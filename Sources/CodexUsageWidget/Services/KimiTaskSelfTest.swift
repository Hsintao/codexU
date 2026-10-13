import Foundation

enum KimiTaskSelfTest {
    static func run() -> Bool {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("codexu-kimi-tasks-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        var failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { failures.append(message) }
        }
        let now = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
        func context(_ zone: String = "Asia/Shanghai", at date: Date? = nil) -> RuntimeLoadContext {
            let date = date ?? now
            return RuntimeLoadContext(now: date, homeDirectory: root, cacheDirectory: root.appendingPathComponent("cache"),
                statistics: StatisticsContext(preference: .init(selection: .fixed, fixedIdentifier: zone), now: date))
        }
        let sessions = root.appendingPathComponent(".kimi-code/sessions")
        func write(_ id: String, title: String, time: Any, workspace: String = "workspace") throws -> URL {
            let directory = sessions.appendingPathComponent(workspace).appendingPathComponent("session_" + id)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("state.json")
            let data = try JSONSerialization.data(withJSONObject: [
                "title": title, "workDir": "/private/projects/Example", "updatedAt": time,
                "createdAt": "2026-10-12T01:00:00.000Z", "agents": ["main": [:]],
                "custom": ["prompt": "PRIVATE CONVERSATION MUST NOT APPEAR"]
            ])
            try data.write(to: file)
            return file
        }
        let provider = KimiRuntimeProvider()
        do {
            expect(provider.loadTaskBoard(context: context()) == nil, "missing Kimi source must remain unavailable")
            try manager.createDirectory(at: sessions, withIntermediateDirectories: true)
            let empty = provider.loadTaskBoard(context: context())
            expect(empty?.totalCount == 0 && empty?.columns.count == 2,
                   "a readable empty source must return an empty two-column board")
            _ = try write("recent", title: "Recent session", time: "2026-10-13T11:30:00.000Z")
            _ = try write("boundary", title: "Two-hour boundary", time: "2026-10-13T10:00:00.000Z")
            let pendingDate = ISO8601DateFormatter().date(from: "2026-10-13T09:59:59Z")!
            _ = try write("pending", title: "Earlier today", time: Int64(pendingDate.timeIntervalSince1970 * 1000))
            _ = try write("yesterday", title: "Yesterday", time: "2026-10-12T15:59:59.000Z")
            _ = try write("future", title: "Future", time: "2026-10-13T12:00:01.000Z")
            _ = try write("recent", title: "Older duplicate", time: "2026-10-13T08:00:00.000Z", workspace: "duplicate")
            let board = provider.loadTaskBoard(context: context())
            let active = board?.columns.first(where: { $0.id == .active })
            let pending = board?.columns.first(where: { $0.id == .pending })
            expect(active?.count == 2 && pending?.count == 1 && board?.totalCount == 3,
                   "today classification must include the two-hour boundary, deduplicate sessions and exclude yesterday/future")
            expect(active?.items.map(\.title) == ["Recent session", "Two-hour boundary"],
                   "sessions must be ordered newest first and retain the newest duplicate")
            expect(pending?.items.first?.title == "Earlier today", "millisecond timestamps must classify correctly")
            let items = board?.columns.flatMap(\.items) ?? []
            expect(items.count == 3 && items.allSatisfy {
                $0.sourceKind.rawValue == "kimiSession" && $0.stateBasis == .activityWindow
                    && $0.runtimeState == .recorded && !$0.isRealtime && $0.threadID == nil && $0.tokens == nil
                    && $0.detail == "Example" && !$0.title.contains("PRIVATE")
                    && ($0.displayState == .recentlyActive || $0.displayState == .continueLater)
            }, "Kimi cards must use session metadata without inventing runtime state, tokens or Codex actions")
            let child = HomeTaskReader.read(scope: .kimi, context: context())
            expect(child?.totalCount == 3 && child?.columns.count == 2
                && child?.columns.first?.items.first?.title == "Recent session"
                && child?.columns.first?.items.first?.detail == "Example",
                "the actual task helper must publish Kimi cards with source and workspace intact")
            if let board, let payload = HomeSnapshotStore.taskData(board: board) {
                let restored = HomeSnapshotStore.taskBoard(data: payload)
                expect(restored?.totalCount == 3 && restored?.columns.first?.items.first?.displayState == .recentlyActive,
                       "bounded task IPC must retain Kimi activity semantics")
            } else { failures.append("Kimi board must encode into bounded task IPC") }

            let bad = try write("broken", title: "Broken", time: "2026-10-13T11:00:00.000Z")
            try Data("{unfinished".utf8).write(to: bad)
            expect(provider.loadTaskBoard(context: context()) == nil,
                   "a failed metadata read must not publish a deceptively complete partial board")
            try manager.removeItem(at: bad.deletingLastPathComponent())
            expect(provider.loadTaskBoard(context: context())?.totalCount == 3,
                   "a new read must recover after a corrupted metadata file is removed")
            let oversized = try write("oversized", title: "Large", time: "2026-10-13T11:00:00.000Z")
            try Data(repeating: 32, count: 256 * 1024 + 1).write(to: oversized)
            expect(provider.loadTaskBoard(context: context()) == nil, "oversized metadata must remain bounded and unavailable")
            try manager.removeItem(at: oversized.deletingLastPathComponent())

            _ = try write("midnight", title: "Local day", time: "2026-10-12T23:30:00.000Z")
            let midnightNow = ISO8601DateFormatter().date(from: "2026-10-13T00:30:00Z")!
            expect(provider.loadTaskBoard(context: context("Asia/Shanghai", at: midnightNow))?.totalCount == 1,
                   "today must use the selected statistics timezone")
            expect(provider.loadTaskBoard(context: context("UTC", at: midnightNow))?.totalCount == 0,
                   "the same previous-UTC-day session must not leak into today's board")

            for number in 0..<12 {
                _ = try write("page-\(number)", title: "Page \(number)", time: "2026-10-13T11:45:00.000Z")
            }
            let page = HomeTaskReader.read(scope: .kimi, context: context())
            expect(page?.columns.first?.count == 14 && page?.columns.first?.items.count == 6,
                   "bounded helper output must preserve the full column count while limiting visible cards")
        } catch { failures.append("fixture failed: \(error)") }
        if failures.isEmpty {
            print("Kimi task self-test passed: metadata, day/window boundaries, deduplication, privacy, failures and real helper")
            return true
        }
        failures.forEach { print("Kimi task self-test failed: \($0)") }
        return false
    }
}
