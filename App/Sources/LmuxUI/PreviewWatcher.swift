import CoreServices
import Foundation

/// `file` 被改寫、被取代（先寫暫存檔再改名蓋掉）或被刪除時，在主執行緒呼叫 `onChange`
/// （beat: preview-tab.feature 的自動更新）。用 FSEvents 監看檔案所在資料夾：只監看檔案本身的話，
/// 改名蓋掉之後就還盯著舊檔。
final class PreviewWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void

    init(file: URL, onChange: @escaping () -> Void) {
        // FSEvents 回報的是真實路徑（/private/var/…）；resolvingSymlinksInPath 只在檔案存在時拿掉
        // /private。兩邊都拿掉再比。
        path = Self.canonical(file.resolvingSymlinksInPath().path)
        self.onChange = onChange
        let folder = (path as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<PreviewWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: { PreviewWatcher.canonical($0) == me.path }) {
                me.onChange()
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
        p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
    }

    deinit { stop() }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
