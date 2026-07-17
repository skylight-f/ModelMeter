import Foundation

struct ClaudeSkillFileResolution: Equatable {
    let path: String
    let staticTokenEstimate: Int64
    let staticByteCount: Int64
}

struct ClaudeSkillPathResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(
        name rawName: String,
        explicitPath: String? = nil,
        projectPath: String?,
        homeDirectory: URL
    ) -> ClaudeSkillFileResolution? {
        if let explicitPath,
           let resolution = resolution(for: URL(fileURLWithPath: explicitPath)) {
            return resolution
        }

        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return nil }

        if let qualified = qualifiedName(name) {
            let candidates = qualifiedCandidates(
                namespace: qualified.namespace,
                skillName: qualified.skillName,
                projectPath: projectPath,
                homeDirectory: homeDirectory
            )
            let matches = readableResolutions(candidates)
            return matches.count == 1 ? matches[0] : nil
        }

        guard isSafePathComponent(name) else { return nil }

        let personalSkill = homeDirectory
            .appendingPathComponent(".claude/skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        if let resolution = resolution(for: personalSkill) {
            return resolution
        }

        let projectDirectories = projectSearchDirectories(projectPath)
        for directory in projectDirectories {
            let candidate = directory
                .appendingPathComponent(".claude/skills", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("SKILL.md")
            if let resolution = resolution(for: candidate) {
                return resolution
            }
        }

        let personalCommand = homeDirectory
            .appendingPathComponent(".claude/commands", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("md")
        if let resolution = resolution(for: personalCommand) {
            return resolution
        }

        for directory in projectDirectories {
            let candidate = directory
                .appendingPathComponent(".claude/commands", isDirectory: true)
                .appendingPathComponent(name)
                .appendingPathExtension("md")
            if let resolution = resolution(for: candidate) {
                return resolution
            }
        }

        return nil
    }

    private func qualifiedName(_ name: String) -> (namespace: String, skillName: String)? {
        guard let separator = name.lastIndex(of: ":") else { return nil }
        let namespace = String(name[..<separator])
        let skillName = String(name[name.index(after: separator)...])
        guard isSafeRelativePath(namespace), isSafePathComponent(skillName) else { return nil }
        return (namespace, skillName)
    }

    private func qualifiedCandidates(
        namespace: String,
        skillName: String,
        projectPath: String?,
        homeDirectory: URL
    ) -> [URL] {
        var candidates: [URL] = []
        let projectDirectories = projectSearchDirectories(projectPath)
        if let startDirectory = projectDirectories.first {
            candidates.append(
                startDirectory
                    .appendingPathComponent(namespace, isDirectory: true)
                    .appendingPathComponent(".claude/skills", isDirectory: true)
                    .appendingPathComponent(skillName, isDirectory: true)
                    .appendingPathComponent("SKILL.md")
            )
        }
        if let repositoryRoot = projectDirectories.last, repositoryRoot != projectDirectories.first {
            candidates.append(
                repositoryRoot
                    .appendingPathComponent(namespace, isDirectory: true)
                    .appendingPathComponent(".claude/skills", isDirectory: true)
                    .appendingPathComponent(skillName, isDirectory: true)
                    .appendingPathComponent("SKILL.md")
            )
        }

        candidates.append(contentsOf: pluginCandidates(
            namespace: namespace,
            skillName: skillName,
            homeDirectory: homeDirectory
        ))
        return candidates
    }

    private func pluginCandidates(namespace: String, skillName: String, homeDirectory: URL) -> [URL] {
        let pluginsRoot = homeDirectory.appendingPathComponent(".claude/plugins", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: pluginsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let expectedSuffix = "/\(namespace)/skills/\(skillName)/SKILL.md"
        var matches: [URL] = []
        var seen = Set<String>()
        for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
            let standardized = url.standardizedFileURL.path
            guard standardized.hasSuffix(expectedSuffix), seen.insert(standardized).inserted else { continue }
            matches.append(url)
        }
        return matches.sorted { $0.path < $1.path }
    }

    private func projectSearchDirectories(_ projectPath: String?) -> [URL] {
        guard let projectPath, projectPath.hasPrefix("/") else { return [] }
        let start = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        var chain: [URL] = []
        var current = start

        while true {
            chain.append(current)
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return chain
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        // Without a discoverable repository root, Claude's historical project boundary
        // cannot be reconstructed safely. Limit fallback to the recorded cwd.
        return [start]
    }

    private func readableResolutions(_ candidates: [URL]) -> [ClaudeSkillFileResolution] {
        var matches: [ClaudeSkillFileResolution] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard let resolution = resolution(for: candidate) else { continue }
            let canonicalPath = URL(fileURLWithPath: resolution.path).resolvingSymlinksInPath().path
            guard seen.insert(canonicalPath).inserted else { continue }
            matches.append(resolution)
        }
        return matches
    }

    private func resolution(for url: URL) -> ClaudeSkillFileResolution? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return ClaudeSkillFileResolution(
            path: url.standardizedFileURL.path,
            staticTokenEstimate: estimateStaticTokens(text),
            staticByteCount: Int64(data.count)
        )
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            isSafePathComponent(String($0))
        }
    }

    private func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
    }
}

enum ClaudeSkillPathResolverSelfTest {
    static func run() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codexu-claude-skill-resolver-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("repo", isDirectory: true)
        let nestedCWD = project.appendingPathComponent("packages/app", isDirectory: true)
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        func write(_ text: String, to url: URL) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }

        defer { try? fileManager.removeItem(at: root) }
        try? fileManager.createDirectory(at: nestedCWD, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let resolver = ClaudeSkillPathResolver(fileManager: fileManager)
        let projectSkill = project.appendingPathComponent(".claude/skills/review/SKILL.md")
        let personalSkill = home.appendingPathComponent(".claude/skills/review/SKILL.md")
        write("project review", to: projectSkill)
        write("personal review", to: personalSkill)

        var result = resolver.resolve(name: "review", projectPath: nestedCWD.path, homeDirectory: home)
        expect(result?.path == personalSkill.path, "personal skill should override project skill")
        expect(result?.staticByteCount == Int64(Data("personal review".utf8).count), "resolved file size should be captured")
        try? fileManager.removeItem(at: personalSkill)

        result = resolver.resolve(name: "review", projectPath: nestedCWD.path, homeDirectory: home)
        expect(result?.path == projectSkill.path, "project skill should be discovered from a nested cwd")
        expect((result?.staticTokenEstimate ?? 0) > 0, "resolved skill should include a token estimate")

        let nestedSkill = project.appendingPathComponent("apps/web/.claude/skills/deploy/SKILL.md")
        write("nested deploy", to: nestedSkill)
        result = resolver.resolve(name: "apps/web:deploy", projectPath: project.path, homeDirectory: home)
        expect(result?.path == nestedSkill.path, "directory-qualified nested skill should resolve")

        let pluginSkill = home.appendingPathComponent(
            ".claude/plugins/marketplaces/community/plugins/sample/skills/audit/SKILL.md"
        )
        write("plugin audit", to: pluginSkill)
        result = resolver.resolve(name: "sample:audit", projectPath: project.path, homeDirectory: home)
        expect(result?.path == pluginSkill.path, "namespaced plugin skill should resolve")

        let legacyCommand = home.appendingPathComponent(".claude/commands/legacy.md")
        write("legacy command", to: legacyCommand)
        result = resolver.resolve(name: "legacy", projectPath: project.path, homeDirectory: home)
        expect(result?.path == legacyCommand.path, "legacy command should be used as a final fallback")

        expect(
            resolver.resolve(name: "../unsafe", projectPath: project.path, homeDirectory: home) == nil,
            "unsafe names must not escape skill roots"
        )
        expect(
            resolver.resolve(name: "missing", projectPath: project.path, homeDirectory: home) == nil,
            "missing skill should remain unresolved"
        )

        if failures.isEmpty {
            print("Claude skill path resolver self-test passed")
            return true
        }
        failures.forEach { print("Claude skill path resolver self-test failed: \($0)") }
        return false
    }
}
