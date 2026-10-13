import Foundation

/// AI leadership evidence extracted from Kimi Code session logs.
struct KimiLeadershipEvidence {
    let workers: [LeadershipWorker]
    let intervals: [LeadershipInterval]
    /// projectID → project path, so the history index can name projects exactly
    /// like the direct reader does.
    let projectPaths: [String: String]
    var error: UsageIndexError? = nil

    static let empty = KimiLeadershipEvidence(workers: [], intervals: [], projectPaths: [:])
}

/// Reads Kimi Code turn boundaries for the AI leadership model.
///
/// Kimi Code writes one `wire.jsonl` per agent under
/// `~/.kimi-code/sessions/<workspace>/session_<uuid>/agents/<agent>/wire.jsonl`.
/// The sibling `state.json` carries the session working directory and the agent
/// roster (`type` = `main`/`sub` plus `parentAgentId`), which supplies worker
/// identity and project attribution. An agent that the roster does not describe
/// is left out rather than guessed.
///
/// Only turn boundaries are read — `agent.turn.started`, `agent.turn.ended` and
/// `turn.ended`. Prompts, messages and tool arguments are never parsed, and the
/// parsed turns are cached by file fingerprint so a refresh costs one `stat` per
/// log.
final class KimiLeadershipReader {
    private let fileManager = FileManager.default
    private let readChunk: (FileHandle) throws -> Data?

    private static let maximumLineBytes = 4 * 1_024 * 1_024
    private static let maximumStateBytes = 256 * 1_024
    private static let maximumCacheBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumCacheEntries = 2_048
    private static let maximumIntervals = 20_000
    private static let maximumTurnIDBytes = 1_024
    private static let maximumReadSeconds: TimeInterval = 5
    private static let lookbackDays = 34
    /// A single turn longer than this is a log artefact, not a session.
    private static let maximumTurnSeconds: TimeInterval = 24 * 3_600
    private static let cacheVersion = 2

    init(readChunk: @escaping (FileHandle) throws -> Data? = { try $0.read(upToCount: 64 * 1_024) }) {
        self.readChunk = readChunk
    }

    func load(context: RuntimeLoadContext) -> KimiLeadershipEvidence {
        do {
            return try loadEvidence(context: context)
        } catch {
            return KimiLeadershipEvidence(workers: [], intervals: [], projectPaths: [:],
                error: error as? UsageIndexError ?? .cacheInvalid)
        }
    }

    private func loadEvidence(context: RuntimeLoadContext) throws -> KimiLeadershipEvidence {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.maximumReadSeconds
        let root = context.homeDirectory
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return .empty }

        let calendar = context.statistics.calendar
        let earliest = calendar.date(
            byAdding: .day,
            value: -Self.lookbackDays,
            to: calendar.startOfDay(for: context.now)
        ) ?? context.now.addingTimeInterval(-Double(Self.lookbackDays) * 24 * 3_600)
        let files = try wireFiles(under: root, earliest: earliest, deadline: deadline)
        guard !files.isEmpty else { return .empty }

        var cache = readCache(context: context)
        let livePaths = Set(files.map(\.path))
        var cacheChanged = false
        // Keep only completed file reads, even when a later file exhausts the
        // budget. The dashboard still fails atomically, but retries can advance.
        defer {
            if cacheChanged {
                writeCache(cache, context: context)
            }
        }
        if cache.entries.keys.contains(where: { !livePaths.contains($0) }) {
            cache.entries = cache.entries.filter { livePaths.contains($0.key) }
            cacheChanged = true
        }
        var cachedTurnCount = cache.entries.values.reduce(0) { $0 + $1.turns.count }

        var metadataBySession: [String: KimiSessionMetadata] = [:]
        var workersByID: [String: LeadershipWorker] = [:]
        var projectPaths: [String: String] = [:]
        var intervals: [LeadershipInterval] = []

        for file in files {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageIndexError.resourceLimited }
            guard let fingerprint = fingerprint(for: file) else { throw UsageIndexError.cacheInvalid }
            let sessionDirectory = file.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let agentDirectory = file.deletingLastPathComponent().lastPathComponent
            let sessionKey = sessionDirectory.path
            let metadata: KimiSessionMetadata
            if let cached = metadataBySession[sessionKey] {
                metadata = cached
            } else {
                metadata = try readSessionMetadata(sessionDirectory: sessionDirectory)
                metadataBySession[sessionKey] = metadata
            }
            guard let agent = metadata.agents[agentDirectory] else { continue }

            let key = file.path
            let turns: [KimiTurnRecord]
            if let entry = cache.entries[key], entry.matches(fingerprint) {
                turns = entry.turns
            } else {
                let parsed = try parseWireFile(file, earliest: earliest, deadline: deadline)
                let nextCount = cachedTurnCount - (cache.entries[key]?.turns.count ?? 0) + parsed.count
                guard nextCount <= Self.maximumIntervals else { throw UsageIndexError.resourceLimited }
                turns = parsed
                cache.entries[key] = KimiLeadershipCacheEntry(fingerprint: fingerprint, turns: parsed)
                cachedTurnCount = nextCount
                cacheChanged = true
            }

            let kind: LeadershipWorkerKind = agent.isSubagent ? .subagent : .main
            let workerID = kind == .subagent
                ? "kimi:subagent:\(metadata.sessionID):\(agentDirectory)"
                : "kimi:main:\(metadata.sessionID)"
            let projectID = UsageLeadershipAdapter.projectID(
                runtime: RuntimeScope.kimi.runtimeId,
                path: metadata.projectPath
            )
            projectPaths[projectID] = metadata.projectPath
            if workersByID[workerID] == nil {
                workersByID[workerID] = LeadershipWorker(
                    id: workerID,
                    runtime: .kimi,
                    kind: kind,
                    projectID: projectID,
                    projectName: projectName(for: metadata.projectPath),
                    parentID: parentWorkerID(agent.parentAgentID, sessionID: metadata.sessionID)
                )
            }
            for turn in turns {
                guard intervals.count < Self.maximumIntervals else { throw UsageIndexError.resourceLimited }
                intervals.append(LeadershipInterval(
                    id: "kimi:\(metadata.sessionID):\(agentDirectory):\(turn.id)",
                    workerID: workerID,
                    runtime: .kimi,
                    workerKind: kind,
                    projectID: projectID,
                    startAt: turn.startAt,
                    endAt: turn.endAt,
                    quality: .fact,
                    isAutonomous: kind == .subagent
                ))
            }
        }

        return KimiLeadershipEvidence(
            workers: workersByID.values.sorted { $0.id < $1.id },
            intervals: intervals,
            projectPaths: projectPaths
        )
    }

    // MARK: - Session metadata

    private struct KimiSessionMetadata {
        let sessionID: String
        let projectPath: String
        let agents: [String: KimiAgentIdentity]
    }

    private struct KimiAgentIdentity {
        let isSubagent: Bool
        let parentAgentID: String?
    }

    private func readSessionMetadata(sessionDirectory: URL) throws -> KimiSessionMetadata {
        let sessionID = sessionDirectory.lastPathComponent
        let url = sessionDirectory.appendingPathComponent("state.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maximumStateBytes,
              let handle = try? FileHandle(forReadingFrom: url)
        else { throw UsageIndexError.cacheInvalid }
        let data = (try? handle.read(upToCount: Self.maximumStateBytes + 1)) ?? Data()
        try? handle.close()
        guard data.count == size,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageIndexError.cacheInvalid }

        var agents: [String: KimiAgentIdentity] = [:]
        guard let roster = kimiDictionaryValue(object["agents"]) else { throw UsageIndexError.cacheInvalid }
        for (directory, value) in roster {
            guard let entry = kimiDictionaryValue(value) else { throw UsageIndexError.cacheInvalid }
            agents[directory] = KimiAgentIdentity(
                isSubagent: kimiStringValue(entry["type"])?.lowercased() == "sub",
                parentAgentID: kimiStringValue(entry["parentAgentId"])
            )
        }
        return KimiSessionMetadata(
            sessionID: sessionID,
            projectPath: kimiStringValue(object["cwd"]) ?? kimiStringValue(object["workDir"]) ?? "",
            agents: agents
        )
    }

    private func parentWorkerID(_ parent: String?, sessionID: String) -> String? {
        guard let parent, !parent.isEmpty else { return nil }
        return parent == "main"
            ? "kimi:main:\(sessionID)"
            : "kimi:subagent:\(sessionID):\(parent)"
    }

    private func projectName(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未归类" }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? "未归类" : name
    }

    // MARK: - Discovery

    private func wireFiles(under root: URL, earliest: Date, deadline: TimeInterval) throws -> [URL] {
        var discoveryFailed = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in discoveryFailed = true; return false }
        ) else { throw UsageIndexError.cacheInvalid }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageIndexError.resourceLimited }
            guard url.lastPathComponent == "wire.jsonl" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.contentModificationDate ?? .distantPast) >= earliest
            else { continue }
            guard urls.count < Self.maximumCacheEntries else { throw UsageIndexError.resourceLimited }
            urls.append(url)
        }
        guard !discoveryFailed else { throw UsageIndexError.cacheInvalid }
        return urls.sorted { $0.path < $1.path }
    }

    // MARK: - Parsing

    private struct KimiTurnRecord: Codable {
        let id: String
        let startAt: Date
        let endAt: Date
    }

    private struct KimiTurnEnd {
        let time: Double
        let durationMilliseconds: Double?
    }

    /// A failed or over-budget read never publishes or caches a partial file.
    private func parseWireFile(_ file: URL, earliest: Date, deadline: TimeInterval) throws -> [KimiTurnRecord] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var starts: [String: Double] = [:]
        var agentEnds: [String: Double] = [:]
        var turnEnds: [String: KimiTurnEnd] = [:]
        var turnIDs = Set<String>()
        var buffer = Data()
        var droppingOversizedLine = false

        func parseLine(_ lineData: Data) throws {
            guard let line = String(data: lineData, encoding: .utf8) else { return }
            let isAgentStart = line.contains("\"agent.turn.started\"")
            let isAgentEnd = !isAgentStart && line.contains("\"agent.turn.ended\"")
            let isTurnEnd = !isAgentStart && !isAgentEnd && line.contains("\"turn.ended\"")
            guard isAgentStart || isAgentEnd || isTurnEnd else { return }
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = kimiStringValue(object["type"]),
                  let turnID = kimiStringValue(object["turnId"]),
                  let time = kimiDoubleValue(object["time"]), time.isFinite
            else { return }
            guard ["agent.turn.started", "agent.turn.ended", "turn.ended"].contains(type),
                  time / 1_000 >= earliest.timeIntervalSince1970 else { return }
            guard turnID.utf8.count <= Self.maximumTurnIDBytes else { throw UsageIndexError.resourceLimited }
            if !turnIDs.contains(turnID) {
                guard turnIDs.count < Self.maximumIntervals else { throw UsageIndexError.resourceLimited }
                turnIDs.insert(turnID)
            }
            switch type {
            case "agent.turn.started":
                starts[turnID] = time
            case "agent.turn.ended":
                agentEnds[turnID] = time
            case "turn.ended":
                guard agentEnds[turnID] == nil else { return }
                turnEnds[turnID] = KimiTurnEnd(time: time, durationMilliseconds: kimiDoubleValue(object["durationMs"]))
            default:
                return
            }
        }

        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageIndexError.resourceLimited }
            let chunk = try readChunk(handle)
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.range(of: Data([10]))?.lowerBound {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !droppingOversizedLine, !lineData.isEmpty, lineData.count <= Self.maximumLineBytes {
                    try parseLine(lineData)
                }
                droppingOversizedLine = false
            }
            if buffer.count > Self.maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                droppingOversizedLine = true
            }
        }
        if !droppingOversizedLine, !buffer.isEmpty, buffer.count <= Self.maximumLineBytes {
            try parseLine(buffer)
        }

        var records: [KimiTurnRecord] = []
        func append(_ turnID: String, start: Double, end: Double) {
            guard start.isFinite, end.isFinite, end > start else { return }
            guard (end - start) / 1_000 <= Self.maximumTurnSeconds else { return }
            records.append(KimiTurnRecord(
                id: turnID,
                startAt: Date(timeIntervalSince1970: start / 1_000),
                endAt: Date(timeIntervalSince1970: end / 1_000)
            ))
        }
        for (turnID, start) in starts {
            if let end = agentEnds[turnID] { append(turnID, start: start, end: end) }
        }
        for (turnID, value) in turnEnds where agentEnds[turnID] == nil {
            guard let duration = value.durationMilliseconds, duration >= 0 else { continue }
            append(turnID, start: value.time - duration, end: value.time)
        }
        return records.sorted {
            if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
            return $0.id < $1.id
        }
    }

    // MARK: - Cache

    private struct KimiLeadershipFingerprint: Codable, Equatable {
        let fileSize: Int64
        let modificationTimeNanoseconds: Int64
    }

    private struct KimiLeadershipCacheEntry: Codable {
        let fingerprint: KimiLeadershipFingerprint
        let turns: [KimiTurnRecord]

        func matches(_ other: KimiLeadershipFingerprint) -> Bool { fingerprint == other }
    }

    private struct KimiLeadershipDiskCache: Codable {
        let version: Int
        var entries: [String: KimiLeadershipCacheEntry]
    }

    private func cacheURL(context: RuntimeLoadContext) -> URL {
        context.cacheDirectory.appendingPathComponent("kimi-leadership-v1.json")
    }

    private func readCache(context: RuntimeLoadContext) -> KimiLeadershipDiskCache {
        let url = cacheURL(context: context)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              Int64(values.fileSize ?? 0) <= Self.maximumCacheBytes,
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(KimiLeadershipDiskCache.self, from: data),
              cache.version == Self.cacheVersion,
              cache.entries.count <= Self.maximumCacheEntries,
              cache.entries.values.reduce(0, { $0 + $1.turns.count }) <= Self.maximumIntervals
        else { return KimiLeadershipDiskCache(version: Self.cacheVersion, entries: [:]) }
        return cache
    }

    private func writeCache(_ cache: KimiLeadershipDiskCache, context: RuntimeLoadContext) {
        let url = cacheURL(context: context)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            guard Int64(data.count) <= Self.maximumCacheBytes else { return }
            try data.write(to: url, options: .atomic)
        } catch {}
    }

    private func fingerprint(for url: URL) -> KimiLeadershipFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modifiedAt = values.contentModificationDate
        else { return nil }
        return KimiLeadershipFingerprint(
            fileSize: Int64(fileSize),
            modificationTimeNanoseconds: Int64(modifiedAt.timeIntervalSince1970 * 1_000_000_000)
        )
    }
}
