import Testing
@testable import LmuxHooks

@Suite struct ProgramReportTests {
    @Test func theProgramNamedInAppMayReport() {
        #expect(ProgramReporter.namesItself("my-agent", argv: ["/usr/local/bin/my-agent", "--fast"]))
        #expect(ProgramReporter.namesItself("my-agent", argv: ["/bin/sh", "./my-agent"]))
        #expect(ProgramReporter.namesItself("my-agent", argv: ["python3", "-u", "/x/my-agent.py"]))
        #expect(ProgramReporter.namesItself("opencode", argv: ["node", "--no-warnings", "/opt/opencode/bin/opencode"]))
        #expect(ProgramReporter.namesItself("aider", argv: ["python3", "-m", "aider"]))
        #expect(ProgramReporter.namesItself("Goose", argv: ["/opt/homebrew/bin/goose", "session"]))  // case doesn't matter
    }

    @Test func nothingElse() {
        // A file shown with a printer, whatever it names (the reporter would be cat).
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["cat", "my-agent"]))
        #expect(!ProgramReporter.namesItself("cat", argv: ["cat", "notes.txt"]))
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["/usr/bin/tail", "-f", "my-agent.log"]))
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["ssh", "host", "my-agent"]))
        // Another program, a shell, or no name.
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["vim", "-R", "notes.md"]))
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["python3", "viewer.py", "my-agent"]))
        #expect(!ProgramReporter.namesItself("python3", argv: ["python3", "viewer.py", "notes.txt"]))  // (an interpreter runs anything)
        #expect(!ProgramReporter.namesItself("node", argv: ["/usr/local/bin/node", "show.js"]))
        // Any other program's first argument is a file, not its name; wrappers run others under theirs.
        #expect(!ProgramReporter.namesItself("notes", argv: ["sort", "notes"]))
        #expect(!ProgramReporter.namesItself("notes", argv: ["cut", "-f1", "notes"]))
        #expect(!ProgramReporter.namesItself("notes", argv: ["/usr/local/bin/mytool", "notes"]))
        #expect(!ProgramReporter.namesItself("find", argv: ["find", ".", "-exec", "cat", "{}", "+"]))
        #expect(!ProgramReporter.namesItself("xargs", argv: ["xargs", "cat"]))
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["xargs", "my-agent"]))
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["sudo", "my-agent"]))
        #expect(!ProgramReporter.namesItself("web", argv: ["docker", "logs", "web"]))
        #expect(!ProgramReporter.namesItself("kubectl", argv: ["kubectl", "logs", "pod"]))
        #expect(!ProgramReporter.namesItself("zsh", argv: ["-zsh"]))
        #expect(!ProgramReporter.namesItself("my-agent", argv: ["-zsh"]))
        #expect(!ProgramReporter.namesItself("", argv: ["my-agent"]))
        #expect(!ProgramReporter.namesItself("my-agent", argv: []))
    }

    @Test func taskRunnersNeverReport() {
        // `npm test`, `make check`: the job's leader is the runner, a test or build step under it prints.
        for (app, argv) in [("npm", ["npm", "test"]), ("make", ["make", "check"]), ("cargo", ["cargo", "run"]),
                            ("go", ["go", "run", "."]), ("pytest", ["pytest", "-q"]), ("yarn", ["/opt/bin/yarn", "dev"]),
                            ("pnpm", ["pnpm", "test"]), ("bunx", ["bunx", "x"]), ("just", ["just"]), ("brew", ["brew", "test", "x"])] {
            #expect(!ProgramReporter.namesItself(app, argv: argv), "\(app)")
            #expect(!ProgramReporter.namesItself("my-agent", argv: argv + ["my-agent"]), "\(app)")
        }
    }

    @Test func shells() {
        #expect(ProgramReporter.isShell(["-zsh"]))
        #expect(ProgramReporter.isShell(["/bin/bash", "./launch.sh"]))
        #expect(!ProgramReporter.isShell(["cat", "notes"]))
        #expect(!ProgramReporter.isShell(["my-agent"]))
        #expect(!ProgramReporter.isShell([]))
    }

    @Test func aNameLibghosttyCutShort() {
        // libghostty passes 15 bytes of `app`: a longer program name only has to start with them.
        #expect(ProgramReporter.namesItself("my-long-agent-n", argv: ["/x/my-long-agent-name"]))
        #expect(!ProgramReporter.namesItself("my-long-agent", argv: ["/x/my-long-agent-name"]))
    }

    @Test func waitUntil() {
        let states = ["idle", "running", "needs input", "done", "failed"]
        func ends(_ u: WaitUntil, fresh: Bool = true, changed: Bool = true) -> [String] {
            states.filter { u.reached($0, fresh: fresh, changed: changed) }
        }
        #expect(ends(.settled) == ["idle", "needs input", "done", "failed"])
        #expect(ends(.idle) == ["idle"])
        #expect(ends(.done) == ["done", "failed"])
        #expect(ends(.needsYou) == ["needs input"])
        #expect(ends(.any) == states)
        #expect(ends(.any, changed: false).isEmpty)
        // A state from before the last `lmux send`: the previous turn's, never the end of a wait.
        for u in WaitUntil.allCases where u != .any { #expect(ends(u, fresh: false).isEmpty) }
        #expect(WaitUntil(rawValue: "needs-you") == .needsYou && WaitUntil(rawValue: "running") == nil)
    }
}
