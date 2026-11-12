import Foundation
import Testing
@testable import LmuxHooks

/// Shaped like a real heavily-hooked ~/.claude/settings.json (JSON.stringify(_, null, 2), no trailing newline).
let foreignSettings = """
{
  "env": {
    "ENABLE_TOOL_SEARCH": "true"
  },
  "permissions": {
    "allow": [
      "Bash(git status:*)"
    ],
    "deny": []
  },
  "model": "opus",
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear",
        "hooks": [
          {
            "type": "command",
            "command": "sh \\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/start.sh\\""
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "if [ -x '/x/hook.sh' ]; then /bin/sh '/x/hook.sh'; else cat >/dev/null 2>&1; fi",
            "timeout": 5
          },
          {
            "type": "command",
            "command": "node /y/clawd-hook.js PreToolUse",
            "async": true,
            "timeout": 1.5
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -m 1 http://127.0.0.1:23334/state \\u001b ünï 한글 || true"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "~/bin/statusline"
  },
  "skipDangerousModePermissionPrompt": true
}
"""

@Suite struct InstallerTests {
    let hookPath = "/Applications/lmux.app/Contents/MacOS/lmux-hook"

    @Test func renderRoundTripsStringifyFormat() throws {
        // \u001b re-renders as \u001b; everything else is byte-identical.
        #expect(try JSONValue.parse(foreignSettings).render() == foreignSettings)
    }

    @Test func installPreservesForeignHooksAndIsIdempotent() throws {
        let once = try HookInstaller.install(into: foreignSettings, hookPath: hookPath)
        let twice = try HookInstaller.install(into: once, hookPath: hookPath)
        #expect(once == twice)

        let before = try JSONValue.parse(foreignSettings)
        let after = try JSONValue.parse(once)
        // Every non-hooks key unchanged and in the same order.
        guard case .object(let bm) = before, case .object(let am) = after else { Issue.record(); return }
        #expect(bm.map(\.key) == am.map(\.key))
        for m in bm where m.key != "hooks" { #expect(after[m.key] == m.value) }
        // Foreign groups identical and in order (lmux's group goes first, so the diff only adds lines).
        for ev in ["SessionStart", "PreToolUse", "PreCompact"] {
            guard case .array(let b)? = before["hooks"]?[ev], case .array(let a)? = after["hooks"]?[ev] else { Issue.record(); return }
            #expect(a.filter { !"\($0)".contains(HookInstaller.marker) } == b)
        }
        // Our entry added for every event, exactly once.
        let status = try HookInstaller.status(of: once)
        #expect(status.isComplete)
        #expect(status.commands == [HookInstaller.command(hookPath: hookPath)])
        for ev in HookInstaller.events {
            guard case .array(let a)? = after["hooks"]?[ev] else { Issue.record("missing \(ev)"); continue }
            #expect(a.filter { "\($0)".contains(HookInstaller.marker) }.count == 1)
        }
        // Full structure: dropping exactly lmux's groups gives the original document back.
        func dropLmux(_ v: JSONValue) -> JSONValue {
            guard case .object(var root) = v, let hi = root.firstIndex(where: { $0.key == "hooks" }),
                  case .object(var hooks) = root[hi].value else { return v }
            hooks = hooks.compactMap { m in
                guard case .array(let groups) = m.value else { return m }
                let kept = groups.filter { !"\($0)".contains(HookInstaller.marker) }
                return kept.isEmpty ? nil : .init(m.key, .array(kept))
            }
            root[hi].value = .object(hooks)
            return .object(root)
        }
        #expect(dropLmux(after) == before)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 更新 hook 時加入壓縮事件，保留使用者自己的壓縮 hook
    /// 舊版 lmux 裝的 hook 沒有壓縮事件：再裝一次會加上 PreCompact 與 PostCompact，
    /// 使用者自己的 PreCompact 項目保留原樣。
    @Test func reinstallAddsCompactionEventsKeepingForeignPreCompact() throws {
        let compaction = ["PreCompact", "PostCompact"]
        let old = HookInstaller.Target(events: HookInstaller.events.filter { !compaction.contains($0) },
                                       argument: nil, appends: false)
        let older = try HookInstaller.install(into: foreignSettings, hookPath: hookPath, target: old)
        let olderStatus = try HookInstaller.status(of: older)
        #expect(!olderStatus.isComplete)

        let now = try HookInstaller.install(into: older, hookPath: hookPath)
        let nowStatus = try HookInstaller.status(of: now)
        #expect(nowStatus.isComplete)
        let before = try JSONValue.parse(foreignSettings)
        let after = try JSONValue.parse(now)
        for ev in compaction {
            guard case .array(let a)? = after["hooks"]?[ev] else { Issue.record("missing \(ev)"); continue }
            #expect(a.filter { "\($0)".contains(HookInstaller.marker) }.count == 1)
        }
        guard case .array(let b)? = before["hooks"]?["PreCompact"],
              case .array(let a)? = after["hooks"]?["PreCompact"] else { Issue.record(); return }
        #expect(a.filter { !"\($0)".contains(HookInstaller.marker) } == b)
    }

    /// 官方版 lmux（舊的事件清單）再裝一次：lmux 的壓縮項目被移除，使用者自己的 PreCompact 保留。
    @Test func olderLmuxReinstallDropsCompactionEventsKeepingForeignPreCompact() throws {
        let compaction = ["PreCompact", "PostCompact"]
        let old = HookInstaller.Target(events: HookInstaller.events.filter { !compaction.contains($0) },
                                       argument: nil, appends: false)
        let newer = try HookInstaller.install(into: foreignSettings, hookPath: hookPath)
        let downgraded = try HookInstaller.install(into: newer, hookPath: hookPath, target: old)
        let before = try JSONValue.parse(foreignSettings)
        let after = try JSONValue.parse(downgraded)
        for ev in compaction {
            if case .array(let a)? = after["hooks"]?[ev] {
                #expect(!a.contains { "\($0)".contains(HookInstaller.marker) })
            }
        }
        #expect(after["hooks"]?["PreCompact"] == before["hooks"]?["PreCompact"])
    }

    @Test func uninstallRestoresOriginalBytes() throws {
        let installed = try HookInstaller.install(into: foreignSettings, hookPath: hookPath)
        let removed = try HookInstaller.uninstall(from: installed)
        #expect(removed == foreignSettings)
        #expect(try HookInstaller.uninstall(from: removed) == foreignSettings)
    }

    @Test func installIntoMissingOrEmptySettings() throws {
        let fresh = try HookInstaller.install(into: nil, hookPath: hookPath)
        #expect(try HookInstaller.status(of: fresh).isComplete)
        #expect(try HookInstaller.uninstall(from: fresh) == "{}\n")
        let empty = try HookInstaller.install(into: "{}", hookPath: hookPath)
        #expect(try HookInstaller.uninstall(from: empty) == "{}")
    }

    @Test func reinstallWithNewPathReplacesOnlyLmuxEntry() throws {
        let a = try HookInstaller.install(into: foreignSettings, hookPath: "/old/lmux-hook")
        let b = try HookInstaller.install(into: a, hookPath: hookPath)
        #expect(try HookInstaller.status(of: b).commands == [HookInstaller.command(hookPath: hookPath)])
        #expect(try HookInstaller.uninstall(from: b) == foreignSettings)
    }

    @Test func lmuxHandlerSharingAGroupWithForeignHandlerIsRemovedAlone() throws {
        let cmd = HookInstaller.command(hookPath: hookPath).replacingOccurrences(of: "\"", with: "\\\"")
        let mixed = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"},{"type":"command","command":"\(cmd)"}]}]}}
        """
        let out = try HookInstaller.uninstall(from: mixed)!
        let v = try JSONValue.parse(out)
        guard case .array(let groups)? = v["hooks"]?["Stop"], case .array(let hs)? = groups.first?["hooks"] else { Issue.record(); return }
        #expect(hs.count == 1 && hs[0]["command"] == .string("say done"))
    }

    @Test func refusesUnexpectedShapes() {
        #expect(throws: HookInstaller.InstallError.self) { try HookInstaller.install(into: "[]", hookPath: hookPath) }
        #expect(throws: HookInstaller.InstallError.self) { try HookInstaller.install(into: #"{"hooks":[]}"#, hookPath: hookPath) }
        #expect(throws: (any Error).self) { try HookInstaller.install(into: "{not json", hookPath: hookPath) }
    }

    @Test func fileApplyUsesTempFileAndFollowsSymlink() throws {
        let dir = TestTemp.dir("lmux-inst")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.json"), link = dir.appendingPathComponent("settings.json")
        try Data(foreignSettings.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let state = dir.appendingPathComponent("state")  // never lmux's real state dir
        try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: link.path, hookPath: hookPath),
                                pristineDirectory: state)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try HookInstaller.status(of: String(contentsOf: real, encoding: .utf8)).isComplete)
        let again = try HookInstaller.planInstall(settingsPath: link.path, hookPath: hookPath)
        #expect(!again.changed)

        try HookInstaller.apply(try HookInstaller.planUninstall(settingsPath: link.path, pristineDirectory: state),
                                pristineDirectory: state)
        #expect(try String(contentsOf: real, encoding: .utf8) == foreignSettings)
    }

    // The sheet shows a diff, the user takes a while: an edit to settings.json meanwhile (Claude
    // Code's /config, another tool) must never be overwritten by the stale plan.
    @Test func applyRefusesAPlanWhoseFileChangedSince() throws {
        let dir = TestTemp.dir("lmux-inst")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json"), state = dir.appendingPathComponent("state")
        try Data(foreignSettings.utf8).write(to: settings)
        let stale = try HookInstaller.planInstall(settingsPath: settings.path, hookPath: hookPath)
        let edited = "{\n  \"editedMeanwhile\": true," + foreignSettings.dropFirst()
        try Data(edited.utf8).write(to: settings)
        #expect(throws: HookInstaller.InstallError.changedSincePlanned(settings.path)) {
            try HookInstaller.apply(stale, pristineDirectory: state)
        }
        #expect(try String(contentsOf: settings, encoding: .utf8) == edited)
        // Planned again from the file as it is now: applies, and the edit is kept.
        try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: settings.path, hookPath: hookPath), pristineDirectory: state)
        let after = try String(contentsOf: settings, encoding: .utf8)
        #expect(after.contains("\"editedMeanwhile\": true"))
        #expect(try HookInstaller.status(of: after).isComplete)
        // A file created after an install was planned for a missing one is refused too.
        try FileManager.default.removeItem(at: settings)
        let forMissing = try HookInstaller.planInstall(settingsPath: settings.path, hookPath: hookPath)
        try Data("{}".utf8).write(to: settings)
        #expect(throws: HookInstaller.InstallError.changedSincePlanned(settings.path)) {
            try HookInstaller.apply(forMissing, pristineDirectory: state)
        }
    }

    @Test func hookCommandIsInertOutsideLmux() throws {
        // The installed shell command must exit 0, print nothing, and not need the binary.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", HookInstaller.command(hookPath: "/nonexistent/it's lmux-hook")]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}

/// R17: install only inserts lines, uninstall restores the exact bytes, whatever the file looks like.
@Suite struct InstallerFormatTests {
    let hookPath = "/Applications/lmux.app/Contents/Resources/bin/lmux-hook"

    static let fourSpaces = """
    {
        "model": "opus",
        "hooks": {
            "Stop": [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": "say done"
                        }
                    ]
                }
            ]
        },
        "env": {
            "A": "1"
        }
    }

    """
    static let compact = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]},"x":[1,2.50,3e2]}"#
    static let crlf = "{\r\n  \"model\": \"opus\",\r\n  \"hooks\": {\r\n    \"Stop\": [\r\n      {\r\n        \"hooks\": [\r\n          {\r\n            \"type\": \"command\",\r\n            \"command\": \"say done\"\r\n          }\r\n        ]\r\n      }\r\n    ]\r\n  }\r\n}\r\n"
    static let escapes = """
    {
      "statusLine": {
        "command": "echo \\u00e9\\u001b[0m \\/ \\ud83d\\ude00 \\"q\\""
      },
      "model": "sonnet"
    }
    """
    static let tabs = "{\n\t\"model\": \"opus\",\n\t\"permissions\": {\n\t\t\"allow\": []\n\t}\n}\n"
    static let noHooksPretty = "{\n  \"model\": \"opus\"\n}\n"

    /// `before` survives as a subsequence of `after`'s lines: `diff` shows only `+` lines.
    func onlyInsertedLines(_ before: String, _ after: String) -> Bool {
        let b = before.components(separatedBy: "\n"), a = after.components(separatedBy: "\n")
        var i = 0
        for line in a where i < b.count && line == b[i] { i += 1 }
        return i == b.count
    }

    /// Same JSON as `before` once lmux's entries are dropped (structure and order, not just keys).
    func sameExceptLmux(_ before: String, _ after: String) throws -> Bool {
        let stripped = try #require(try HookInstaller.uninstall(from: after))
        return try JSONValue.parse(stripped) == JSONValue.parse(before)
    }

    @Test(arguments: [fourSpaces, crlf, escapes, tabs, noHooksPretty, foreignSettings])
    func multiLineFilesOnlyGainLines(_ original: String) throws {
        let installed = try HookInstaller.install(into: original, hookPath: hookPath)
        #expect(installed != original)
        #expect(onlyInsertedLines(original, installed), "diff must only add lines:\n\(installed)")
        #expect(try HookInstaller.status(of: installed).isComplete)
        #expect(try sameExceptLmux(original, installed))
        #expect(try HookInstaller.uninstall(from: installed) == original)
        #expect(try HookInstaller.install(into: installed, hookPath: hookPath) == installed)
    }

    @Test func crlfStaysCRLF() throws {
        let installed = try HookInstaller.install(into: Self.crlf, hookPath: hookPath)
        let bytes = Array(installed.utf8)
        for (i, b) in bytes.enumerated() where b == 0x0A { #expect(i > 0 && bytes[i - 1] == 0x0D) }
    }

    @Test func fourSpaceIndentIsKept() throws {
        let installed = try HookInstaller.install(into: Self.fourSpaces, hookPath: hookPath)
        for line in installed.components(separatedBy: "\n") {
            let lead = line.prefix { $0 == " " }.count
            #expect(lead % 4 == 0, "\(line)")
        }
    }

    @Test func escapesAreNeverRewritten() throws {
        let installed = try HookInstaller.install(into: Self.escapes, hookPath: hookPath)
        let b = "\\"  // built up so no tool turns the escapes into characters
        let line = "\"command\": \"echo " + b + "u00e9" + b + "u001b[0m " + b + "/ " + b + "ud83d" + b + "ude00 " + b + "\"q" + b + "\"\""
        #expect(Data(installed.utf8).range(of: Data(line.utf8)) != nil)
    }

    @Test func compactFileStaysCompactAndOnlyGainsBytes() throws {
        let installed = try HookInstaller.install(into: Self.compact, hookPath: hookPath)
        #expect(!installed.contains("\n"))
        // Every original byte is still there, in order (only insertions).
        var it = Array(Self.compact.utf8).makeIterator()
        var next = it.next()
        for b in installed.utf8 where b == next { next = it.next() }
        #expect(next == nil)
        #expect(installed.contains(#""x":[1,2.50,3e2]"#))
        #expect(try sameExceptLmux(Self.compact, installed))
        #expect(try HookInstaller.uninstall(from: installed) == Self.compact)
    }

    @Test func utf8BOMIsKept() throws {
        let original = "\u{FEFF}" + Self.noHooksPretty
        let installed = try HookInstaller.install(into: original, hookPath: hookPath)
        #expect(installed.hasPrefix("\u{FEFF}{") && Array(installed.utf8.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(try HookInstaller.status(of: installed).isComplete)
        #expect(try HookInstaller.uninstall(from: installed) == original)
    }

    @Test func duplicateHooksKeysAreRefusedAndStatusReadsTheLastOne() throws {
        // JSON.parse keeps the LAST duplicate: that's what Claude Code sees.
        let cmd = HookInstaller.command(hookPath: hookPath).replacingOccurrences(of: "\"", with: "\\\"")
        let dup = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(cmd)"}]}]},"hooks":{}}"#
        #expect(try HookInstaller.status(of: dup).installedEvents.isEmpty)
        let dup2 = #"{"hooks":{},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(cmd)"}]}]}}"#
        #expect(try HookInstaller.status(of: dup2).installedEvents == ["Stop"])
        #expect(throws: HookInstaller.InstallError.duplicateKey("hooks")) { try HookInstaller.install(into: dup, hookPath: hookPath) }
        #expect(throws: HookInstaller.InstallError.duplicateKey("hooks")) { try HookInstaller.uninstall(from: dup2) }
        let dupEvent = #"{"hooks":{"Stop":[],"Stop":[]}}"#
        #expect(throws: HookInstaller.InstallError.duplicateKey("hooks.Stop")) { try HookInstaller.install(into: dupEvent, hookPath: hookPath) }
        #expect("\(HookInstaller.InstallError.duplicateKey("hooks"))".contains("more than once"))
    }

    @Test func emptyObjectRoundTrips() throws {
        for original in ["{}", "{}\n"] {
            let installed = try HookInstaller.install(into: original, hookPath: hookPath)
            #expect(try HookInstaller.status(of: installed).isComplete)
            #expect(try HookInstaller.uninstall(from: installed) == original)
        }
    }

    @Test func surgicalRemovalAfterClaudeReformatted() throws {
        // Claude Code rewrites settings.json (JSON.stringify, 2 spaces) after lmux installed:
        // the pristine copy no longer applies, lmux's entries are cut out of the new text.
        let installed = try HookInstaller.install(into: Self.fourSpaces, hookPath: hookPath)
        var v = try JSONValue.parse(installed)
        if case .object(var m) = v { m.append(.init("theme", .string("dark"))); v = .object(m) }
        let rewritten = v.render() + "\n"
        let removed = try #require(try HookInstaller.uninstall(from: rewritten))
        var expected = try JSONValue.parse(Self.fourSpaces)
        if case .object(var m) = expected { m.append(.init("theme", .string("dark"))); expected = .object(m) }
        #expect(removed == expected.render() + "\n")
    }

    func tempDir() throws -> URL {
        let d = TestTemp.dir("lmux-fmt")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func emptyAndMissingFilesComeBackExactly() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state")
        // Empty file: back to zero bytes. Missing file: gone again.
        for original in ["", nil] as [String?] {
            let settings = dir.appendingPathComponent("settings-\(original == nil ? "missing" : "empty").json")
            if let original { try Data(original.utf8).write(to: settings) }
            try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: settings.path, hookPath: hookPath),
                                    pristineDirectory: state)
            #expect(HookInstaller.isComplete(settingsPath: settings.path))
            try HookInstaller.apply(try HookInstaller.planUninstall(settingsPath: settings.path, pristineDirectory: state),
                                    pristineDirectory: state)
            if let original {
                #expect(try Data(contentsOf: settings) == Data(original.utf8))
            } else {
                #expect(!FileManager.default.fileExists(atPath: settings.path))
            }
        }
    }

    @Test func pristineCopyRestoresAnyFormatWhenUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state")
        let settings = dir.appendingPathComponent("settings.json")
        for original in ["{ }", "  {\"a\":1}  \n\n", Self.compact, Self.crlf] {
            try Data(original.utf8).write(to: settings)
            try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: settings.path, hookPath: hookPath),
                                    pristineDirectory: state)
            try HookInstaller.apply(try HookInstaller.planUninstall(settingsPath: settings.path, pristineDirectory: state),
                                    pristineDirectory: state)
            #expect(try Data(contentsOf: settings) == Data(original.utf8), "\(original.debugDescription)")
        }
        // The pristine copy is lmux's own file, private to the user.
        let files = try FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil)
        for f in files {
            let mode = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
    }

    /// A UTF-8 BOM survives on real files: install keeps it on disk, uninstall gives the exact bytes back,
    /// both through the pristine copy and through surgical removal (no pristine dir).
    @Test(arguments: [("bom-crlf", crlf), ("bom-lf", noHooksPretty), ("bom-4space", fourSpaces)])
    func bomFilesRoundTripByteForByte(_ name: String, _ body: String) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        for pristine in [dir.appendingPathComponent("state"), nil] as [URL?] {
            let settings = dir.appendingPathComponent("\(name)-\(pristine == nil ? "surgical" : "pristine").json")
            try original.write(to: settings)
            try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: settings.path, hookPath: hookPath),
                                    pristineDirectory: pristine)
            let installed = try Data(contentsOf: settings)
            #expect(Array(installed.prefix(3)) == [0xEF, 0xBB, 0xBF], "\(name): install dropped the BOM")
            #expect(Array(installed.dropFirst(3).prefix(1)) == [UInt8(ascii: "{")], "\(name): one BOM, then the JSON")
            #expect(HookInstaller.isComplete(settingsPath: settings.path))
            if body == Self.crlf {
                let b = Array(installed)
                for (i, c) in b.enumerated() where c == 0x0A { #expect(i > 0 && b[i - 1] == 0x0D) }
            }
            try HookInstaller.apply(try HookInstaller.planUninstall(settingsPath: settings.path, pristineDirectory: pristine),
                                    pristineDirectory: pristine)
            #expect(try Data(contentsOf: settings) == original, "\(name) \(pristine == nil ? "surgical" : "pristine")")
        }
    }
}
