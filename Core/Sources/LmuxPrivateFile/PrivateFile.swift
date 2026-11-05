import Darwin
import Foundation

/// Files that hold conversation text (restored transcripts, forget backups, rewritten
/// transcripts and history): created with their final mode from the first byte on, so
/// there is never a moment where the umask's 0644 lets another user read them.
public enum PrivateFile {
    /// Tests: runs right after the file is created, before anything is written to it.
    nonisolated(unsafe) public static var didCreate: ((URL) -> Void)?

    /// A new file at `url` with `mode` (fails if anything is there already).
    public static func create(_ url: URL, _ data: Data, mode: mode_t = 0o600) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(url.path) }
        }
        // open() applies the umask, which can only take bits away: set exactly `mode`.
        guard fchmod(fd, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        didCreate?(url)
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                off += n
            }
        }
        ok = true
    }

    /// Atomically replaces `url` with `data`: a new file with `mode` next to it, renamed over it.
    public static func replace(_ url: URL, _ data: Data, mode: mode_t) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).lmux-\(getpid())-\(UUID().uuidString.prefix(8))")
        try create(tmp, data, mode: mode)
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
    }

    /// The permission bits of the file at `path`, if it exists.
    public static func mode(of path: String) -> mode_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_mode & 0o7777 : nil
    }
}
