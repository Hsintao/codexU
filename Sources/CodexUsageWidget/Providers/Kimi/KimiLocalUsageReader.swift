import Foundation

/// Reads Kimi Code token usage from the local session log.
///
/// Kimi Code records one `usage.record` event per turn in
/// `~/.kimi-code/sessions/<workspace>/session_<uuid>/agents/<agent>/wire.jsonl`.
/// Only `usage.record` carries consumable token counts; the similarly named
/// `token_counting.*` events report the current context size and must never be
/// summed. Tool and Skill invocations come from the loop `tool.call` events,
/// and inference samples pair each `llm.request` with its `usage.record`.
///
/// This is a machine-local lower bound: it only covers sessions produced on this
/// Mac. Kimi's official usage endpoint returns quota percentages, not token
/// counts, so the two figures cannot be reconciled.
struct KimiLocalUsageReader {
    private let fileManager = FileManager.default
    private let readChunk: (FileHandle) throws -> Data?

    init(readChunk: @escaping (FileHandle) throws -> Data? = { try $0.read(upToCount: 64 * 1_024) }) {
        self.readChunk = readChunk
    }
    /// Every provider routed through the Kimi Code CLI counts toward the local
    /// stats; this prefix only marks the Kimi subscription's own models so the
    /// display name can drop it.
    private static let kimiModelPrefix = "kimi-code/"
    private static let maximumLineBytes = 4 * 1_024 * 1_024
    /// Also invalidate prior parses that treated failed reads as successful EOF
    /// or accepted unsafe token counters.
    private static let cacheVersion = 5
    private static let maximumCacheBytes: Int64 = 64 * 1_024 * 1_024
    /// Inference samples pair a request with its usage record; anything longer
    /// is an abandoned request the log never closed, not a real call.
    private static let maximumInferenceSampleMilliseconds: Double = 30 * 60 * 1_000

    func loadLocalUsage(context: RuntimeLoadContext, messages: inout [String]) -> LocalUsage? {
        let root = context.homeDirectory
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        guard fileManager.fileExists(atPath: root.path) else {
            messages.append("未找到 ~/.kimi-code/sessions")
            return nil
        }

        let files = enumerateWireFiles(under: root)
        guard !files.isEmpty else {
            messages.append("未找到 Kimi Code 会话日志")
            return nil
        }

        let cacheState = readCache(context: context)
        var cache = cacheState.cache
        var deltas: [KimiUsageDelta] = []
        var toolCalls: [String: Int] = [:]
        var skillLoads: [(name: String, date: Date, file: String)] = []
        var inferenceSamples: [KimiInferenceSample] = []
        var projectFiles: [String: Set<String>] = [:]
        var cacheChanged = false
        var parsedFileCount = 0
        var failedFileCount = 0
        var invalidTokenRecordCount = 0
        let livePaths = Set(files.map(\.path))

        if cache.entries.keys.contains(where: { !livePaths.contains($0) }) {
            cache.entries = cache.entries.filter { livePaths.contains($0.key) }
            cacheChanged = true
        }

        for file in files {
            guard let fingerprint = fingerprint(for: file) else {
                failedFileCount += 1
                continue
            }
            let key = file.path
            // Project attribution is a session-directory property, not log
            // content: it is resolved on every read so a session that records
            // its cwd later is picked up without invalidating the parsed cache.
            let projectPath = sessionProjectPath(forWireFile: file)
            let parsed: KimiWireParseResult
            if let entry = cache.entries[key], entry.matches(fingerprint) {
                parsed = entry.result
            } else {
                do {
                    parsed = try parseWireFile(file, fingerprint: fingerprint)
                } catch {
                    // Keep the old fingerprint, if any, so a failed scan is
                    // retried. Never publish or cache the partially read file.
                    failedFileCount += 1
                    continue
                }
                cache.entries[key] = KimiWireCacheEntry(
                    fileSize: fingerprint.fileSize,
                    modificationTimeNanoseconds: fingerprint.modificationTimeNanoseconds,
                    result: parsed
                )
                cacheChanged = true
            }
            parsedFileCount += 1
            invalidTokenRecordCount += parsed.invalidTokenRecordCount
            deltas.append(contentsOf: parsed.deltas.map { $0.attributing(to: projectPath) })
            if !parsed.deltas.isEmpty {
                projectFiles[projectPath, default: []].insert(key)
            }
            toolCalls.merge(parsed.toolCalls) { $0 + $1 }
            skillLoads.append(contentsOf: parsed.skillLoads.map { (name: $0.name, date: $0.date, file: key) })
            inferenceSamples.append(contentsOf: parsed.inferenceSamples)
        }

        if cacheChanged, !writeCache(cache, context: context) {
            messages.append("Kimi Code 本地缓存写入失败")
        }

        if failedFileCount > 0 {
            messages.append("Kimi Code 有 \(failedFileCount) 个会话日志读取失败，下次刷新将重试；本次统计可能不完整")
        }
        if invalidTokenRecordCount > 0 {
            messages.append("Kimi Code 已忽略 \(invalidTokenRecordCount) 条无效 token 记录")
        }

        guard !deltas.isEmpty else {
            messages.append("Kimi Code 会话日志中未找到用量记录")
            return nil
        }

        return makeLocalUsage(
            from: deltas,
            parsedFileCount: parsedFileCount,
            toolCalls: toolCalls,
            skillLoads: skillLoads,
            inferenceSamples: inferenceSamples,
            projectFiles: projectFiles,
            context: context,
            messages: &messages
        )
    }

    // MARK: - Enumeration

    private func enumerateWireFiles(under root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.lastPathComponent == "wire.jsonl" else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    // MARK: - Parsing

    private func parseWireFile(_ file: URL, fingerprint: KimiFileFingerprint) throws -> KimiWireParseResult {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        // The parse is content-only; project attribution is applied by the
        // caller so the cache stays valid when a session later records a cwd.
        var result = KimiWireParseResult()
        var buffer = Data()
        var droppingOversizedLine = false
        var lineIndex = 0
        // `llm.request` events awaiting their `usage.record`. Pairing is LIFO
        // within each model: a retry replaces the failed attempt, so the newest
        // pending request for that model owns the next matching record.
        var pendingRequests: [(timeMilliseconds: Double, model: String, effort: String)] = []

        func parseLine(_ lineData: Data) {
            lineIndex += 1
            // Cheap substring pre-filter: the log holds many unrelated event
            // types, and most lines never need JSON parsing.
            guard let line = String(data: lineData, encoding: .utf8) else { return }
            let isUsageRecord = line.contains("\"usage.record\"")
            let isLlmRequest = !isUsageRecord && line.contains("\"llm.request\"")
            let isToolCall = !isUsageRecord && !isLlmRequest && line.contains("\"tool.call\"")
            let isTurnEnd = !isUsageRecord && !isLlmRequest && !isToolCall
                && line.contains("\"agent.turn.ended\"")
            guard isUsageRecord || isLlmRequest || isToolCall || isTurnEnd else { return }
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }
            let type = kimiStringValue(object["type"])

            if isTurnEnd {
                guard type == "agent.turn.ended" else { return }
                // Requests still pending at a turn boundary never produced a
                // record; keeping them would mis-pair the next turn's records.
                pendingRequests.removeAll()
                return
            }

            if isLlmRequest {
                guard type == "llm.request" else { return }
                let alias = kimiStringValue(object["modelAlias"]) ?? kimiStringValue(object["model"]) ?? ""
                guard !alias.isEmpty,
                      let timeMilliseconds = kimiDoubleValue(object["time"]) else { return }
                pendingRequests.append((
                    timeMilliseconds: timeMilliseconds,
                    model: alias,
                    effort: kimiStringValue(object["thinkingEffort"]) ?? "default"
                ))
                return
            }

            if isToolCall {
                guard type == "context.append_loop_event",
                      let event = kimiDictionaryValue(object["event"]),
                      kimiStringValue(event["type"]) == "tool.call",
                      let name = kimiStringValue(event["name"]) else { return }
                if name == "Skill" {
                    guard let skill = kimiStringValue(kimiDictionaryValue(event["args"])?["skill"]) else { return }
                    let date = kimiDateValue(object["time"]) ?? fingerprint.modificationDate ?? Date()
                    result.skillLoads.append(KimiSkillLoad(name: skill, date: date))
                } else {
                    result.toolCalls[name, default: 0] += 1
                }
                return
            }

            guard type == "usage.record" else { return }

            let model = kimiStringValue(object["model"]) ?? "unknown"

            guard let usage = kimiDictionaryValue(object["usage"]) else { return }
            guard let tokens = Self.tokenBreakdown(from: usage) else {
                result.invalidTokenRecordCount += 1
                return
            }
            guard !tokens.isZero else { return }

            let date = kimiDateValue(object["time"])
                ?? kimiDateValue(object["timestamp"])
                ?? fingerprint.modificationDate
                ?? Date()

            result.deltas.append(KimiUsageDelta(date: date, tokens: tokens, model: model, projectPath: ""))

            if let recordMilliseconds = kimiDoubleValue(object["time"]),
               let matchIndex = pendingRequests.lastIndex(where: { $0.model == model }) {
                let request = pendingRequests.remove(at: matchIndex)
                let durationMilliseconds = recordMilliseconds - request.timeMilliseconds
                if durationMilliseconds > 0, durationMilliseconds <= Self.maximumInferenceSampleMilliseconds {
                    result.inferenceSamples.append(KimiInferenceSample(
                        completedAt: date,
                        durationSeconds: durationMilliseconds / 1_000,
                        outputTokens: tokens.outputTokens,
                        model: request.model,
                        effort: request.effort,
                        identityKey: "\(file.path)#\(lineIndex)"
                    ))
                }
            }
        }

        while true {
            let chunk = try readChunk(handle)
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !droppingOversizedLine, !lineData.isEmpty, lineData.count <= Self.maximumLineBytes {
                    parseLine(lineData)
                }
                droppingOversizedLine = false
            }
            if buffer.count > Self.maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                droppingOversizedLine = true
            }
        }
        if !droppingOversizedLine, !buffer.isEmpty, buffer.count <= Self.maximumLineBytes {
            parseLine(buffer)
        }

        return result
    }

    /// Maps Kimi's four counters onto the shared token model.
    ///
    /// `inputOther` is the cache-miss input, while `inputCacheRead` is the cache
    /// hit portion. Both are input tokens, so `inputTokens` holds their sum and
    /// `cachedInputTokens` records the cached share for the existing breakdown.
    static func tokenBreakdown(from usage: [String: Any]) -> TokenBreakdown? {
        guard let inputOther = tokenCount(usage["inputOther"] ?? usage["input_other"]),
              let cacheRead = tokenCount(usage["inputCacheRead"] ?? usage["input_cache_read"]),
              let cacheCreation = tokenCount(usage["inputCacheCreation"] ?? usage["input_cache_creation"]),
              let output = tokenCount(usage["output"]) else { return nil }

        let readInput = inputOther.addingReportingOverflow(cacheRead)
        let input = readInput.partialValue.addingReportingOverflow(cacheCreation)
        let total = input.partialValue.addingReportingOverflow(output)
        guard !readInput.overflow, !input.overflow, !total.overflow else { return nil }
        return TokenBreakdown(
            inputTokens: input.partialValue,
            cachedInputTokens: cacheRead,
            cacheWriteInputTokens: cacheCreation,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: total.partialValue
        )
    }

    private static func tokenCount(_ value: Any?) -> Int64? {
        guard let value else { return 0 }
        let text: String
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            text = number.stringValue
        } else if let string = value as? String {
            text = string
        } else {
            return nil
        }
        // Preserve JSON integers such as Int64.max exactly, before trying a
        // floating representation for decimal/exponent notation.
        if let integer = Int64(text) { return integer >= 0 ? integer : nil }
        guard let number = Double(text), number.isFinite, number >= 0,
              number.rounded(.towardZero) == number,
              number < Double(Int64.max) else { return nil }
        return Int64(number)
    }

    private static func adding(_ value: TokenBreakdown, to previous: TokenBreakdown) -> TokenBreakdown? {
        let input = previous.inputTokens.addingReportingOverflow(value.inputTokens)
        let cached = previous.cachedInputTokens.addingReportingOverflow(value.cachedInputTokens)
        let written = previous.cacheWriteInputTokens.addingReportingOverflow(value.cacheWriteInputTokens)
        let output = previous.outputTokens.addingReportingOverflow(value.outputTokens)
        let reasoning = previous.reasoningOutputTokens.addingReportingOverflow(value.reasoningOutputTokens)
        let total = previous.totalTokens.addingReportingOverflow(value.totalTokens)
        guard !input.overflow, !cached.overflow, !written.overflow,
              !output.overflow, !reasoning.overflow, !total.overflow,
              !input.partialValue.addingReportingOverflow(output.partialValue).overflow else { return nil }
        return TokenBreakdown(
            inputTokens: input.partialValue, cachedInputTokens: cached.partialValue,
            cacheWriteInputTokens: written.partialValue, outputTokens: output.partialValue,
            reasoningOutputTokens: reasoning.partialValue, totalTokens: total.partialValue
        )
    }

    /// Reads the session's recorded working directory.
    ///
    /// `wire.jsonl` sits at `<session>/agents/<agent>/wire.jsonl`, and the
    /// session-level `state.json` carries `cwd`. A session without a recorded
    /// cwd stays empty rather than borrowing another session's project.
    private func sessionProjectPath(forWireFile file: URL) -> String {
        let stateURL = file
            .deletingLastPathComponent()   // agents/<agent>
            .deletingLastPathComponent()   // agents
            .deletingLastPathComponent()   // session_<uuid>
            .appendingPathComponent("state.json")
        guard let values = try? stateURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= 256 * 1_024,
              let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return kimiStringValue(object["cwd"]) ?? ""
    }

    // MARK: - Aggregation

    private func makeLocalUsage(
        from deltas: [KimiUsageDelta],
        parsedFileCount: Int,
        toolCalls: [String: Int],
        skillLoads: [(name: String, date: Date, file: String)],
        inferenceSamples: [KimiInferenceSample],
        projectFiles: [String: Set<String>],
        context: RuntimeLoadContext,
        messages: inout [String]
    ) -> LocalUsage? {
        let statistics = context.statistics
        let now = statistics.now
        let calendar = statistics.calendar

        let dayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let previousSevenDayStart = calendar.date(byAdding: .day, value: -13, to: dayStart) ?? dayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart

        var today = TokenBreakdown.zero
        var sevenDay = TokenBreakdown.zero
        var previousSevenDay = TokenBreakdown.zero
        var month = TokenBreakdown.zero
        var lifetime = TokenBreakdown.zero
        var dailyUsage: [String: (date: Date, tokens: TokenBreakdown)] = [:]
        var dailyByModel: [String: [String: TokenBreakdown]] = [:]
        var projects: [String: KimiProjectAccumulator] = [:]

        for delta in deltas {
            // All counters are nonnegative and each record's total is exact.
            // Bounding lifetime first also bounds every day/model/project and
            // inference subset, whose shared aggregators use ordinary addition.
            guard let accumulated = Self.adding(delta.tokens, to: lifetime) else {
                messages.append("Kimi Code 累计 token 超出可表示范围，统计暂不可用")
                return nil
            }
            lifetime = accumulated
            // Retain consumed usage in lifetime even if the producing clock
            // was ahead, but current statistics must all use the same cutoff.
            guard delta.date <= now else { continue }
            if delta.date >= monthStart { month.add(delta.tokens) }
            if delta.date >= sevenDayStart { sevenDay.add(delta.tokens) }
            if delta.date >= previousSevenDayStart && delta.date < sevenDayStart {
                previousSevenDay.add(delta.tokens)
            }
            if delta.date >= dayStart { today.add(delta.tokens) }

            let bucketDate = calendar.startOfDay(for: delta.date)
            let key = statistics.dayKey(for: bucketDate)
            var dayTokens = dailyUsage[key]?.tokens ?? .zero
            dayTokens.add(delta.tokens)
            dailyUsage[key] = (bucketDate, dayTokens)

            var modelDays = dailyByModel[delta.model] ?? [:]
            var modelDayTokens = modelDays[key] ?? .zero
            modelDayTokens.add(delta.tokens)
            modelDays[key] = modelDayTokens
            dailyByModel[delta.model] = modelDays

            // Sessions without a recorded working directory are tracked under an
            // empty key so their tokens still count toward the totals, but they
            // are not presented as a project.
            var project = projects[delta.projectPath] ?? KimiProjectAccumulator(path: delta.projectPath)
            project.add(delta.tokens, at: delta.date)
            projects[delta.projectPath] = project
        }

        let detailed = DetailedUsage(
            today: PricedTokenUsage(tokens: today, estimatedCostUSD: 0, hasEstimatedCost: false),
            sevenDay: PricedTokenUsage(tokens: sevenDay, estimatedCostUSD: 0, hasEstimatedCost: false),
            month: PricedTokenUsage(tokens: month, estimatedCostUSD: 0, hasEstimatedCost: false),
            lifetime: PricedTokenUsage(tokens: lifetime, estimatedCostUSD: 0, hasEstimatedCost: false),
            parsedFileCount: parsedFileCount,
            tokenEventCount: deltas.count
        )
        let dailyBuckets = makeSevenDayBuckets(dailyUsage: dailyUsage, now: now, calendar: calendar)
        let usageTrend = makeUsageTrend(
            dailyUsage: dailyUsage,
            sevenDay: sevenDay,
            previousSevenDay: previousSevenDay,
            month: month,
            modelTrends: makeModelTrends(dailyByModel: dailyByModel, now: now, calendar: calendar),
            now: now,
            calendar: calendar
        )

        // Sessions without a recorded cwd still contribute to the totals above,
        // but they are not a project, so a nameless bucket is never shown.
        let projectUsages = projects
            .filter { !$0.key.isEmpty }
            .values
            .map { $0.makeProject(threadCount: max(projectFiles[$0.path]?.count ?? 1, 1)) }
            .sorted {
                if $0.tokens == $1.tokens {
                    return ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
                }
                return $0.tokens > $1.tokens
            }
        let recentProjects = projectUsages.filter {
            ($0.lastActiveAt ?? .distantPast) >= sevenDayStart
        }

        let toolUsages = toolCalls
            .map { name, count in
                ToolUsage(
                    id: name,
                    name: name,
                    category: toolCategory(for: name),
                    callCount: count,
                    estimatedTokens: nil,
                    estimatedCostUSD: nil
                )
            }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                return $0.name < $1.name
            }

        let skillUsages = makeSkillUsages(
            from: skillLoads,
            projectPaths: projectFiles.keys.filter { !$0.isEmpty },
            homeDirectory: context.homeDirectory
        )

        let inferencePerformance = makeInferenceHistory(
            from: inferenceSamples,
            dayStart: dayStart,
            now: now,
            calendar: calendar
        )

        return LocalUsage(
            lifetimeTokens: lifetime.visibleTotalTokens,
            todayTokens: today.visibleTotalTokens,
            sevenDayTokens: sevenDay.visibleTotalTokens,
            threadCount: parsedFileCount,
            lastUpdatedAt: deltas.lazy.filter { $0.date <= now }.map(\.date).max(),
            dailyBuckets: dailyBuckets,
            recentThreads: [],
            detailedUsage: detailed,
            usageTrend: usageTrend,
            inferencePerformance: inferencePerformance,
            projectBoard: projectUsages.isEmpty
                ? nil
                : ProjectBoard(recentProjects: Array(recentProjects.prefix(8)), allProjects: projectUsages),
            toolUsages: toolUsages,
            skillUsages: skillUsages
        )
    }

    /// The wire log records only the skill name at invocation time. Loads are
    /// grouped by name and resolved to an on-disk SKILL.md when one exists in
    /// the known roots; unresolved skills stay name-only rather than guessing
    /// a file.
    private func makeSkillUsages(
        from skillLoads: [(name: String, date: Date, file: String)],
        projectPaths: [String],
        homeDirectory: URL
    ) -> [SkillUsage] {
        var groups: [String: (count: Int, files: Set<String>, lastAt: Date?)] = [:]
        for load in skillLoads where !load.name.isEmpty {
            var group = groups[load.name] ?? (count: 0, files: [], lastAt: nil)
            group.count += 1
            group.files.insert(load.file)
            if group.lastAt == nil || load.date > group.lastAt! {
                group.lastAt = load.date
            }
            groups[load.name] = group
        }

        let resolver = KimiSkillResolver()
        return groups.map { name, group -> SkillUsage in
            let resolution = resolver.resolve(
                name: name,
                projectPaths: projectPaths,
                homeDirectory: homeDirectory
            )
            return SkillUsage(
                id: resolution?.path ?? name,
                name: name,
                path: resolution?.path ?? name,
                sourceLabel: resolution.map { kimiSkillSourceLabel(for: $0.path) } ?? "Kimi Code",
                loadCount: group.count,
                threadCount: max(group.files.count, 1),
                staticTokenEstimate: resolution?.tokenEstimate,
                staticByteCount: resolution?.byteCount,
                lastLoadedAt: group.lastAt
            )
        }
        .sorted {
            if $0.loadCount != $1.loadCount { return $0.loadCount > $1.loadCount }
            if ($0.staticTokenEstimate ?? -1) != ($1.staticTokenEstimate ?? -1) {
                return ($0.staticTokenEstimate ?? -1) > ($1.staticTokenEstimate ?? -1)
            }
            return $0.name < $1.name
        }
    }

    private func kimiSkillSourceLabel(for path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(".kimi-code"),
           let managedIndex = components.firstIndex(of: "managed"),
           components.count > managedIndex + 1 {
            return components[managedIndex + 1]
        }
        if path.contains("/.agents/skills/") { return "agents" }
        return "Kimi Code"
    }

    /// Samples outside the retention window keep the cache from growing
    /// unbounded; the window mirrors the Codex inference history horizon.
    private func makeInferenceHistory(
        from inferenceSamples: [KimiInferenceSample],
        dayStart: Date,
        now: Date,
        calendar: Calendar
    ) -> ModelInferencePerformanceHistory? {
        let retentionStart = calendar.date(byAdding: .day, value: -34, to: dayStart) ?? dayStart
        let samples = inferenceSamples
            .filter { $0.completedAt >= retentionStart && $0.completedAt <= now }
            .map { sample in
                ModelInferenceSample(
                    completedAt: sample.completedAt,
                    durationSeconds: sample.durationSeconds,
                    outputTokens: sample.outputTokens,
                    // The log carries no reasoning-token split; zero reads as
                    // "not recorded", not "no reasoning happened".
                    reasoningOutputTokens: 0,
                    model: sample.model.hasPrefix(Self.kimiModelPrefix)
                        ? String(sample.model.dropFirst(Self.kimiModelPrefix.count))
                        : sample.model,
                    effort: sample.effort,
                    eventIdentity: CodexTokenEventIdentity(rawKey: sample.identityKey)
                )
            }
        guard !samples.isEmpty else { return nil }
        return ModelInferencePerformanceBuilder.makeHistory(
            samples: samples,
            recordingStartedAt: samples.map(\.completedAt).min() ?? now,
            dayStart: dayStart,
            calendar: calendar
        )
    }

    private func makeSevenDayBuckets(
        dailyUsage: [String: (date: Date, tokens: TokenBreakdown)],
        now: Date,
        calendar: Calendar
    ) -> [DailyTokenBucket] {
        let labelFormatter = DateFormatter()
        labelFormatter.calendar = calendar
        labelFormatter.timeZone = calendar.timeZone
        labelFormatter.locale = Locale(identifier: "zh_CN")
        labelFormatter.dateFormat = "E"
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now

        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = statisticsDayKey(date, calendar: calendar)
            return DailyTokenBucket(
                id: key,
                label: labelFormatter.string(from: date),
                tokens: dailyUsage[key]?.tokens.visibleTotalTokens ?? 0
            )
        }
    }

    private func makeUsageTrend(
        dailyUsage: [String: (date: Date, tokens: TokenBreakdown)],
        sevenDay: TokenBreakdown,
        previousSevenDay: TokenBreakdown,
        month: TokenBreakdown,
        modelTrends: [ModelUsageTrend]?,
        now: Date,
        calendar: Calendar
    ) -> UsageTrend {
        let start = calendar.date(byAdding: .day, value: -179, to: calendar.startOfDay(for: now)) ?? now
        var buckets: [UsageDayBucket] = []
        var heatmapDays: [UsageHeatmapDay] = []

        for offset in 0..<180 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let key = statisticsDayKey(date, calendar: calendar)
            let tokens = dailyUsage[key]?.tokens ?? .zero
            let usage = PricedTokenUsage(tokens: tokens, estimatedCostUSD: 0, hasEstimatedCost: false)
            buckets.append(UsageDayBucket(id: key, date: date, usage: usage, sourceQuality: .detailed))
            heatmapDays.append(UsageHeatmapDay(id: key, date: date, usage: usage, isFuture: date > now))
        }

        let activeBuckets = buckets.filter { $0.tokens > 0 }
        let peak = activeBuckets.max { $0.tokens < $1.tokens }
        let previousTokens = previousSevenDay.visibleTotalTokens
        let currentTokens = sevenDay.visibleTotalTokens
        let changePercent: Double?
        if previousTokens > 0 {
            changePercent = (Double(currentTokens - previousTokens) / Double(previousTokens)) * 100
        } else {
            changePercent = nil
        }

        let summary = UsageTrendSummary(
            sevenDay: PricedTokenUsage(tokens: sevenDay, estimatedCostUSD: 0, hasEstimatedCost: false),
            dailyAverageTokens: currentTokens / 7,
            peakDay: peak,
            changePercent: changePercent,
            isNewActivity: previousTokens == 0 && currentTokens > 0
        )
        let thresholds = makeHeatmapThresholds(activeBuckets.map(\.tokens))
        let heatmapWeeks = stride(from: 0, to: heatmapDays.count, by: 7).map { start in
            Array(heatmapDays[start..<min(start + 7, heatmapDays.count)])
        }

        return UsageTrend(
            dayBuckets: buckets,
            heatmapWeeks: heatmapWeeks,
            heatmapThresholds: thresholds,
            summary: summary,
            modelTrends: modelTrends,
            month: PricedTokenUsage(tokens: month, estimatedCostUSD: 0, hasEstimatedCost: false),
            projectedMonthCostUSD: nil,
            activeDayCount: activeBuckets.count,
            sourceQuality: .detailed
        )
    }

    /// Kimi's log records the model per usage event, so per-model daily buckets
    /// are exact rather than inferred.
    private func makeModelTrends(
        dailyByModel: [String: [String: TokenBreakdown]],
        now: Date,
        calendar: Calendar
    ) -> [ModelUsageTrend]? {
        let dayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let previousSevenDayStart = calendar.date(byAdding: .day, value: -13, to: dayStart) ?? dayStart
        let start = calendar.date(byAdding: .day, value: -179, to: dayStart) ?? dayStart

        var trends: [ModelUsageTrend] = []
        for (model, days) in dailyByModel {
            var buckets: [UsageDayBucket] = []
            var sevenDay = TokenBreakdown.zero
            var previousSevenDay = TokenBreakdown.zero

            for offset in 0..<180 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                let key = statisticsDayKey(date, calendar: calendar)
                let tokens = days[key] ?? .zero
                buckets.append(UsageDayBucket(
                    id: key,
                    date: date,
                    usage: PricedTokenUsage(tokens: tokens, estimatedCostUSD: 0, hasEstimatedCost: false),
                    sourceQuality: .detailed
                ))
                if date >= sevenDayStart {
                    sevenDay.add(tokens)
                } else if date >= previousSevenDayStart {
                    previousSevenDay.add(tokens)
                }
            }

            let activeBuckets = buckets.filter { $0.tokens > 0 }
            guard !activeBuckets.isEmpty else { continue }

            let currentTokens = sevenDay.visibleTotalTokens
            let previousTokens = previousSevenDay.visibleTotalTokens
            let changePercent: Double?
            if previousTokens > 0 {
                changePercent = (Double(currentTokens - previousTokens) / Double(previousTokens)) * 100
            } else {
                changePercent = nil
            }
            let summary = UsageTrendSummary(
                sevenDay: PricedTokenUsage(tokens: sevenDay, estimatedCostUSD: 0, hasEstimatedCost: false),
                dailyAverageTokens: currentTokens / 7,
                peakDay: activeBuckets.max { $0.tokens < $1.tokens },
                changePercent: changePercent,
                isNewActivity: previousTokens == 0 && currentTokens > 0
            )
            trends.append(ModelUsageTrend(
                id: model,
                model: model.hasPrefix(Self.kimiModelPrefix)
                    ? String(model.dropFirst(Self.kimiModelPrefix.count))
                    : model,
                dayBuckets: buckets,
                summary: summary,
                activeDayCount: activeBuckets.count
            ))
        }

        return trends.sorted {
            let lhsRecent = $0.summary.sevenDay.tokens.visibleTotalTokens
            let rhsRecent = $1.summary.sevenDay.tokens.visibleTotalTokens
            if lhsRecent != rhsRecent { return lhsRecent > rhsRecent }
            let lhsTotal = $0.dayBuckets.reduce(Int64(0)) { $0 + $1.tokens }
            let rhsTotal = $1.dayBuckets.reduce(Int64(0)) { $0 + $1.tokens }
            if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
            return ($0.model ?? "") < ($1.model ?? "")
        }
    }

    private func makeHeatmapThresholds(_ tokens: [Int64]) -> [Int64] {
        let sorted = tokens.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return [1, 10, 100, 1000] }
        func percentile(_ value: Double) -> Int64 {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * value).rounded())))
            return max(sorted[index], 1)
        }
        return [percentile(0.25), percentile(0.5), percentile(0.75), percentile(0.95)]
    }

    // MARK: - Cache

    private func fingerprint(for file: URL) -> KimiFileFingerprint? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return KimiFileFingerprint(
            fileSize: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate,
            modificationTimeNanoseconds: values.contentModificationDate.map {
                Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded())
            }
        )
    }

    private func readCache(context: RuntimeLoadContext) -> (cache: KimiDiskCache, reloadAll: Bool) {
        let url = cacheURL(context: context)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              Int64(values.fileSize ?? 0) <= Self.maximumCacheBytes,
              let data = try? Data(contentsOf: url) else {
            return (KimiDiskCache(version: Self.cacheVersion, entries: [:]), false)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let cache = try? decoder.decode(KimiDiskCache.self, from: data),
              cache.version == Self.cacheVersion else {
            return (KimiDiskCache(version: Self.cacheVersion, entries: [:]), false)
        }
        return (cache, false)
    }

    private func writeCache(_ cache: KimiDiskCache, context: RuntimeLoadContext) -> Bool {
        let url = cacheURL(context: context)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(cache)
            guard Int64(data.count) <= Self.maximumCacheBytes else { return false }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func cacheURL(context: RuntimeLoadContext) -> URL {
        context.cacheDirectory
            .appendingPathComponent("kimi", isDirectory: true)
            .appendingPathComponent("session-usage-v1.json")
    }
}

// MARK: - Supporting types

/// Accumulates one project's token usage for the project board.
private struct KimiProjectAccumulator {
    let path: String
    var tokens = TokenBreakdown.zero
    var lastActiveAt: Date?

    mutating func add(_ value: TokenBreakdown, at date: Date) {
        tokens.add(value)
        if lastActiveAt == nil || date > lastActiveAt! {
            lastActiveAt = date
        }
    }

    func makeProject(threadCount: Int) -> ProjectUsage {
        let name = path.isEmpty ? "未归类" : URL(fileURLWithPath: path).lastPathComponent
        return ProjectUsage(
            id: path.isEmpty ? "uncategorized" : path,
            name: name.isEmpty ? "未归类" : name,
            fullPath: path,
            tokens: tokens.visibleTotalTokens,
            estimatedCostUSD: nil,
            threadCount: threadCount,
            lastActiveAt: lastActiveAt,
            sourceQuality: .detailed
        )
    }
}

struct KimiUsageDelta: Codable {
    let date: Date
    let tokens: TokenBreakdown
    let model: String
    /// Working directory of the owning session, read from the sibling
    /// `state.json`. Empty when the session did not record one.
    let projectPath: String

    init(date: Date, tokens: TokenBreakdown, model: String, projectPath: String) {
        self.date = date
        self.tokens = tokens
        self.model = model
        self.projectPath = projectPath
    }

    // Tolerate cache entries written before project attribution existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        tokens = try container.decode(TokenBreakdown.self, forKey: .tokens)
        model = try container.decode(String.self, forKey: .model)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
    }

    /// Returns a copy bound to the owning session's project directory. The
    /// cached parse intentionally stores no project so this stays fresh.
    func attributing(to projectPath: String) -> KimiUsageDelta {
        guard projectPath != self.projectPath else { return self }
        return KimiUsageDelta(date: date, tokens: tokens, model: model, projectPath: projectPath)
    }
}

struct KimiFileFingerprint {
    let fileSize: Int64
    let modificationDate: Date?
    let modificationTimeNanoseconds: Int64?
}

/// One Skill invocation observed in the wire log. Only the skill name and its
/// time are kept; arguments are never persisted.
struct KimiSkillLoad: Codable {
    let name: String
    let date: Date
}

/// One `llm.request` ↔ `usage.record` pair. Duration covers the whole call,
/// from request dispatch to usage accounting; the log records no time to
/// first token.
struct KimiInferenceSample: Codable {
    let completedAt: Date
    let durationSeconds: Double
    let outputTokens: Int64
    let model: String
    let effort: String
    let identityKey: String
}

/// Everything one wire file contributes to the Kimi panels.
struct KimiWireParseResult: Codable {
    var invalidTokenRecordCount = 0
    var deltas: [KimiUsageDelta] = []
    var toolCalls: [String: Int] = [:]
    var skillLoads: [KimiSkillLoad] = []
    var inferenceSamples: [KimiInferenceSample] = []
}

private struct KimiWireCacheEntry: Codable {
    let fileSize: Int64
    let modificationTimeNanoseconds: Int64?
    let result: KimiWireParseResult

    func matches(_ fingerprint: KimiFileFingerprint) -> Bool {
        fileSize == fingerprint.fileSize
            && modificationTimeNanoseconds == fingerprint.modificationTimeNanoseconds
    }
}

private struct KimiDiskCache: Codable {
    let version: Int
    var entries: [String: KimiWireCacheEntry]
}
