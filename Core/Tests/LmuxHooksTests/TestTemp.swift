import Foundation

/// One temp root per test process, removed when the process exits (every test's files go
/// under it, so nothing is left in $TMPDIR even when a test fails midway).
enum TestTemp {
    static let root: URL = {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("lmux-coretests-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestTemp.root) }
        return r
    }()

    static func dir(_ prefix: String) -> URL { root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true) }
}
