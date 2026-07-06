import Foundation

enum FilePaths {
    static let home = NSHomeDirectory()

    // Codex
    static let codexStateDB = home + "/.codex/state_5.sqlite"
    static let codexStateDBAlt = home + "/.codex/sqlite/state_5.sqlite"
    static let codexSkillsDir = home + "/.codex/skills"
    static let codexAutomationsDir = home + "/.codex/automations"

    // MimoCode
    static let mimocodeDB = home + "/.local/share/mimocode/mimocode.db"

    // Claude Code
    static let claudeStateDB = home + "/.claude/state.db"
    static let claudeStateDBAlt = home + "/.claude/sqlite/state.db"

    // Cursor
    static let cursorStateDB = home + "/.cursor/state.vscsqlite"
    static let cursorWorkspaceDB = home + "/Library/Application Support/Cursor/User/workspaceStorage/state.vscsqlite"

    // Windsurf
    static let windsurfStateDB = home + "/.codeium/windsurf/state.vscsqlite"

    // sqlite3 binary
    static let sqlite3Binary: String? = {
        let candidates = ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3",
                          "/opt/homebrew/share/android-commandlinetools/platform-tools/sqlite3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // Agents skills
    static let agentsSkillsDir = home + "/.agents/skills"

    static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}
