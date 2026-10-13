import Foundation

/// Fixture-driven coverage for the Kimi AI leadership reader.
///
/// The fixtures mirror the real session layout: one `state.json` roster per
/// session plus one `wire.jsonl` per agent. Turn boundaries are the only log
/// content the reader may consume, so the fixtures also carry message and usage
/// payloads that must never surface as intervals.
enum KimiLeadershipSelfTest {
    private enum ProbeError: Error { case unreadable }

    static func run() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("codexu-kimi-leadership-\(UUID().uuidString)", isDirectory: true)
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
            // Keep every fixture turn before the snapshot even when the self-test
            // is invoked shortly after midnight.
            let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
            let alpha = "/Users/tester/Alpha"

            func writeState(session relative: String, object: [String: Any]) throws {
                let url = sessions.appendingPathComponent(relative).appendingPathComponent("state.json")
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(try JSONSerialization.data(withJSONObject: object)).write(to: url)
            }
            func writeWire(session relative: String, agent: String, lines: [String]) throws -> URL {
                let url = sessions.appendingPathComponent(relative)
                    .appendingPathComponent("agents")
                    .appendingPathComponent(agent)
                    .appendingPathComponent("wire.jsonl")
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
                return url
            }
            func line(_ object: [String: Any]) -> String {
                String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            }
            func milliseconds(_ date: Date) -> Double { date.timeIntervalSince1970 * 1_000 }
            func turnStarted(_ turnID: String, at date: Date) -> String {
                line(["type": "agent.turn.started", "turnId": turnID, "kind": "user", "time": milliseconds(date)])
            }
            func turnEnded(_ turnID: String, at date: Date) -> String {
                line(["type": "agent.turn.ended", "turnId": turnID, "kind": "user", "outcome": "completed", "time": milliseconds(date)])
            }

            let context = RuntimeLoadContext(
                now: now,
                homeDirectory: home,
                cacheDirectory: cache,
                statistics: StatisticsContext(preference: .default, now: now)
            )

            // -- 1. A main agent and a spawned subagent share one session --
            try writeState(session: "wd_a/session_main", object: ["cwd": alpha, "agents": ["main": ["type": "main"]]])
            let mainStart = now.addingTimeInterval(-7_200)
            let mainEnd = now.addingTimeInterval(-6_000)
            _ = try writeWire(session: "wd_a/session_main", agent: "main", lines: [
                turnStarted("1", at: mainStart),
                turnEnded("1", at: mainEnd),
                // An unfinished turn is the running one and must not be counted.
                turnStarted("2", at: now.addingTimeInterval(-60)),
                // Content-bearing lines must never contribute.
                line(["type": "agent.message.appended", "kind": "assistant", "time": milliseconds(now), "message": ["role": "assistant", "content": "secret"]]),
                line(["type": "usage.record", "model": "kimi-code/k3", "time": milliseconds(now), "usage": ["inputOther": 10, "inputCacheRead": 0, "inputCacheCreation": 0, "output": 5]])
            ])

            try writeState(session: "wd_a/session_sub", object: [
                "cwd": alpha,
                "agents": [
                    "main": ["type": "main"],
                    "agent-0": ["type": "sub", "parentAgentId": "main"]
                ]
            ])
            let subStart = now.addingTimeInterval(-5_000)
            let subEnd = now.addingTimeInterval(-4_000)
            _ = try writeWire(session: "wd_a/session_sub", agent: "main", lines: [
                turnStarted("1", at: subStart.addingTimeInterval(-600)),
                turnEnded("1", at: subStart.addingTimeInterval(-300))
            ])
            _ = try writeWire(session: "wd_a/session_sub", agent: "agent-0", lines: [
                turnStarted("1", at: subStart),
                turnEnded("1", at: subEnd)
            ])

            // -- 2. Older logs only record a duration, and only a workDir --
            let legacyEnd = now.addingTimeInterval(-2_000)
            try writeState(session: "wd_legacy/session_legacy", object: [
                "workDir": "/Users/tester/Beta",
                "agents": ["main": ["type": "main"]]
            ])
            _ = try writeWire(session: "wd_legacy/session_legacy", agent: "main", lines: [
                line(["type": "turn.ended", "turnId": "7", "reason": "completed", "durationMs": 120_000, "time": milliseconds(legacyEnd)]),
                // A turn longer than a day is a log artefact.
                line(["type": "turn.ended", "turnId": "8", "reason": "completed", "durationMs": 172_800_000, "time": milliseconds(legacyEnd)])
            ])

            // -- 3. An agent the roster does not describe is left out --
            try writeState(session: "wd_unknown/session_unknown", object: ["cwd": alpha, "agents": ["main": ["type": "main"]]])
            _ = try writeWire(session: "wd_unknown/session_unknown", agent: "ghost", lines: [
                turnStarted("1", at: now.addingTimeInterval(-900)),
                turnEnded("1", at: now.addingTimeInterval(-800))
            ])

            // -- 4. Logs older than the lookback window are ignored --
            let staleWire = try writeWire(session: "wd_a/session_stale", agent: "main", lines: [
                turnStarted("1", at: now.addingTimeInterval(-4_000)),
                turnEnded("1", at: now.addingTimeInterval(-3_900))
            ])
            try writeState(session: "wd_a/session_stale", object: ["cwd": alpha, "agents": ["main": ["type": "main"]]])
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 24 * 3_600)], ofItemAtPath: staleWire.path)

            let reader = KimiLeadershipReader()
            let evidence = reader.load(context: context)
            let intervalsByWorker = Dictionary(grouping: evidence.intervals, by: \.workerID)

            expect(evidence.workers.count == 4,
                   "one worker per attributable agent (expected 4, got \(evidence.workers.count))")
            expect(intervalsByWorker["kimi:main:session_main"]?.count == 1,
                   "the unfinished main turn must not be counted")
            expect(intervalsByWorker["kimi:subagent:session_sub:agent-0"]?.count == 1,
                   "a subagent's own turn must be attributed to the subagent")
            expect(intervalsByWorker["kimi:main:session_legacy"]?.count == 1,
                   "a legacy turn.ended duration must produce exactly one interval")
            expect(intervalsByWorker["kimi:main:session_sub"]?.count == 1,
                   "a session's own main turns must be counted alongside its subagents")
            expect(evidence.intervals.count == 4,
                   "message, usage and oversized turns must not produce intervals (got \(evidence.intervals.count))")

            let mainWorker = evidence.workers.first { $0.id == "kimi:main:session_main" }
            expect(mainWorker?.kind == .main, "the roster type main must map to a main worker")
            expect(mainWorker?.parentID == nil, "a main worker must not claim a parent")
            expect(mainWorker?.projectID == UsageLeadershipAdapter.projectID(runtime: "kimi", path: alpha),
                   "project identity must match the history index hash")
            expect(mainWorker?.projectName == "Alpha", "the project name must be the working directory's last component")
            expect(evidence.projectPaths[mainWorker?.projectID ?? ""] == alpha,
                   "the project path must be carried for index naming")

            let subWorker = evidence.workers.first { $0.id == "kimi:subagent:session_sub:agent-0" }
            expect(subWorker?.kind == .subagent, "the roster type sub must map to a subagent worker")
            expect(subWorker?.parentID == "kimi:main:session_sub", "a subagent must point at its session's main worker")
            expect(subWorker?.projectName == "Alpha", "a subagent inherits the session working directory")
            expect(intervalsByWorker["kimi:subagent:session_sub:agent-0"]?.allSatisfy(\.isAutonomous) == true,
                   "subagent turns must count as autonomous work")
            expect(intervalsByWorker["kimi:main:session_main"]?.allSatisfy { !$0.isAutonomous } == true,
                   "main-agent turns are not autonomous work")
            expect(evidence.workers.contains { $0.id.contains("ghost") } == false,
                   "an agent missing from the roster must be left out")
            expect(evidence.workers.contains { $0.id == "kimi:main:session_stale" } == false,
                   "logs outside the lookback window must be ignored")

            let mainInterval = intervalsByWorker["kimi:main:session_main"]?.first
            expect(mainInterval.map { abs($0.startAt.timeIntervalSince(mainStart)) < 0.5 } == true,
                   "the paired start must be the agent.turn.started timestamp")
            expect(mainInterval.map { abs($0.endAt.timeIntervalSince(mainEnd)) < 0.5 } == true,
                   "the paired end must be the agent.turn.ended timestamp")
            expect(mainInterval?.quality == .fact, "logged turn boundaries are factual evidence")
            expect(mainInterval?.runtime == .kimi, "Kimi intervals must carry the Kimi runtime")
            expect(mainInterval?.id == "kimi:session_main:main:1",
                   "turn identifiers repeat per file and need the session and agent prefix")

            let legacyInterval = intervalsByWorker["kimi:main:session_legacy"]?.first
            expect(legacyInterval.map { abs($0.endAt.timeIntervalSince(legacyEnd)) < 0.5 } == true,
                   "a duration-only turn ends at its recorded time")
            expect(legacyInterval.map { abs($0.endAt.timeIntervalSince($0.startAt) - 120) < 0.5 } == true,
                   "a duration-only turn starts durationMs earlier")
            let legacyWorker = evidence.workers.first { $0.id == "kimi:main:session_legacy" }
            expect(legacyWorker?.projectName == "Beta", "workDir must be read when cwd is absent")

            // -- 5. The parsed turns are cached by fingerprint --
            let cacheURL = cache.appendingPathComponent("kimi-leadership-v1.json")
            expect(fileManager.fileExists(atPath: cacheURL.path), "the turn cache must be written")
            let cachedEvidence = reader.load(context: context)
            expect(cachedEvidence.intervals.count == evidence.intervals.count,
                   "a cached refresh must return the same evidence")
            expect(cachedEvidence.workers.map(\.id) == evidence.workers.map(\.id),
                   "a cached refresh must keep worker identity")

            let extraStart = now.addingTimeInterval(-300)
            _ = try writeWire(session: "wd_a/session_main", agent: "main", lines: [
                turnStarted("1", at: mainStart),
                turnEnded("1", at: mainEnd),
                turnStarted("3", at: extraStart),
                turnEnded("3", at: extraStart.addingTimeInterval(120))
            ])
            let refreshed = reader.load(context: context)
            expect(Dictionary(grouping: refreshed.intervals, by: \.workerID)["kimi:main:session_main"]?.count == 2,
                   "an appended turn must invalidate that file's cache entry")
            expect(refreshed.intervals.count == 5, "only the changed file may contribute a new interval")

            // -- 6. A failed read never publishes a partial file --
            let failingRoot = root.appendingPathComponent("failing", isDirectory: true)
            let failingCache = root.appendingPathComponent("failing-cache", isDirectory: true)
            let failingSessions = failingRoot.appendingPathComponent(".kimi-code/sessions", isDirectory: true)
            let failingSession = failingSessions.appendingPathComponent("wd_x/session_x")
            try fileManager.createDirectory(at: failingSession.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
            let failingState: [String: Any] = ["cwd": alpha, "agents": ["main": ["type": "main"]]]
            try Data(try JSONSerialization.data(withJSONObject: failingState)).write(to: failingSession.appendingPathComponent("state.json"))
            try Data((turnStarted("1", at: now.addingTimeInterval(-900)) + "\n").utf8)
                .write(to: failingSession.appendingPathComponent("agents/main/wire.jsonl"))
            let failingContext = RuntimeLoadContext(
                now: now,
                homeDirectory: failingRoot,
                cacheDirectory: failingCache,
                statistics: StatisticsContext(preference: .default, now: now)
            )
            let failing = KimiLeadershipReader(readChunk: { _ in throw ProbeError.unreadable }).load(context: failingContext)
            expect(failing.intervals.isEmpty, "a failed read must not publish partial turns")
            expect(failing.error == .cacheInvalid, "read failures must reach the history completeness gate")
            let failingCacheData = try? Data(contentsOf: failingCache.appendingPathComponent("kimi-leadership-v1.json"))
            let failingEntries = failingCacheData
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["entries"] as? [String: Any]
            expect((failingEntries ?? [:]).keys.contains { $0.contains("session_x") } == false,
                   "a failed read must not be cached")

            // A later timeout must retain completed files so retries make progress.
            let completedTurn = turnStarted("1", at: now.addingTimeInterval(-900)) + "\n"
                + turnEnded("1", at: now.addingTimeInterval(-800)) + "\n"
            try Data(completedTurn.utf8).write(to: failingSession.appendingPathComponent("agents/main/wire.jsonl"))
            let subDirectory = failingSession.appendingPathComponent("agents/sub")
            try fileManager.createDirectory(at: subDirectory, withIntermediateDirectories: true)
            try Data(completedTurn.utf8).write(to: subDirectory.appendingPathComponent("wire.jsonl"))
            try Data(try JSONSerialization.data(withJSONObject: [
                "cwd": alpha,
                "agents": ["main": ["type": "main"], "sub": ["type": "sub", "parentAgentId": "main"]]
            ])).write(to: failingSession.appendingPathComponent("state.json"))
            var timeoutReads = 0
            let timedOut = KimiLeadershipReader(readChunk: { handle in
                timeoutReads += 1
                if timeoutReads > 2 { throw UsageIndexError.resourceLimited }
                return try handle.read(upToCount: 64 * 1_024)
            }).load(context: failingContext)
            expect(timedOut.error == .resourceLimited && timedOut.intervals.isEmpty && timedOut.workers.isEmpty,
                   "a timeout after a complete file must still withhold the partial dashboard")
            let progressData = try? Data(contentsOf: failingCache.appendingPathComponent("kimi-leadership-v1.json"))
            let progressEntries = progressData
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["entries"] as? [String: Any]
            expect(progressEntries?.count == 1,
                   "a timeout must cache the completed file without caching the failed file")
            var retryReads = 0
            let retried = KimiLeadershipReader(readChunk: { handle in
                retryReads += 1
                return try handle.read(upToCount: 64 * 1_024)
            }).load(context: failingContext)
            expect(retried.error == nil && retried.intervals.count == 2,
                   "retry must publish both agents only after the remaining file completes")
            expect(retryReads == 2,
                   "retry must read only the uncached file instead of starting over (read \(retryReads) chunks)")
            try fileManager.removeItem(at: subDirectory)

            // Oversized message bodies must not consume the whole read budget
            // or hide the valid turn boundary on the following line.
            let oversizedHandle = try FileHandle(forWritingTo: failingSession.appendingPathComponent("agents/main/wire.jsonl"))
            try oversizedHandle.truncate(atOffset: 0)
            try oversizedHandle.write(contentsOf: Data((turnStarted("large", at: now.addingTimeInterval(-900))
                + "\n{\"type\":\"agent.message.appended\",\"content\":\"").utf8))
            let bodyChunk = Data(repeating: 120, count: 64 * 1_024)
            for _ in 0..<768 { try oversizedHandle.write(contentsOf: bodyChunk) }
            try oversizedHandle.write(contentsOf: Data(("\"}\n"
                + turnEnded("large", at: now.addingTimeInterval(-800)) + "\n").utf8))
            try oversizedHandle.close()
            let oversizedEvidence = KimiLeadershipReader().load(context: failingContext)
            expect(oversizedEvidence.error == nil && oversizedEvidence.intervals.count == 1,
                   "a large message must be skipped within budget without losing the following turn end")

            // An unreadable roster must not become a successful, smaller dashboard.
            try Data("invalid state".utf8).write(to: failingSession.appendingPathComponent("state.json"))
            expect(LeadershipDataReader().load(context: failingContext).reports.isEmpty,
                   "unreadable Kimi metadata must make the direct dashboard unavailable")

            // More than 20,000 recent turns must not silently discard older work.
            try Data(try JSONSerialization.data(withJSONObject: failingState))
                .write(to: failingSession.appendingPathComponent("state.json"))
            let crowded = (0...20_000).map { index in
                line(["type": "turn.ended", "turnId": index, "durationMs": 1_000,
                      "time": milliseconds(now.addingTimeInterval(-Double(index + 1) * 2))])
            }.joined(separator: "\n") + "\n"
            try Data(crowded.utf8).write(to: failingSession.appendingPathComponent("agents/main/wire.jsonl"))
            expect(LeadershipDataReader().load(context: failingContext).reports.isEmpty,
                   "over-budget turns must not publish a truncated direct dashboard")

            // Unfinished turns also consume the parser budget, before materialization.
            var reads = 0
            let bounded = KimiLeadershipReader(readChunk: { _ in
                reads += 1
                guard reads <= 25_000 else { return nil }
                return Data((turnStarted(String(reads), at: now.addingTimeInterval(-60)) + "\n").utf8)
            }).load(context: RuntimeLoadContext(now: now, homeDirectory: failingRoot,
                cacheDirectory: root.appendingPathComponent("bounded-cache"), statistics: context.statistics))
            expect(reads <= 20_001, "unmatched turn state must stop growing at the parser budget (read \(reads) records)")
            expect(bounded.error == .resourceLimited, "over-budget parsing must report a resource limit")
        } catch {
            failures.append("fixtures threw: \(error)")
        }
        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("Kimi leadership self-test passed")
            return true
        }
        failures.forEach { print("Kimi leadership self-test failed: \($0)") }
        return false
    }
}
