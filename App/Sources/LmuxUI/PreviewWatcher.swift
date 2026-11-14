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
    private let onChange: @MainActor () -> Void

    init(file: URL, onChange: @escaping @MainActor () -> Void) {
        // FSEvents 回報的是真實路徑（/private/var/…）；即使檔案尚未存在，先解析現存上層目錄 symlink 再去除 /private。
        path = Self.canonical(PreviewTarget.resolvingPath(file).path)
        self.onChange = onChange
        let folder = (path as NSString).deletingLastPathComponent
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
                if list.prefix(count).contains(where: { PreviewWatcher.canonical($0) == me.path }) {
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

    /// `/private/var/x` → `/var/x`（`/private/tmp`、`/private/etc` 同理）；其他路徑不變。
    static func canonical(_ p: String) -> String {
        PreviewTarget.canonicalPath(p)
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
