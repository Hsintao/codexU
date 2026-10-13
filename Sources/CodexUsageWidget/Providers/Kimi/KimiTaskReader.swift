import Foundation

/// Session activity metadata only. Executed by the existing bounded task helper;
/// conversation logs and credentials are not needed to build this board.
struct KimiTaskReader {
    private let manager = FileManager.default
    private let maximumMetadataBytes = 256 * 1024

    func loadTaskBoard(context: RuntimeLoadContext) -> TaskBoard? {
        let root = context.homeDirectory.appendingPathComponent(".kimi-code/sessions", isDirectory: true)
        let statistics = context.statistics
        let dayStart = statistics.startOfDay(for: context.now)
        do {
            var sessions: [String: TaskItem] = [:]
            for workspace in try directories(under: root) {
                for directory in try directories(under: workspace) where directory.lastPathComponent.hasPrefix("session_") {
                    let file = directory.appendingPathComponent("state.json")
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size > 0, size <= maximumMetadataBytes else { return nil }
                    let handle = try FileHandle(forReadingFrom: file)
                    let data: Data
                    do {
                        data = try handle.read(upToCount: maximumMetadataBytes + 1) ?? Data()
                        try handle.close()
                    } catch {
                        try? handle.close()
                        throw error
                    }
                    guard data.count == size,
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let updatedAt = kimiDateValue(object["updatedAt"]), updatedAt.timeIntervalSince1970.isFinite,
                          let title = object["title"] as? String,
                          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    guard updatedAt >= dayStart, updatedAt <= context.now else { continue }
                    let id = directory.lastPathComponent
                    if let previous = sessions[id]?.updatedAt, previous >= updatedAt { continue }
                    let kind = TaskActivityClassifier.column(updatedAt: updatedAt, now: context.now)
                    let project = (object["workDir"] as? String).flatMap { value -> String? in
                        guard !value.isEmpty else { return nil }
                        return URL(fileURLWithPath: value).lastPathComponent
                    }
                    sessions[id] = TaskItem(id: id, code: "Kimi", title: title, detail: project ?? "", chip: "",
                        updatedAt: updatedAt, tokens: nil, kind: kind, sourceKind: .kimiSession,
                        displayState: kind == .active ? .recentlyActive : .continueLater, stateBasis: .activityWindow)
                }
            }
            let columns: [TaskColumn] = [TaskColumnKind.active, .pending].map { kind in
                let items = sessions.values.filter { $0.kind == kind }.sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt! > $1.updatedAt! }
                    return $0.id < $1.id
                }
                return TaskColumn(id: kind, title: kind == .active ? "最近活跃" : "待继续", count: items.count,
                    items: Array(items.prefix(HomeSnapshotStore.maximumTasksPerRuntime / 4)))
            }
            return TaskBoard(refreshedAt: context.now, columns: columns)
        } catch {
            // Failed scans stay unavailable so the coordinator can retain its
            // last successful board, rather than publish partial counts as zero.
            return nil
        }
    }

    private func directories(under root: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]).filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
