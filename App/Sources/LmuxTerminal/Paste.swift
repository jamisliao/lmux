// Drop and paste contents as the terminal should receive them. The file-path rules and
// shell escaping follow Ghostty (https://github.com/ghostty-org/ghostty) at ff23824:
//   macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift (getOpinionatedStringContents)
//   macos/Sources/Ghostty/Ghostty.Shell.swift (escape)
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.
// lmux addition: an image (screenshot, copied picture) becomes a temp PNG whose escaped
// path is pasted, which Claude Code attaches as an image ([Image #1]) and a shell can use.

import AppKit
import UniformTypeIdentifiers

public enum PasteContents {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Escape shell-sensitive characters with a backslash (for inserting at the cursor).
    public static func shellEscape(_ str: String) -> String {
        var result = str
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    /// Where pasted images are written (0700). Files older than a day are removed on the next paste.
    public static var imageDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmux-paste", isDirectory: true)

    /// Text for the terminal: escaped paths of dropped/copied files, else plain text, else
    /// an image saved as a PNG (its escaped path). nil if there's nothing usable.
    public static func string(from pb: NSPasteboard) -> String? {
        let items = pb.pasteboardItems ?? []
        let strings: [String] = items.compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return shellEscape(url.path)
            }
            return item.string(forType: .string)
        }
        if !strings.isEmpty { return strings.joined(separator: " ") }
        if let url = saveImage(from: pb) { return shellEscape(url.path) }
        return nil
    }

    /// What a drop inserts. Like a paste, except that an image dragged from a browser (image data
    /// plus its web address, no file) inserts the image as a file, not the URL text.
    /// nil = nothing usable here (maybe a file promise, see `receive`).
    public static func dropString(from pb: NSPasteboard) -> String? {
        let items = pb.pasteboardItems ?? []
        let hasFile = items.contains { $0.types.contains(.fileURL) }
        let hasImage = (pb.types ?? []).contains { $0 == .png || $0 == .tiff }
        if !hasFile, hasImage {
            let texts = items.compactMap { $0.string(forType: .string) ?? $0.string(forType: .URL) }
            let onlyURLs = texts.allSatisfy { t in
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                return !s.contains(" ") && (s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("data:"))
            }
            if onlyURLs, let url = saveImage(from: pb) { return shellEscape(url.path) }
        }
        if !hasFile, items.allSatisfy({ $0.string(forType: .string) == nil }),
           let u = items.compactMap({ $0.string(forType: .URL) }).first {
            return u  // a link dragged from a browser's address bar
        }
        if !hasFile, !hasImage, items.allSatisfy({ $0.string(forType: .string) == nil }) { return nil }
        return string(from: pb)
    }

    /// Receive promised files (screenshot thumbnail, Photos, …) into a fresh private dir under
    /// `imageDirectory`; `done` gets the files that arrived, on the main queue.
    public static func receive(_ promises: [NSFilePromiseReceiver], done: @escaping ([URL]) -> Void) {
        let fm = FileManager.default
        try? fm.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        pruneImages()
        let dest = imageDirectory.appendingPathComponent("dropped-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let queue = OperationQueue()
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in promises {
            for _ in p.fileTypes { group.enter() }
            if p.fileTypes.isEmpty { group.enter() }
            p.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { url, error in
                if error == nil {
                    chmod(url.path, 0o600)
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls.sorted { $0.path < $1.path }) }
    }

    /// True if `string(from:)` will have something (cheap: declared types only).
    public static func hasContents(_ pb: NSPasteboard) -> Bool {
        let types = pb.types ?? []
        return types.contains(.fileURL) || types.contains(.string) || types.contains(.png) || types.contains(.tiff)
    }

    /// The pasteboard's image as a PNG file in `imageDirectory`, 0600.
    static func saveImage(from pb: NSPasteboard) -> URL? {
        let data: Data?
        if let png = pb.data(forType: .png) {
            data = png
        } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        } else {
            data = nil
        }
        guard let data else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        pruneImages()
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let url = imageDirectory.appendingPathComponent("pasted-\(stamp)-\(UUID().uuidString.prefix(6)).png")
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }

    static func pruneImages(olderThan age: TimeInterval = 86400) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for f in files {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(m) > age { try? fm.removeItem(at: f) }
        }
    }
}
