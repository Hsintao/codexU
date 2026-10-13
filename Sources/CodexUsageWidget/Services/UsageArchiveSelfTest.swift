import Foundation

enum UsageArchiveSelfTest {
    static func run() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func check(_ value: Bool) throws { if !value { throw UsageIndexError.databaseFailure } }
        do {
            let store = try UsageIndexStore(directory: directory)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let statistics = StatisticsContext(preference: .init(selection: .utc, fixedIdentifier: "UTC"), now: now)
            let context = try store.ensureProjectionContext(root: "fixture", statistics: statistics, now: now)
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tests/fixtures/history-index/codex-counters.jsonl")
            let parsed = try UsageStreamParser.readCodex(url: url, targetEnd: UInt64(Data(contentsOf: url).count), checkpoint: CodexIndexCheckpoint())
            let scan = try store.beginDiscovery(root: "fixture", runtime: "codex", now: now)
            for source in ["parent", "child"] {
                try store.registerSource(id: source, root: "fixture", runtime: "codex", logicalID: source, locator: "/fixture", now: now)
                try store.recordMetadata(source: source, metadata: UsageSourceMetadata(model: nil, project: "fixture",
                    parentLogicalID: source == "child" ? "parent" : nil), now: now)
                let checkpoint = try store.beginGeneration(source: source, identity: source, targetEnd: 10, initialState: "{}", now: now)
                let facts = parsed.deltas.enumerated().map { UsageIndexFact(logicalKey: String(format: "%010d", $0.offset),
                    occurredAt: $0.element.date, payload: .token($0.element)) }
                let next = try store.append(source: source, expected: checkpoint, offset: 10, state: "{}", facts: facts, now: now)
                try store.activate(source: source, expected: next, verifiedIdentity: source, now: now)
                try store.execute("UPDATE source SET discovered_epoch=? WHERE id=?", [.integer(scan), .text(source)])
                try store.observeSource(source: source, identity: source, targetEnd: 10, status: "readable", now: now)
            }
            try store.finishDiscovery(scan: scan, complete: true, now: now)
            var revision = try store.scalar("SELECT max(id) FROM revision")!
            try check(!store.dependencyIsCurrent(source: "child"))
            var prefix = UsagePrefixCursor()
            var rounds = 0
            repeat {
                prefix = try store.comparePrefix(child: "child", parent: "parent", kind: "token", revision: revision,
                    cursor: JSONDecoder().decode(UsagePrefixCursor.self, from: JSONEncoder().encode(prefix)), maximumPairs: 1)
                rounds += 1
            } while !prefix.finished && rounds < 10
            try check(prefix.finished && prefix.count == 4)
            let inferencePrefix = try store.comparePrefix(child: "child", parent: "parent", kind: "inference", revision: revision, cursor: UsagePrefixCursor())
            try store.recordDependency(child: "child", expectedChild: store.checkpoint(source: "child")!,
                childMetadataRevision: store.metadata(source: "child", revision: revision)!.revision,
                parent: "parent", expectedParent: store.checkpoint(source: "parent")!,
                parentMetadataRevision: store.metadata(source: "parent", revision: revision)!.revision,
                parentLogicalID: "parent", tokenResult: prefix, inferenceResult: inferencePrefix, now: now)
            revision = try store.scalar("SELECT max(id) FROM revision")!
            try check(store.dependencyIsCurrent(source: "child"))
            func project(_ source: String) throws {
                guard var cursor = try store.beginUsageProjection(context: context, source: source, revision: revision, now: now) else {
                    throw UsageIndexError.databaseFailure
                }
                var count = 0
                while !cursor.finished {
                    cursor = try store.stepUsageProjection(cursor, statistics: statistics, now: now)
                    count += 1
                    try check(count < 100)
                }
            }
            try project("parent"); try project("child")
            func archive() throws -> Int64 {
                let build = try store.beginDayArchive(context: context, root: "fixture", dayKey: statistics.dayKey(for: now), now: now)
                var count = 0
                while try !store.stepDayArchive(build: build, now: now) {
                    count += 1; try check(count < 100)
                }
                try check(store.rows("SELECT state FROM report_build WHERE id=?", [.text(build)], limit: 1).first?.first?.text == "ready")
                let payload = try store.rows("SELECT cursor FROM report_build WHERE id=?", [.text(build)], limit: 1).first?.first?.text
                return try JSONDecoder().decode(UsageArchiveCursor.self, from: Data(payload!.utf8)).publicationRevision
            }
            let oldCut = try archive()
            func total(_ cut: Int64) throws -> Int64 {
                var sum: Int64 = 0
                for row in try store.rows("SELECT payload FROM archive_day WHERE context_id=? AND revision_id=?", [.text(context), .integer(cut)]) {
                    let day = try JSONDecoder().decode(UsageArchivedDay.self, from: Data(row[0].text!.utf8))
                    sum += day.dimensions.values.reduce(0) { $0 + $1.tokens.totalTokens }
                }
                return sum
            }
            try check(total(oldCut) == 175)
            // Removing only the parent metadata must retire the old dependency in the same generation.
            try store.recordMetadata(source: "child", metadata: UsageSourceMetadata(model: nil, project: "fixture", parentLogicalID: nil), now: now)
            revision = try store.scalar("SELECT max(id) FROM revision")!
            try project("child")
            try check(total(archive()) == 350)
            // Rewrite both sources to empty; the new complete projections must remove old day rows.
            for source in ["parent", "child"] {
                try store.recordMetadata(source: source, metadata: UsageSourceMetadata(model: nil, project: "fixture", parentLogicalID: nil), now: now)
                let empty = try store.beginGeneration(source: source, identity: source + "-new", targetEnd: 0, initialState: "{}", now: now)
                try store.activate(source: source, expected: empty, verifiedIdentity: source + "-new", now: now)
                try store.observeSource(source: source, identity: source + "-new", targetEnd: 0, status: "readable", now: now)
            }
            revision = try store.scalar("SELECT max(id) FROM revision")!
            try project("parent"); try project("child")
            let newCut = try archive()
            try check(total(newCut) == 0 && total(oldCut) == 175)
            // A source deleted from disk must not block a fresh context forever: its committed
            // facts are the final state, and the materializer reconciles missing projections.
            try store.registerSource(id: "lost", root: "fixture", runtime: "codex", logicalID: "lost", locator: "/fixture/lost", now: now)
            try store.recordMetadata(source: "lost", metadata: UsageSourceMetadata(model: nil, project: "fixture", parentLogicalID: nil), now: now)
            let lostFacts = parsed.deltas.prefix(2).enumerated().map { UsageIndexFact(logicalKey: String(format: "%010d", $0.offset),
                occurredAt: $0.element.date, payload: .token($0.element)) }
            let lostCheckpoint = try store.beginGeneration(source: "lost", identity: "lost", targetEnd: 10, initialState: "{}", now: now)
            let lostNext = try store.append(source: "lost", expected: lostCheckpoint, offset: 10, state: "{}", facts: lostFacts, now: now)
            try store.activate(source: "lost", expected: lostNext, verifiedIdentity: "lost", now: now)
            try store.observeSource(source: "lost", identity: "lost", targetEnd: 10, status: "readable", now: now)
            // Registered but deleted before any parse: no generation, no facts.
            try store.registerSource(id: "empty-gone", root: "fixture", runtime: "codex", logicalID: "empty-gone", locator: "/fixture/empty-gone", now: now)
            let rescan = try store.beginDiscovery(root: "fixture", runtime: "codex", now: now)
            for source in ["parent", "child"] {
                try store.execute("UPDATE source SET discovered_epoch=? WHERE id=?", [.integer(rescan), .text(source)])
            }
            try store.finishDiscovery(scan: rescan, complete: true, now: now)
            try check(store.rows("SELECT status FROM source_observation WHERE source_id='lost' ORDER BY revision_id DESC LIMIT 1",
                                 limit: 1).first?.first?.text == "missing")
            let statisticsB = StatisticsContext(preference: .init(selection: .fixed, fixedIdentifier: "Asia/Shanghai"), now: now)
            let contextB = try store.ensureProjectionContext(root: "fixture", statistics: statisticsB, now: now)
            try check(contextB != context)
            func archiveState(_ build: String) throws -> String? {
                var steps = 0
                while try !store.stepDayArchive(build: build, now: now) { steps += 1; try check(steps < 100) }
                return try store.rows("SELECT state FROM report_build WHERE id=?", [.text(build)], limit: 1).first?.first?.text
            }
            // Without reconciliation the fresh context cannot cover the deleted sources.
            let gapBuild = try store.beginDayArchive(context: contextB, root: "fixture", dayKey: statisticsB.dayKey(for: now), now: now)
            try check(archiveState(gapBuild) == "partial")
            let materializer = try UsageIndexMaterializer(store: store, root: "fixture", statistics: statisticsB)
            var materializeSteps = 0
            while try materializer.step() { materializeSteps += 1; try check(materializeSteps < 2000) }
            try check(store.scalar("SELECT count(*) FROM job WHERE kind='materialize' AND context_id=? AND status<>'done'", [.text(contextB)]) == 0)
            try check(store.scalar("SELECT count(*) FROM source_projection WHERE context_id=? AND state='ready'", [.text(contextB)]) == 3)
            let healedBuild = try store.beginDayArchive(context: contextB, root: "fixture", dayKey: statisticsB.dayKey(for: now), now: now)
            try check(archiveState(healedBuild) == "ready")
            try check(store.rows("SELECT coverage FROM published_slice WHERE context_id=? AND domain='archive' AND runtime='codex'",
                                 [.text(contextB)], limit: 1).first?.first?.text == "completeAtRevision")
            let healedRevision = try JSONDecoder().decode(UsageArchiveCursor.self, from: Data(store.rows(
                "SELECT cursor FROM report_build WHERE id=?", [.text(healedBuild)], limit: 1).first!.first!.text!.utf8)).publicationRevision
            var healedTotal: Int64 = 0
            for row in try store.rows("SELECT payload FROM archive_day WHERE context_id=? AND revision_id=?", [.text(contextB), .integer(healedRevision)]) {
                let day = try JSONDecoder().decode(UsageArchivedDay.self, from: Data(row[0].text!.utf8))
                healedTotal += day.dimensions.values.reduce(0) { $0 + $1.tokens.totalTokens }
            }
            try check(healedTotal == 145)
            print("history archive: resumable fork prefix, parent watermarks, day projection, fixed-cut archive, empty replacement and missing-source recovery passed")
            let regressionFacts = parsed.deltas.enumerated().map { UsageIndexFact(logicalKey: String(format: "%010d", $0.offset),
                occurredAt: $0.element.date, payload: .token($0.element)) }
            return recoveryRegressions(facts: regressionFacts)
        } catch {
            print("history archive failed: \(error)")
            return false
        }
    }

    private struct RegressionFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw RegressionFailure(description: message) }
    }

    /// Separate databases let a RED run report every regression instead of stopping at the first.
    private static func recoveryRegressions(facts: [UsageIndexFact]) -> Bool {
        let cases: [(String, (RecoveryFixture) throws -> Void)] = [
            ("known nonempty deleted before parsing stays partial", unparsedDeletedSource),
            ("unobserved nonempty staging generation stays partial", unobservedStagingSource),
            ("earlier nonempty observation cannot retire without facts", earlierNonemptySource),
            ("returning context rebuilds the current generation", changedGenerationContext),
            ("returning context rebuilds appended input", appendedInputContext),
            ("returning context rebuilds changed metadata", changedMetadataContext),
            ("returning context rebuilds changed dependency watermark", changedDependencyContext),
            ("unreadable then missing stays partial", { try failedObservation($0, status: "unreadable") }),
            ("changed then missing stays partial", { try failedObservation($0, status: "changed") }),
            ("unreadable without facts then missing stays partial", { try failedUnparsedSource($0, status: "unreadable") }),
            ("changed without facts then missing stays partial", { try failedUnparsedSource($0, status: "changed") })
        ]
        var passed = true
        for (name, test) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let fixture = try RecoveryFixture(directory: directory, facts: facts)
                try test(fixture)
                print("history archive regression passed: \(name)")
            } catch {
                passed = false
                print("history archive regression failed: \(name): \(error)")
            }
        }
        return passed
    }

    private struct RecoveryFixture {
        let store: UsageIndexStore
        let facts: [UsageIndexFact]
        let root = "archive-regression"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let statistics = StatisticsContext(preference: .init(selection: .utc, fixedIdentifier: "UTC"),
                                           now: Date(timeIntervalSince1970: 1_700_000_000))
        let statisticsB = StatisticsContext(preference: .init(selection: .fixed, fixedIdentifier: "Asia/Shanghai"),
                                            now: Date(timeIntervalSince1970: 1_700_000_000))

        init(directory: URL, facts: [UsageIndexFact]) throws {
            store = try UsageIndexStore(directory: directory)
            self.facts = facts
        }

        func register(_ source: String) throws {
            try store.registerSource(id: source, root: root, runtime: "codex", logicalID: source,
                                     locator: "/fixture/" + source, now: now)
            try store.recordMetadata(source: source, metadata: UsageSourceMetadata(model: nil, project: "fixture",
                                                                                  parentLogicalID: nil), now: now)
        }

        func activate(_ source: String, identity: String, facts: [UsageIndexFact], targetEnd: Int64 = 10) throws {
            let checkpoint = try store.beginGeneration(source: source, identity: identity, targetEnd: targetEnd,
                                                       initialState: "{}", now: now)
            let next = try store.append(source: source, expected: checkpoint, offset: targetEnd, state: "{}", facts: facts, now: now)
            try store.activate(source: source, expected: next, verifiedIdentity: identity, now: now)
            try store.observeSource(source: source, identity: identity, targetEnd: targetEnd, status: "readable", now: now)
        }

        func discover(present: [String] = []) throws {
            let scan = try store.beginDiscovery(root: root, runtime: "codex", now: now)
            for source in present {
                try store.execute("UPDATE source SET discovered_epoch=? WHERE id=?", [.integer(scan), .text(source)])
            }
            try store.finishDiscovery(scan: scan, complete: true, now: now)
        }

        func context(_ statistics: StatisticsContext) throws -> String {
            try store.ensureProjectionContext(root: root, statistics: statistics, now: now)
        }

        func materialize(_ statistics: StatisticsContext) throws {
            let materializer = try UsageIndexMaterializer(store: store, root: root, statistics: statistics)
            var idle = false
            for _ in 0..<2000 {
                if try !materializer.step() { idle = true; break }
            }
            try require(idle, "materializer did not drain within 2000 steps")
            try require(store.scalar("SELECT count(*) FROM job WHERE kind='materialize' AND context_id=? AND status<>'done'",
                                     [.text(context(statistics))]) == 0, "materialize jobs did not finish")
        }

        @discardableResult
        func archive(_ statistics: StatisticsContext, state: String, missingSources: Int) throws -> String {
            let build = try store.beginDayArchive(context: context(statistics), root: root,
                                                  dayKey: statistics.dayKey(for: now), now: now)
            var finished = false
            for _ in 0..<1000 {
                if try store.stepDayArchive(build: build, now: now) { finished = true; break }
            }
            try require(finished, "archive did not finish within 1000 steps")
            let row = try store.rows("SELECT state,cursor FROM report_build WHERE id=?", [.text(build)], limit: 1).first!
            let cursor = try JSONDecoder().decode(UsageArchiveCursor.self, from: Data(row[1].text!.utf8))
            try require(row[0].text == state, "expected archive \(state), got \(row[0].text ?? "nil")")
            try require(cursor.missingSources == missingSources,
                        "expected \(missingSources) missing sources, got \(cursor.missingSources)")
            return build
        }

        func total(_ build: String) throws -> Int64 {
            let row = try store.rows("SELECT context_id,cursor FROM report_build WHERE id=?", [.text(build)], limit: 1).first!
            let cursor = try JSONDecoder().decode(UsageArchiveCursor.self, from: Data(row[1].text!.utf8))
            var tokens: Int64 = 0
            for value in try store.rows("SELECT payload FROM archive_day WHERE context_id=? AND revision_id=?",
                                        [.text(row[0].text!), .integer(cursor.publicationRevision)]) {
                let day = try JSONDecoder().decode(UsageArchivedDay.self, from: Data(value[0].text!.utf8))
                tokens += day.dimensions.values.reduce(0) { $0 + $1.tokens.totalTokens }
            }
            return tokens
        }

        func publishedBuild(_ statistics: StatisticsContext) throws -> String? {
            try store.rows("SELECT build_id FROM published_slice WHERE context_id=? AND domain='archive' AND runtime='codex'",
                           [.text(context(statistics))], limit: 1).first?.first?.text
        }
    }

    private static func unparsedDeletedSource(_ fixture: RecoveryFixture) throws {
        // Preserve the existing registered-and-immediately-deleted, never-observed case.
        try fixture.register("registered-gone")
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)

        try fixture.register("observed-empty-gone")
        try fixture.store.observeSource(source: "observed-empty-gone", identity: "empty", targetEnd: 0,
                                        status: "unreadable", now: fixture.now)
        try fixture.store.observeSource(source: "observed-empty-gone", identity: "empty", targetEnd: 0,
                                        status: "readable", now: fixture.now)
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)

        try fixture.register("nonempty-gone")
        try fixture.store.observeSource(source: "nonempty-gone", identity: "nonempty", targetEnd: 10,
                                        status: "readable", now: fixture.now)
        _ = try fixture.store.beginGeneration(source: "nonempty-gone", identity: "nonempty", targetEnd: 10,
                                              initialState: "{}", now: fixture.now)
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
    }

    private static func unobservedStagingSource(_ fixture: RecoveryFixture) throws {
        try fixture.register("source")
        _ = try fixture.store.beginGeneration(source: "source", identity: "staging", targetEnd: 10,
                                              initialState: "{}", now: fixture.now)
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
    }

    private static func earlierNonemptySource(_ fixture: RecoveryFixture) throws {
        try fixture.register("source")
        try fixture.store.observeSource(source: "source", identity: "file", targetEnd: 10, status: "readable", now: fixture.now)
        try fixture.store.observeSource(source: "source", identity: "file", targetEnd: 0, status: "readable", now: fixture.now)
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
    }

    private static func failedUnparsedSource(_ fixture: RecoveryFixture, status: String) throws {
        try fixture.register("source")
        try fixture.store.observeSource(source: "source", identity: "file", targetEnd: 0, status: status, now: fixture.now)
        try fixture.discover()
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
    }

    private static func changedGenerationContext(_ fixture: RecoveryFixture) throws {
        try fixture.register("source")
        try fixture.activate("source", identity: "generation-1", facts: fixture.facts)
        try fixture.discover(present: ["source"])
        try fixture.materialize(fixture.statistics)
        let oldBuild = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(oldBuild) == 175, "initial generation total must be 175")

        try fixture.activate("source", identity: "generation-2", facts: Array(fixture.facts.prefix(2)))
        try fixture.materialize(fixture.statisticsB)
        let buildB = try fixture.archive(fixture.statisticsB, state: "ready", missingSources: 0)
        try require(fixture.total(buildB) == 145, "replacement generation total must be 145")
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
        try fixture.materialize(fixture.statistics)
        let recovered = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(recovered) == 145, "returning context must use the replacement generation")
        try require(fixture.total(oldBuild) == 175, "recovery must preserve the old fixed-cut archive")
        try require(fixture.publishedBuild(fixture.statistics) == recovered, "recovered generation must be published")
    }

    private static func appendedInputContext(_ fixture: RecoveryFixture) throws {
        try fixture.register("source")
        try fixture.activate("source", identity: "same-generation", facts: Array(fixture.facts.prefix(2)))
        try fixture.discover(present: ["source"])
        try fixture.materialize(fixture.statistics)
        let oldBuild = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(oldBuild) == 145, "initial append fixture total must be 145")

        let checkpoint = try fixture.store.checkpoint(source: "source")!
        let extended = try fixture.store.observeAppend(source: "source", expected: checkpoint, targetEnd: 20,
                                                       verifiedIdentity: "same-generation", now: fixture.now)
        _ = try fixture.store.append(source: "source", expected: extended, offset: 20, state: "{}",
                                     facts: Array(fixture.facts.dropFirst(2)), now: fixture.now)
        try fixture.materialize(fixture.statisticsB)
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
        try fixture.materialize(fixture.statistics)
        let recovered = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(recovered) == 175, "returning context must include the appended 30 tokens")
        try require(fixture.total(oldBuild) == 145, "append recovery must preserve the old fixed-cut archive")
    }

    private static func changedMetadataContext(_ fixture: RecoveryFixture) throws {
        try fixture.register("source")
        try fixture.activate("source", identity: "same-generation", facts: fixture.facts)
        try fixture.discover(present: ["source"])
        try fixture.materialize(fixture.statistics)
        try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)

        try fixture.store.recordMetadata(source: "source", metadata: UsageSourceMetadata(model: "gpt-5", project: "fixture",
                                                                                       parentLogicalID: nil), now: fixture.now)
        try fixture.materialize(fixture.statisticsB)
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
        try fixture.materialize(fixture.statistics)
        let recovered = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(recovered) == 175, "metadata recovery must retain all tokens")
        try require(fixture.publishedBuild(fixture.statistics) == recovered, "current metadata projection must be published")
    }

    private static func failedObservation(_ fixture: RecoveryFixture, status: String) throws {
        try fixture.register("source")
        try fixture.activate("source", identity: "file", facts: fixture.facts)
        try fixture.discover(present: ["source"])
        try fixture.materialize(fixture.statistics)
        let complete = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)

        try fixture.store.observeSource(source: "source", identity: "file", targetEnd: 10, status: status, now: fixture.now)
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
        // Consecutive complete scans must not erase the last non-missing failure.
        try fixture.discover()
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
        try require(fixture.publishedBuild(fixture.statistics) == complete, "partial deletion must retain the complete publication")

        // A new successful observation resolves the failure; subsequent deletion is covered.
        try fixture.store.observeSource(source: "source", identity: "file", targetEnd: 10, status: "readable", now: fixture.now)
        try fixture.discover(present: ["source"])
        try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try fixture.discover()
        let recovered = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(recovered) == 175, "successful reappearance must retain the committed usage")
    }

    private static func changedDependencyContext(_ fixture: RecoveryFixture) throws {
        for source in ["parent", "child"] {
            try fixture.register(source)
            try fixture.activate(source, identity: source, facts: fixture.facts)
        }
        try fixture.store.recordMetadata(source: "child", metadata: UsageSourceMetadata(model: nil, project: "fixture",
                                                                                       parentLogicalID: "parent"), now: fixture.now)
        try fixture.discover(present: ["parent", "child"])
        try fixture.materialize(fixture.statistics)
        let oldBuild = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(oldBuild) == 175, "inherited usage must be counted once")

        // Context B refreshes the dependency revision without changing either checkpoint.
        try fixture.materialize(fixture.statisticsB)
        try fixture.discover()
        try fixture.archive(fixture.statistics, state: "partial", missingSources: 1)
        try fixture.materialize(fixture.statistics)
        let recovered = try fixture.archive(fixture.statistics, state: "ready", missingSources: 0)
        try require(fixture.total(recovered) == 175, "dependency recovery must preserve prefix deduplication")
        try require(fixture.total(oldBuild) == 175, "dependency recovery must preserve the old fixed cut")
    }
}
