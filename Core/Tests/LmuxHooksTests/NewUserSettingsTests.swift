import Foundation
import Testing
@testable import LmuxHooks

/// settings.json shapes a new user may already have, beyond the formats in InstallerTests:
/// install must give valid JSON with every hook, and the text uninstall (no pristine copy,
/// e.g. the file was touched since) must give the original bytes back.
struct NewUserSettingsTests {
    static let shapes: [(String, String)] = [
        ("empty-hooks", "{\n  \"hooks\": {}\n}\n"),
        ("empty-hooks-compact", "{\"hooks\":{}}"),
        ("empty-event-array", "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n"),
        ("hooks-last-member", "{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"say done\"\n          }\n        ]\n      }\n    ]\n  }\n}"),
        ("unicode-and-slashes", "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"echo 한글 \\/ \\u00e9\"},\n  \"env\": {\"A\": \"\\\"q\\\"\"}\n}\n"),
        ("one-line-spaces", "{ \"model\" : \"haiku\" , \"permissions\" : { \"allow\" : [ ] } }"),
        ("trailing-blank-lines", "{\n  \"model\": \"haiku\"\n}\n\n\n"),
        ("only-whitespace-object", "  {  }  "),
        ("tabs-crlf-mixed", "{\r\n\t\"hooks\": {\r\n\t\t\"Notification\": [\r\n\t\t\t{\"hooks\": [{\"type\": \"command\", \"command\": \"x\"}]}\r\n\t\t]\r\n\t}\r\n}\r\n"),
        ("numbers-and-bools", "{\n  \"cleanupPeriodDays\": 1e3,\n  \"includeCoAuthoredBy\": false,\n  \"x\": null,\n  \"y\": -0.5\n}\n"),
    ]

    @Test(arguments: shapes.map { $0.0 })
    func installGivesValidCompleteJSONAndUninstallRestoresBytes(_ name: String) throws {
        let original = Self.shapes.first { $0.0 == name }!.1
        let hook = "/Applications/lmux.app/Contents/MacOS/lmux-hook"
        let installed = try HookInstaller.install(into: original, hookPath: hook)
        #expect((try? JSONSerialization.jsonObject(with: Data(installed.utf8))) != nil, "install of \(name) is not valid JSON:\n\(installed)")
        #expect(try HookInstaller.status(of: installed).isComplete)
        #expect(try HookInstaller.install(into: installed, hookPath: hook) == installed, "install is not idempotent for \(name)")
        let back = try HookInstaller.uninstall(from: installed, kept: .init(original: original)) ?? ""
        #expect(try HookInstaller.status(of: back).installedEvents.isEmpty)
        // The one exception: whitespace inside an object that was empty (`{  }` comes back `{}`, same JSON).
        let want = name == "only-whitespace-object" ? "  {}  " : original
        #expect(back == want, "uninstall of \(name) did not restore the bytes:\n---\n\(original)\n---\n\(back)")
        if !Self.emptyContainers.contains(name) {
            // Without a pristine copy at all, shapes with no empty container still come back exactly.
            #expect(try HookInstaller.uninstall(from: installed) == original)
        }
        // Untouched since install: the pristine copy gives every shape back byte for byte.
        let dir = TestTemp.dir("shape-\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        try Data(original.utf8).write(to: file)
        let pristine = dir.appendingPathComponent("pristine")
        try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: file.path, hookPath: hook), pristineDirectory: pristine)
        try HookInstaller.apply(try HookInstaller.planUninstall(settingsPath: file.path, pristineDirectory: pristine),
                                pristineDirectory: pristine)
        #expect(try Data(contentsOf: file) == Data(original.utf8), "pristine restore of \(name)")

        // Edited since install (here: a newline added at the end): lmux's lines come out, the
        // user's own empty `"hooks": {}` / `"Stop": []` stay, the edit stays.
        try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: file.path, hookPath: hook), pristineDirectory: pristine)
        try Data((try HookInstaller.read(file.path)! + "\n").utf8).write(to: file)
        try HookInstaller.apply(try HookInstaller.planUninstall(settingsPath: file.path, pristineDirectory: pristine),
                                pristineDirectory: pristine)
        #expect(try HookInstaller.read(file.path) == want + "\n", "edited-since uninstall of \(name)")
    }

    /// Shapes whose empty containers only the pristine record can tell apart from ones lmux emptied.
    static let emptyContainers: Set<String> = ["empty-hooks", "empty-hooks-compact", "empty-event-array", "only-whitespace-object"]

    @Test func pathWithSpacesQuotesAndKoreanStaysOneShellWord() throws {
        let hook = "/Users/새 사용자/Apps/it's lmux.app/Contents/MacOS/lmux-hook"
        let cmd = HookInstaller.command(hookPath: hook)
        let installed = try HookInstaller.install(into: nil, hookPath: hook)
        #expect(try HookInstaller.status(of: installed).commands == [cmd])
        #expect((try? JSONSerialization.jsonObject(with: Data(installed.utf8))) != nil)
    }

    @Test func refusesCommentsAndTrailingCommasInsteadOfRewriting() {
        for bad in ["{\n  // my model\n  \"model\": \"opus\"\n}\n", "{\n  \"model\": \"opus\",\n}\n", "[1, 2]", "\"s\""] {
            #expect(throws: (any Error).self) { try HookInstaller.install(into: bad, hookPath: "/x/lmux-hook") }
        }
    }

    /// The "Can't edit settings.json" alert names a line and column, not a byte offset.
    @Test func parseErrorsPointAtLineAndColumn() {
        let bad = "{\n  \"model\": \"opus\",\n  \"env\": { \"한\": 1 \"B\": 2 }\n}\n"
        do {
            _ = try HookInstaller.install(into: bad, hookPath: "/x/lmux-hook")
            Issue.record("no error")
        } catch {
            #expect("\(error)".contains("line 3, column 19"), "\(error)")
        }
    }

    @Test func claudeConfigDirIsUsedAndEmptyFallsBackToHome() {
        #expect(HookInstaller.defaultSettingsPath(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"]) == "/tmp/cc/settings.json")
        #expect(HookInstaller.defaultSettingsPath(environment: ["CLAUDE_CONFIG_DIR": ""]) == NSHomeDirectory() + "/.claude/settings.json")
    }

    @Test func claudeConfigDirWithTrailingSlashGivesACleanPath() {
        #expect(HookInstaller.defaultSettingsPath(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc/"]) == "/tmp/cc/settings.json")
    }

    /// A user without ~/.claude at all: install creates the directory and the file, uninstall removes the file again.
    @Test func noClaudeDirAtAll() throws {
        let home = TestTemp.dir("nohome")
        let settings = home.appendingPathComponent(".claude/settings.json").path
        let pristine = home.appendingPathComponent("state/hooks-pristine")
        let plan = try HookInstaller.planInstall(settingsPath: settings, hookPath: "/x/lmux-hook")
        try HookInstaller.apply(plan, pristineDirectory: pristine)
        #expect(HookInstaller.isComplete(settingsPath: settings))
        let un = try HookInstaller.planUninstall(settingsPath: settings, pristineDirectory: pristine)
        try HookInstaller.apply(un, pristineDirectory: pristine)
        #expect(!FileManager.default.fileExists(atPath: settings))
    }
}
