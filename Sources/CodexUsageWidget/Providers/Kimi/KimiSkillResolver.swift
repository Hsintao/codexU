import Foundation

/// Resolves a Kimi Code skill name to its on-disk SKILL.md.
///
/// The wire log records only the skill name at invocation time, never the file
/// it came from, so the Skill panel resolves the name against the known roots
/// to surface the same static token estimate other runtimes show. The lookup
/// is deliberately shallow: no recursive walk, one fixed directory layout.
struct KimiSkillResolver {
    struct Resolution {
        let path: String
        let tokenEstimate: Int64
        let byteCount: Int64
    }

    private let fileManager = FileManager.default
    private static let maximumSkillBytes = 4 * 1_024 * 1_024

    /// Lookup order: project skills of sessions seen in the log, then personal
    /// skills, then managed plugin skills. First hit wins.
    func resolve(
        name: String,
        projectPaths: some Sequence<String>,
        homeDirectory: URL
    ) -> Resolution? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }

        var candidates: [URL] = []
        for path in projectPaths where !path.isEmpty {
            candidates.append(
                URL(fileURLWithPath: path)
                    .appendingPathComponent(".agents/skills/\(name)/SKILL.md")
            )
        }
        candidates.append(
            homeDirectory.appendingPathComponent(".agents/skills/\(name)/SKILL.md")
        )

        let managedRoot = homeDirectory.appendingPathComponent(".kimi-code/plugins/managed", isDirectory: true)
        if let families = try? fileManager.contentsOfDirectory(
            at: managedRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for family in families.sorted(by: { $0.path < $1.path }) {
                candidates.append(family.appendingPathComponent("skills/\(name)/SKILL.md"))
            }
        }

        for candidate in candidates {
            guard let values = try? candidate.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  size <= Self.maximumSkillBytes,
                  let data = try? Data(contentsOf: candidate) else {
                continue
            }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return Resolution(
                path: candidate.path,
                tokenEstimate: estimateStaticTokens(text),
                byteCount: Int64(data.count)
            )
        }
        return nil
    }
}
