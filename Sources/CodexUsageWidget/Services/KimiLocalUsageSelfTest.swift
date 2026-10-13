import Foundation

/// Fixture-driven coverage for Kimi Code's local token usage reader.
///
/// The fixtures mirror the real `wire.jsonl` shape. The critical guard is that
/// only `usage.record` contributes; the `token_counting.*` events in the same
/// file report context watermarks and must never be summed.
enum KimiLocalUsageSelfTest {
    static func run() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("codexu-kimi-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        do {
            let home = root.appendingPathComponent("home", isDirectory: true)
            let cache = root.appendingPathComponent("cache", isDirectory: true)
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)

            let sessions = home
                .appendingPathComponent(".kimi-code", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)

            let calendar = Calendar.current
            // Keep every completed-call fixture before the snapshot even when
            // the self-test is invoked shortly after midnight.
            let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
            func writeWire(_ relative: String, lines: [String]) throws {
                let url = sessions.appendingPathComponent(relative)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            }
            /// Writes the session-level `state.json` that carries the project cwd.
            func writeState(session relative: String, cwd: String) throws {
                let url = sessions.appendingPathComponent(relative).appendingPathComponent("state.json")
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let object: [String: Any] = ["id": "session", "cwd": cwd]
                try Data(try JSONSerialization.data(withJSONObject: object)).write(to: url)
            }
            func event(type: String, model: String?, usage: [String: Int]?, time: Date, agent: String = "main", scope: String = "turn") -> String {
                var object: [String: Any] = [
                    "type": type,
                    "agentId": agent,
                    "time": Int(time.timeIntervalSince1970 * 1000),
                    "usageScope": scope
                ]
                if let model { object["model"] = model }
                if let usage { object["usage"] = usage }
                return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            }

            let today = calendar.startOfDay(for: now).addingTimeInterval(3_600)

            // -- 1. Every provider routed through the CLI counts --
            try writeWire("wd_a/session_1/agents/main/wire.jsonl", lines: [
                // Kimi subscription traffic: must count.
                event(type: "usage.record", model: "kimi-code/kimi-for-coding",
                      usage: ["inputOther": 1_000, "inputCacheRead": 9_000, "inputCacheCreation": 200, "output": 500],
                      time: today),
                // Another provider routed through the same CLI: must count too.
                event(type: "usage.record", model: "opencodex/deepseek/deepseek-flash",
                      usage: ["inputOther": 7_777_777, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 7_777_777],
                      time: today),
                // A provider label that shares no namespace with Kimi at all.
                event(type: "usage.record", model: "RightCode Codex key1 codex/gpt-6-sol",
                      usage: ["inputOther": 5_555_555, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 0],
                      time: today),
                // Context watermark events share the file but are not usage.
                event(type: "token_counting.measured", model: nil, usage: nil, time: today),
                // Unrelated event types must be ignored.
                event(type: "turn.started", model: nil, usage: nil, time: today)
            ])

            let context = RuntimeLoadContext(
                now: now,
                homeDirectory: home,
                cacheDirectory: cache,
                statistics: StatisticsContext(preference: .default, now: now)
            )
            var messages: [String] = []
            guard let usage = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &messages) else {
                failures.append("a wire.jsonl with usage.record events must produce local usage")
                return report(failures)
            }

            expect(usage.lifetimeTokens == 21_121_809,
                   "every provider's usage.record must count (expected 21121809, got \(usage.lifetimeTokens))")
            expect(usage.todayTokens == 21_121_809, "today's tokens must include every provider")
            expect(usage.detailedUsage?.today.estimatedCostForDisplay == nil,
                   "Kimi tokens must not present an unknown API cost as zero")
            expect(usage.threadCount == 1, "one wire file must be reported as one thread")

            let breakdown = usage.detailedUsage!.lifetime.tokens
            expect(breakdown.inputTokens == 13_343_532, "input must sum cache miss, cache read and cache creation")
            expect(breakdown.cachedInputTokens == 9_000, "the cached share must be recorded separately")
            expect(breakdown.cacheWriteInputTokens == 200, "cache creation must be preserved")
            expect(breakdown.outputTokens == 7_778_277, "output tokens must be preserved")
            expect(breakdown.uncachedInputTokens == 13_334_532, "uncached input must exclude the cached share")

            // -- 2. Context watermark events must not inflate the total --
            let watermarkFile = sessions.appendingPathComponent("wd_b/session_2/agents/main/wire.jsonl")
            // A growing context watermark: naive summing would add ~100k.
            try writeWire("wd_b/session_2/agents/main/wire.jsonl", lines: [
                event(type: "token_counting.measured", model: nil, usage: nil, time: today),
                event(type: "token_counting.turn_recorded", model: nil, usage: nil, time: today),
                event(type: "token_counting.truncated", model: nil, usage: nil, time: today),
                event(type: "token_counting.rebased", model: nil, usage: nil, time: today)
            ])
            // Give the watermark events a large `tokens` field so a regression is loud.
            let watermark = """
            {"type":"token_counting.measured","agentId":"main","tokens":999999,"time":\(Int(today.timeIntervalSince1970 * 1000))}
            """
            try Data((watermark + "\n").utf8).write(to: watermarkFile)

            var secondMessages: [String] = []
            let second = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &secondMessages)
            expect(second?.lifetimeTokens == 21_121_809,
                   "token_counting events must never contribute to token totals (got \(second?.lifetimeTokens ?? -1))")

            // -- 3. Sub agents count, and are attributed to the same runtime --
            try writeWire("wd_c/session_3/agents/sub-1/wire.jsonl", lines: [
                event(type: "usage.record", model: "kimi-code/k3",
                      usage: ["inputOther": 100, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 50],
                      time: today, agent: "sub-1")
            ])
            var thirdMessages: [String] = []
            let third = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &thirdMessages)
            expect(third?.lifetimeTokens == 21_121_959,
                   "sub agent usage must be included (expected 21121959, got \(third?.lifetimeTokens ?? -1))")

            // -- 4. Zero-value records must not create phantom activity --
            try writeWire("wd_d/session_4/agents/main/wire.jsonl", lines: [
                event(type: "usage.record", model: "kimi-code/k3",
                      usage: ["inputOther": 0, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 0],
                      time: today)
            ])
            var fourthMessages: [String] = []
            let fourth = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &fourthMessages)
            expect(fourth?.lifetimeTokens == 21_121_959,
                   "an all-zero usage record must be skipped rather than counted")

            // -- 5. Malformed lines and missing fields must not break the scan --
            try writeWire("wd_e/session_5/agents/main/wire.jsonl", lines: [
                "{ this is not json",
                #"{"type":"usage.record","model":"kimi-code/k3"}"#,               // usage missing
                #"{"type":"usage.record","model":"kimi-code/k3","usage":{}}"#,     // usage empty
                event(type: "usage.record", model: "kimi-code/k3",
                      usage: ["inputOther": 10, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 5],
                      time: today)
            ])
            var fifthMessages: [String] = []
            let fifth = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &fifthMessages)
            expect(fifth?.lifetimeTokens == 21_121_974,
                   "malformed and incomplete records must be skipped (expected 21121974, got \(fifth?.lifetimeTokens ?? -1))")

            // -- 6. Missing sessions directory reports why, rather than zero --
            let emptyHome = root.appendingPathComponent("empty-home", isDirectory: true)
            try fileManager.createDirectory(at: emptyHome, withIntermediateDirectories: true)
            let emptyContext = RuntimeLoadContext(
                now: now,
                homeDirectory: emptyHome,
                cacheDirectory: root.appendingPathComponent("empty-cache", isDirectory: true),
                statistics: StatisticsContext(preference: .default, now: now)
            )
            var emptyMessages: [String] = []
            let none = KimiLocalUsageReader().loadLocalUsage(context: emptyContext, messages: &emptyMessages)
            expect(none == nil, "a machine without Kimi sessions must report no local usage")
            expect(emptyMessages.contains(where: { $0.contains(".kimi-code") }),
                   "the missing sessions directory must be named in the message")

            // -- 7. The cache must not double count across repeated reads --
            var cachedMessages: [String] = []
            let firstRead = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &cachedMessages)
            var rereadMessages: [String] = []
            let secondRead = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &rereadMessages)
            expect(firstRead?.lifetimeTokens == secondRead?.lifetimeTokens,
                   "a cached read must return the same totals")

            // -- 8. Time bucketing must follow the statistics calendar --
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            try writeWire("wd_f/session_6/agents/main/wire.jsonl", lines: [
                event(type: "usage.record", model: "kimi-code/k3",
                      usage: ["inputOther": 400, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 100],
                      time: yesterday)
            ])
            var bucketMessages: [String] = []
            let bucketed = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &bucketMessages)
            expect(bucketed?.todayTokens == 21_121_974,
                   "yesterday's tokens must not leak into today (got \(bucketed?.todayTokens ?? -1))")
            expect(bucketed?.sevenDayTokens == 21_122_474, "yesterday must still fall inside the 7 day window")
            expect(bucketed?.dailyBuckets.count == 7, "seven daily buckets must be produced")

            // -- 9. The provider must surface the local slice alongside quota --
            let providerSnapshot = KimiRuntimeProvider().loadLocalSnapshot(context: context)
            expect(providerSnapshot.snapshot.local != nil,
                   "the local slice must populate LocalUsage instead of returning nil")
            expect(providerSnapshot.snapshot.quotaReadSucceeded == false,
                   "the local slice must not claim a successful quota read")
            expect(providerSnapshot.usageSourceLabel.contains("session logs"),
                   "the usage source label must name the local session logs")

            // -- 10. Project attribution comes from the session state.json --
            // Every fixture session so far has no state.json, so nothing may be
            // attributed to a project rather than being guessed.
            var unattributedMessages: [String] = []
            let unattributed = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &unattributedMessages)
            expect(unattributed?.projectBoard == nil || unattributed?.projectBoard?.allProjects.isEmpty == true,
                   "sessions without a recorded cwd must not invent a project")

            try writeState(session: "wd_a/session_1", cwd: "/Users/example/Alpha")
            try writeState(session: "wd_c/session_3", cwd: "/Users/example/Beta")
            try writeState(session: "wd_e/session_5", cwd: "/Users/example/Alpha")
            try writeState(session: "wd_f/session_6", cwd: "/Users/example/Beta")

            var projectMessages: [String] = []
            guard let withProjects = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &projectMessages),
                  let board = withProjects.projectBoard else {
                failures.append("sessions with a recorded cwd must produce a project board")
                return report(failures)
            }
            expect(board.allProjects.count == 2,
                   "two distinct working directories must produce two projects (got \(board.allProjects.count))")

            let alpha = board.allProjects.first { $0.name == "Alpha" }
            let beta = board.allProjects.first { $0.name == "Beta" }
            // Alpha holds session_1 and session_5 (the latter also carries the
            // malformed lines) — assert by reconciliation instead of
            // hard-coding each bucket.
            let projectTotal = board.allProjects.reduce(Int64(0)) { $0 + $1.tokens }
            expect(projectTotal == withProjects.lifetimeTokens,
                   "project tokens must reconcile with lifetime (projects \(projectTotal) vs lifetime \(withProjects.lifetimeTokens))")
            expect(alpha != nil && beta != nil, "both projects must be named from their directory")
            expect(alpha?.fullPath == "/Users/example/Alpha", "the project path must be preserved")
            expect(board.allProjects.first?.tokens ?? 0 >= (board.allProjects.last?.tokens ?? 0),
                   "projects must be ordered by descending tokens")

            // -- 11. A session without a cwd must stay unattributed, not borrow --
            let projectsByPath = Dictionary(uniqueKeysWithValues: board.allProjects.map { ($0.fullPath, $0.tokens) })
            expect(projectsByPath[""] == nil,
                   "an empty path must not appear as a real project when others have paths")

            // -- 12. The history index covers a fixed pair, so every other
            // runtime must be resolved directly instead of waiting on an
            // archive that the index will never publish --
            expect(RuntimeScope.historyIndexedScopes == [.codex, .claudeCode],
                   "the indexed runtimes must stay explicit")
            expect(RuntimeScope.historyUnindexedScopes == [.kimi],
                   "Kimi must be recognised as not covered by the history index")
            expect(Set(RuntimeScope.historyIndexedScopes).union(RuntimeScope.historyUnindexedScopes)
                    == Set(RuntimeScope.allCases),
                   "every runtime must be either indexed or directly resolved")

            // -- 13. Tool calls aggregate; Skill never counts as a plain tool --
            func llmRequest(alias: String, effort: String?, time: Date) -> String {
                var object: [String: Any] = [
                    "type": "llm.request",
                    "agentId": "main",
                    "kind": "loop",
                    "modelAlias": alias,
                    "time": Int(time.timeIntervalSince1970 * 1000)
                ]
                if let effort { object["thinkingEffort"] = effort }
                return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            }
            func toolCall(name: String, skill: String?, time: Date) -> String {
                var event: [String: Any] = ["type": "tool.call", "name": name]
                if let skill { event["args"] = ["skill": skill] }
                let object: [String: Any] = [
                    "type": "context.append_loop_event",
                    "agentId": "main",
                    "event": event,
                    "time": Int(time.timeIntervalSince1970 * 1000)
                ]
                return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            }

            let requestStart = today.addingTimeInterval(600)
            try writeWire("wd_g/session_7/agents/main/wire.jsonl", lines: [
                // A completed call: 10s, 100 output tokens.
                llmRequest(alias: "kimi-code/k3", effort: "high", time: requestStart),
                event(type: "usage.record", model: "kimi-code/k3",
                      usage: ["inputOther": 1_000, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 100],
                      time: requestStart.addingTimeInterval(10)),
                // A retry: the second request owns the record, the first lingers.
                llmRequest(alias: "kimi-code/k3", effort: "high", time: requestStart.addingTimeInterval(60)),
                llmRequest(alias: "kimi-code/k3", effort: "high", time: requestStart.addingTimeInterval(62)),
                event(type: "usage.record", model: "kimi-code/k3",
                      usage: ["inputOther": 500, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 50],
                      time: requestStart.addingTimeInterval(72)),
                // An abandoned request: 31 minutes is over the sample ceiling.
                llmRequest(alias: "kimi-code/k3", effort: "high", time: requestStart.addingTimeInterval(120)),
                event(type: "usage.record", model: "kimi-code/k3",
                      usage: ["inputOther": 100, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 10],
                      time: requestStart.addingTimeInterval(120 + 31 * 60)),
                #"{"type":"agent.turn.ended","turnId":0,"time":1790785824603}"#,
                // Another provider's traffic counts too, paired by its own model.
                llmRequest(alias: "opencodex/deepseek/deepseek-flash", effort: nil, time: requestStart.addingTimeInterval(200)),
                event(type: "usage.record", model: "opencodex/deepseek/deepseek-flash",
                      usage: ["inputOther": 9, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 9],
                      time: requestStart.addingTimeInterval(205)),
                toolCall(name: "Bash", skill: nil, time: requestStart.addingTimeInterval(300)),
                toolCall(name: "Bash", skill: nil, time: requestStart.addingTimeInterval(301)),
                toolCall(name: "Read", skill: nil, time: requestStart.addingTimeInterval(302)),
                toolCall(name: "Skill", skill: "test-skill", time: requestStart.addingTimeInterval(303))
            ])
            try writeWire("wd_h/session_8/agents/main/wire.jsonl", lines: [
                event(type: "usage.record", model: "kimi-code/kimi-for-coding",
                      usage: ["inputOther": 20, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 5],
                      time: requestStart.addingTimeInterval(400)),
                toolCall(name: "Skill", skill: "test-skill", time: requestStart.addingTimeInterval(401)),
                toolCall(name: "Skill", skill: "other-skill", time: requestStart.addingTimeInterval(402))
            ])

            var toolMessages: [String] = []
            guard let withTools = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &toolMessages) else {
                failures.append("tool fixtures must still produce local usage")
                return report(failures)
            }
            let toolsByName = Dictionary(uniqueKeysWithValues: withTools.toolUsages.map { ($0.name, $0.callCount) })
            expect(toolsByName["Bash"] == 2, "Bash must be counted twice (got \(toolsByName["Bash"] ?? -1))")
            expect(toolsByName["Read"] == 1, "Read must be counted once")
            expect(toolsByName["Skill"] == nil, "Skill invocations must not appear as plain tool calls")

            // -- 14. Skill loads group by name; resolvable skills get an estimate --
            let skillDirectory = home.appendingPathComponent(".agents/skills/test-skill", isDirectory: true)
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            let skillText = "---\nname: test-skill\ndescription: fixture\n---\nhello world\n"
            try Data(skillText.utf8).write(to: skillDirectory.appendingPathComponent("SKILL.md"))

            var skillMessages: [String] = []
            guard let withSkills = KimiLocalUsageReader().loadLocalUsage(context: context, messages: &skillMessages) else {
                failures.append("skill fixtures must still produce local usage")
                return report(failures)
            }
            let resolvedSkill = withSkills.skillUsages.first { $0.name == "test-skill" }
            expect(resolvedSkill?.loadCount == 2,
                   "test-skill must count two loads (got \(resolvedSkill?.loadCount ?? -1))")
            expect(resolvedSkill?.threadCount == 2,
                   "loads from two sessions must count as two threads")
            expect(resolvedSkill?.staticTokenEstimate != nil && resolvedSkill?.staticByteCount == Int64(skillText.utf8.count),
                   "a resolved SKILL.md must carry the file's byte count and a token estimate")
            expect(resolvedSkill?.sourceLabel == "agents",
                   "a skill under .agents/skills must be labelled agents (got \(resolvedSkill?.sourceLabel ?? "nil"))")
            let unresolvedSkill = withSkills.skillUsages.first { $0.name == "other-skill" }
            expect(unresolvedSkill?.loadCount == 1 && unresolvedSkill?.staticTokenEstimate == nil,
                   "an unresolvable skill keeps its count without inventing a file")
            expect(unresolvedSkill?.sourceLabel == "Kimi Code",
                   "an unresolvable skill reads as coming from Kimi Code")

            // -- 15. Inference samples pair requests with their usage records --
            let inference = withSkills.inferencePerformance
            let todayGroup = inference?.today?.groups.first { $0.model == "k3" && $0.effort == "high" }
            expect(todayGroup?.callCount == 2,
                   "only the two completed sub-30-minute calls may sample (got \(todayGroup?.callCount ?? -1))")
            expect(todayGroup != nil && abs(todayGroup!.averageDurationSeconds - 10.0) < 0.01,
                   "the retry must pair with the latest request (avg \(todayGroup?.averageDurationSeconds ?? -1)s)")
            let otherProviderGroup = inference?.today?.groups.first { $0.model.contains("deepseek") }
            expect(otherProviderGroup?.callCount == 1,
                   "another provider's calls must sample under their own model (got \(otherProviderGroup?.callCount ?? -1))")
            expect(otherProviderGroup != nil && abs(otherProviderGroup!.averageDurationSeconds - 5.0) < 0.01,
                   "the other provider's record must pair with its own request (avg \(otherProviderGroup?.averageDurationSeconds ?? -1)s)")

            // -- 16. Model trends split per model and reconcile with the total --
            let modelTrends = withSkills.usageTrend?.modelTrends ?? []
            expect(modelTrends.count == 4,
                   "k3, kimi-for-coding and the two other providers must each get a trend (got \(modelTrends.count))")
            let trendTotal = modelTrends.reduce(Int64(0)) { total, trend in
                total + trend.dayBuckets.reduce(Int64(0)) { $0 + $1.tokens }
            }
            expect(trendTotal == withSkills.lifetimeTokens,
                   "per-model day buckets must reconcile with lifetime (\(trendTotal) vs \(withSkills.lifetimeTokens))")
            expect(modelTrends.first?.summary.sevenDay.tokens.visibleTotalTokens
                    ?? 0 >= modelTrends.last?.summary.sevenDay.tokens.visibleTotalTokens ?? 0,
                   "model trends must sort by recent usage")

            // -- 17. Project thread counts reflect the contributing sessions --
            let alphaProject = withSkills.projectBoard?.allProjects.first { $0.name == "Alpha" }
            expect(alphaProject?.threadCount == 2,
                   "Alpha spans two sessions and must say so (got \(alphaProject?.threadCount ?? -1))")
        } catch {
            failures.append("Kimi local usage self-test threw: \(error)")
        }

        return report(failures) && runRegression()
    }

    /// Runs each boundary independently so a pre-fix crash cannot hide the
    /// other regression results in an isolated harness.
    static func runRegression(_ suite: String = "all") -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("codexu-kimi-regression-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let now = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append("\(suite): \(message)") }
        }
        func context(_ name: String) -> RuntimeLoadContext {
            RuntimeLoadContext(
                now: now,
                homeDirectory: root.appendingPathComponent("\(name)/home"),
                cacheDirectory: root.appendingPathComponent("\(name)/cache"),
                statistics: StatisticsContext(preference: .init(selection: .utc, fixedIdentifier: "UTC"), now: now)
            )
        }
        func record(_ usage: String, at date: Date = now) -> String {
            "{\"type\":\"usage.record\",\"model\":\"kimi-code/k3\",\"usageScope\":\"turn\",\"usage\":\(usage),\"time\":\(Int64(date.timeIntervalSince1970 * 1_000))}"
        }
        @discardableResult
        func write(_ context: RuntimeLoadContext, _ lines: [String], agent: String = "main") throws -> URL {
            let file = context.homeDirectory.appendingPathComponent(".kimi-code/sessions/workspace/session_1/agents/\(agent)/wire.jsonl")
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
            return file
        }
        func read(_ context: RuntimeLoadContext, messages: inout [String]) -> LocalUsage? {
            KimiLocalUsageReader().loadLocalUsage(context: context, messages: &messages)
        }
        do {
            if suite == "all" || suite == "cost" {
                let ctx = context("unknown-cost")
                try write(ctx, [record(#"{"inputOther":10}"#)])
                var messages: [String] = []
                guard let local = read(ctx, messages: &messages), let detailed = local.detailedUsage else {
                    failures.append("\(suite): known token usage must remain available without pricing")
                    return report(failures)
                }
                expect(detailed.today.estimatedCostForDisplay == nil, "today's unknown cost must not display as zero")
                expect(detailed.sevenDay.estimatedCostForDisplay == nil, "seven-day unknown cost must not display as zero")
                expect(detailed.month.estimatedCostForDisplay == nil, "monthly unknown cost must not display as zero")
                expect(detailed.lifetime.estimatedCostForDisplay == nil, "lifetime unknown cost must not display as zero")
                if let trend = local.usageTrend {
                    expect(trend.month.estimatedCostForDisplay == nil, "trend monthly cost must remain unavailable")
                    expect(trend.summary.sevenDay.estimatedCostForDisplay == nil, "trend summary cost must remain unavailable")
                    expect(trend.dayBuckets.allSatisfy { $0.usage.estimatedCostForDisplay == nil }, "daily costs, including empty days, must remain unavailable")
                    expect(trend.heatmapWeeks.flatMap { $0 }.allSatisfy { $0.usage?.estimatedCostForDisplay == nil }, "heatmap costs must remain unavailable")
                    expect(trend.modelTrends?.allSatisfy { model in
                        model.summary.sevenDay.estimatedCostForDisplay == nil
                            && model.dayBuckets.allSatisfy { $0.usage.estimatedCostForDisplay == nil }
                    } == true, "model costs must remain unavailable")
                } else {
                    failures.append("\(suite): known token usage must still produce a trend")
                }
                var aggregate = PricedTokenUsage.zero
                aggregate.add(tokens: detailed.month.tokens, costUSD: detailed.month.estimatedCostUSD,
                              hasEstimatedCost: detailed.month.hasEstimatedCost)
                expect(aggregate.tokens.totalTokens == 10, "unknown pricing must not discard aggregate tokens")
                expect(aggregate.estimatedCostForDisplay == nil, "an aggregate containing unknown cost must not display zero")
            }
            if suite == "all" || suite == "read-failure" {
                // Caching an open failure makes restored permissions invisible.
                let ctx = context("permissions")
                try write(ctx, [record(#"{"inputOther":50}"#)], agent: "other")
                let file = try write(ctx, [record(#"{"inputOther":200}"#)])
                try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
                var failedMessages: [String] = []
                expect(read(ctx, messages: &failedMessages)?.lifetimeTokens == 50,
                       "unreadable logs must not replace readable usage")
                expect(!failedMessages.isEmpty, "an open failure must be reported even when another log is readable")
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                var retriedMessages: [String] = []
                expect(read(ctx, messages: &retriedMessages)?.lifetimeTokens == 250,
                       "restoring permissions without changing size/mtime must retry the failed log")
                expect(retriedMessages.isEmpty, "a recovered log must clear the read failure")
            }
            if suite == "all" || suite == "partial-read" {
                // Real file data is read first; only the second I/O operation
                // fails. Treating that error as EOF would cache a partial sum.
                let ctx = context("partial")
                let first = record(#"{"inputOther":100}"#)
                try write(ctx, [first, record(#"{"inputOther":200}"#)])
                var readCount = 0
                let reader = KimiLocalUsageReader(readChunk: { handle in
                    readCount += 1
                    if readCount == 2 { throw CocoaError(.fileReadUnknown) }
                    return try handle.read(upToCount: first.utf8.count + 1)
                })
                var failedMessages: [String] = []
                expect(reader.loadLocalUsage(context: ctx, messages: &failedMessages) == nil,
                       "a prefix before a read error must not be published as a complete file")
                expect(!failedMessages.isEmpty, "a mid-stream read failure must be reported")
                var recoveredMessages: [String] = []
                expect(read(ctx, messages: &recoveredMessages)?.lifetimeTokens == 300,
                       "a failed partial scan must retry the file with its unchanged fingerprint")
            }
            if suite == "all" || suite == "token-values" {
                let ctx = context("invalid-counters")
                let invalid = [
                    #"{"inputOther":"inf"}"#, #"{"output":"NaN"}"#,
                    #"{"inputCacheRead":"9223372036854775808"}"#,
                    #"{"inputCacheCreation":1e30}"#, #"{"inputOther":-1}"#,
                    #"{"output":1.5}"#, #"{"inputOther":"broken","output":9}"#
                ]
                try write(ctx, invalid.map { record($0) } + [record(#"{"inputOther":10,"inputCacheRead":20,"inputCacheCreation":30,"output":40}"#)])
                for _ in 0..<2 {
                    var messages: [String] = []
                    let usage = read(ctx, messages: &messages)
                    expect(usage?.lifetimeTokens == 100, "invalid counters must be skipped while the next valid record survives")
                    expect(usage?.detailedUsage?.lifetime.tokens.inputTokens == 60, "all three valid input counters must be preserved")
                    expect(usage?.detailedUsage?.lifetime.tokens.cacheWriteInputTokens == 30, "cache creation must remain separate")
                    expect(usage?.detailedUsage?.tokenEventCount == 1, "invalid records must not become usage events")
                    expect(!messages.isEmpty, "skipped invalid counters must be reported on cold and cached reads")
                }
                let edge = context("exact-integer")
                try write(edge, [record(#"{"inputOther":9223372036854775807}"#)])
                var edgeMessages: [String] = []
                expect(read(edge, messages: &edgeMessages)?.lifetimeTokens == Int64.max,
                       "a valid integer at Int64.max must not lose precision through Double")
            }
            if suite == "all" || suite == "record-overflow" {
                let ctx = context("record-overflow")
                try write(ctx, [
                    record(#"{"inputOther":5000000000000000000,"inputCacheRead":5000000000000000000}"#),
                    record(#"{"inputCacheRead":4000000000000000000,"inputCacheCreation":4000000000000000000,"output":4000000000000000000}"#),
                    record(#"{"output":25}"#)
                ])
                var messages: [String] = []
                expect(read(ctx, messages: &messages)?.lifetimeTokens == 25,
                       "overflow in the input sum or four-counter total must discard only that record")
                expect(!messages.isEmpty, "record sum overflow must be reported")
            }
            if suite == "all" || suite == "aggregate-overflow" {
                for separateFiles in [false, true] {
                    let ctx = context("aggregate-\(separateFiles)")
                    let input = record(#"{"inputOther":5000000000000000000}"#)
                    let output = record(#"{"output":5000000000000000000}"#)
                    try write(ctx, separateFiles ? [input] : [input, output])
                    if separateFiles { try write(ctx, [output], agent: "other") }
                    for _ in 0..<2 {
                        var messages: [String] = []
                        expect(read(ctx, messages: &messages) == nil,
                               "an unrepresentable total must be unavailable rather than trap or wrap")
                        expect(!messages.isEmpty, "aggregate overflow must be explained on cold and cached reads")
                    }
                }
                // Large representable totals must survive project, day, model
                // and inference aggregation, including their warm-cache path.
                let ctx = context("large-valid")
                try write(ctx, [
                    #"{"type":"llm.request","modelAlias":"kimi-code/k3","time":1791892799000}"#,
                    record(#"{"output":4000000000000000000}"#),
                    #"{"type":"llm.request","modelAlias":"kimi-code/k3","time":1791892799000}"#,
                    record(#"{"output":4000000000000000000}"#)
                ])
                let state = ctx.homeDirectory.appendingPathComponent(".kimi-code/sessions/workspace/session_1/state.json")
                try JSONSerialization.data(withJSONObject: ["cwd": root.appendingPathComponent("large-project").path]).write(to: state)
                for _ in 0..<2 {
                    var messages: [String] = []
                    let usage = read(ctx, messages: &messages)
                    expect(usage?.lifetimeTokens == 8_000_000_000_000_000_000, "a large representable lifetime total must remain exact")
                    expect(usage?.dailyBuckets.reduce(Int64(0), { $0 + $1.tokens }) == 8_000_000_000_000_000_000,
                           "large daily totals must remain exact")
                    expect(usage?.projectBoard?.allProjects.first?.tokens == 8_000_000_000_000_000_000,
                           "large project totals must remain exact")
                    expect(usage?.usageTrend?.modelTrends?.first?.summary.sevenDay.tokens.totalTokens == 8_000_000_000_000_000_000,
                           "large per-model totals must remain exact")
                    expect(usage?.inferencePerformance?.today?.groups.first?.outputTokens == 8_000_000_000_000_000_000,
                           "large inference output sums must remain exact")
                }
            }
            if suite == "all" || suite == "future" {
                let ctx = context("future")
                try write(ctx, [
                    record(#"{"inputOther":10}"#, at: now.addingTimeInterval(-3_600)),
                    record(#"{"inputOther":20}"#, at: now.addingTimeInterval(-86_400)),
                    record(#"{"inputOther":100}"#, at: now.addingTimeInterval(86_400)),
                    #"{"type":"llm.request","modelAlias":"kimi-code/k3","time":1791896399000}"#,
                    record(#"{"output":200}"#, at: now.addingTimeInterval(3_600))
                ])
                for _ in 0..<2 {
                    var messages: [String] = []
                    let usage = read(ctx, messages: &messages)
                    expect(usage?.lifetimeTokens == 330, "lifetime must preserve consumed usage even when its clock was ahead")
                    expect(usage?.todayTokens == 10, "today must exclude later records even on the same calendar day")
                    expect(usage?.sevenDayTokens == 30, "seven days must exclude all records after now")
                    expect(usage?.detailedUsage?.month.tokens.totalTokens == 30, "the current month must exclude records after now")
                    expect(usage?.dailyBuckets.reduce(Int64(0), { $0 + $1.tokens }) == 30, "daily buckets must agree with the current windows")
                    expect(usage?.usageTrend?.dayBuckets.reduce(Int64(0), { $0 + $1.tokens }) == 30, "historical trend must not contain future usage")
                    expect(usage?.usageTrend?.modelTrends?.first?.summary.sevenDay.tokens.totalTokens == 30, "model trends must agree with the overall window")
                    expect(usage?.inferencePerformance == nil, "future completions must not enter current inference statistics")
                    expect(usage?.lastUpdatedAt == now.addingTimeInterval(-3_600), "last activity must not jump into the future")
                }
            }
        } catch {
            failures.append("\(suite): regression threw: \(error)")
        }
        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("Kimi local usage self-test passed")
            return true
        }
        failures.forEach { print("Kimi local usage self-test failed: \($0)") }
        return false
    }
}
