import CoreServices
import Foundation

/// `file` 被改寫、被取代（先寫暫存檔再改名蓋掉）或被刪除時，在主執行緒呼叫 `onChange`
/// （beat: preview-tab.feature 的自動更新）。用 FSEvents 監看檔案所在資料夾：只監看檔案本身的話，
/// 改名蓋掉之後就還盯著舊檔。
@MainActor
final class PreviewWatcher {
    /// 用弱參考包裝傳進 `FSEventStreamContext`，讓 FSEvents 可安全 retain/release 而不對 `PreviewWatcher` 形成循環參考。
    private final class CallbackBox {
        weak var watcher: PreviewWatcher?
        init(_ watcher: PreviewWatcher) { self.watcher = watcher }
    }

    private var stream: FSEventStreamRef?
    private let path: String
    private let caseSensitive: Bool
    private let onChange: @MainActor () -> Void

    init(file: URL, onChange: @escaping @MainActor () -> Void) {
        // FSEvents 回報的是真實路徑（/private/var/…）；先取磁碟真實大小寫與真實上層路徑，再去除 /private。
        path = Self.canonicalDiskPath(PreviewTarget.resolvingPath(file))
        self.onChange = onChange
        let folder = (path as NSString).deletingLastPathComponent
        caseSensitive = (try? URL(fileURLWithPath: folder)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? true
        let box = CallbackBox(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                return UnsafeRawPointer(Unmanaged<CallbackBox>.fromOpaque(ptr).retain().toOpaque())
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<CallbackBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated {
                guard let me = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().watcher else { return }
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                if list.prefix(count).contains(where: { me.matches($0) }) {
                    me.onChange()
                }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }


    /// 取得現存檔案或最深現存上層目錄在磁碟上的真實大小寫路徑，避免大小寫差異讓 FSEvents 比對靜默失效。
    private static func canonicalDiskPath(_ resolved: URL) -> String {
        let fm = FileManager.default
        var cur = resolved
        var missing: [String] = []
        while cur.path != "/", !fm.fileExists(atPath: cur.path) {
            missing.append(cur.lastPathComponent)
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        let diskBase = (try? cur.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? cur.path
        var out = URL(fileURLWithPath: diskBase)
        for component in missing.reversed() {
            out.appendPathComponent(component)
        }
        return PreviewTarget.canonicalPath(out.path)
    }

    private func matches(_ eventPath: String) -> Bool {
        let event = PreviewTarget.canonicalPath(eventPath)
        return caseSensitive ? event == path : event.caseInsensitiveCompare(path) == .orderedSame
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
