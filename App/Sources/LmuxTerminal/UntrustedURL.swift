// Adapted from Ghostty (https://github.com/ghostty-org/ghostty) at commit ff23824:
//   macos/Sources/Helpers/UntrustedURL.swift (the policy, unchanged but `public`, except that
//   isUnsafeCharacter also blocks U+00AD and U+3164, two more invisible characters — see there,
//   more extensions are blocked, and an OSC 8 label that reads as another host is asked about)
//   macos/Sources/Helpers/UntrustedURLAlert.swift (confirm / block alerts)
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// A URL supplied by a source that should not be allowed to dispatch directly
/// to the operating system, such as terminal output.
public struct UntrustedURL: Equatable {
    public enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile

        public var message: String {
            switch self {
            case .malformedURL:
                "The target is not an absolute URL with a scheme."
            case .unsafeCharacters:
                "The target contains invisible or line-breaking characters."
            case .invalidWebURL:
                "The web target does not contain a valid host."
            case .inaccessibleFile:
                "The local target does not exist or is not a regular file or directory."
            case .unsafeFile:
                "Opening this local target could execute code."
            }
        }
    }

    public enum Decision: Equatable {
        /// Open schemes with non-executing, well-understood behavior directly.
        case allow(URL)

        /// Ask before dispatching a custom scheme to its registered handler.
        case confirm(URL)

        /// Never dispatch malformed targets or executable local files.
        case deny(DenialReason)
    }

    public let string: String

    public init(_ string: String) {
        self.string = string
    }

    public var decision: Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }

        // Foundation accepts many Unicode control and formatting characters in
        // a URL. UI frameworks can render those same characters as line breaks,
        // zero-width text, or bidirectional overrides, so reject them before
        // parsing changes their representation.
        guard !Self.containsUnsafeCharacters(string) else {
            return .deny(.unsafeCharacters)
        }

        // URL(string:) also accepts relative references. An untrusted target
        // must include an explicit scheme so it cannot be reinterpreted as a
        // local path by a later layer.
        guard
            let url = URL(string: string),
            let scheme = url.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http", "https":
            // Reject values such as "https:relative". They have a scheme, but
            // no authority, and different consumers may resolve them against a
            // base URL differently.
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)

        case "mailto":
            // URLComponents places the address portion of a mailto URL in the
            // path. Require one so a bare "mailto:" cannot dispatch an empty
            // request to the user's mail application.
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                !components.path.isEmpty
            else {
                return .deny(.malformedURL)
            }
            return .allow(url)

        case "file":
            return fileDecision(for: url)

        default:
            // A custom scheme can invoke any application registered with
            // Launch Services. The caller must show the target and handler
            // before allowing that dispatch.
            return .confirm(url)
        }
    }

    /// Whether `value` contains control, invisible, or text-reversing
    /// characters. Use this to check a value before converting it to a URL,
    /// since conversion can percent-encode these characters.
    public static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isUnsafeCharacter)
    }

    /// A single-line representation of the effective target. Paths are
    /// standardized before display so traversal and repeated separators cannot
    /// cause the visible and opened targets to differ.
    public var displayString: String {
        let normalized: String
        if let url = URL(string: string), url.scheme != nil {
            // File URLs are standardized exactly as they are before opening,
            // including symlink resolution. Keep non-file URLs byte-for-byte
            // equivalent because repeated separators can be meaningful to a
            // web or custom-scheme handler.
            normalized = url.isFileURL
                ? url.standardizedFileURL.resolvingSymlinksInPath().path
                : string
        } else {
            // Scheme-less values are never allowed to open, but they still
            // appear in the blocked-target UI. Standardizing them prevents
            // slash padding and dot traversal from hiding the effective path.
            normalized = URL(filePath: string).standardizedFileURL.path
        }

        // Escaping happens after normalization so any unsafe scalar that
        // remains is visible as text and cannot create a second display line.
        var result = String()
        result.reserveCapacity(normalized.count)
        for scalar in normalized.unicodeScalars {
            if Self.isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        return result
    }

    /// lmux: the host a link's visible text (the word under the pointer) reads as, if it looks like
    /// an address: `https://…`, `www.…`, or `name.tld[/…]` (common file names such as `README.md`
    /// don't count).
    public static func labelHost(_ word: String) -> String? {
        var w = word.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'()[]{}<>.,;:!?"))
        if let r = w.range(of: "://") { w = String(w[r.upperBound...]) }
        while w.hasPrefix("/") { w.removeFirst() }
        let host = String(w.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" }).lowercased()
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        let explicit = word.contains("://") || host.hasPrefix("www.")
        guard explicit || !fileExtensions.contains(String(tld)) else { return nil }
        return host
    }

    /// lmux: the label's host when the visible text reads as one address and the link opens
    /// another (`paypal.com` linking to `paypal.com.evil.io`); nil when they agree (a subdomain of
    /// the label's host counts as agreeing) or the label isn't an address.
    public static func misleadingLabel(_ label: String?, target: URL) -> String? {
        guard let label, let shown = labelHost(label) else { return nil }
        func bare(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        let s = bare(shown), t = bare((target.host ?? "").lowercased())
        return t == s || t.hasSuffix("." + s) ? nil : shown
    }

    static let fileExtensions: Set<String> = [
        "md", "txt", "json", "jsonl", "yml", "yaml", "toml", "lock", "log", "swift", "js", "ts", "tsx", "jsx", "py",
        "rs", "go", "rb", "sh", "zsh", "html", "css", "png", "jpg", "jpeg", "gif", "svg", "pdf", "zip", "gz", "tar",
        "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "plist", "xml", "csv", "diff", "patch", "env", "cfg", "conf",
    ]
}

private extension UntrustedURL {
    func fileDecision(for url: URL) -> Decision {
        // Only local file URLs are meaningful here. Queries and fragments do
        // not identify part of a filesystem object and may be interpreted
        // inconsistently by Launch Services handlers.
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformedURL)
        }

        // An empty host and localhost both refer to this machine. Do not allow
        // file URLs that name a remote host and could trigger network access.
        if let host = url.host,
           !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny(.malformedURL)
        }

        // Classify the effective object, not the spelling supplied by terminal
        // output. This collapses dot traversal and prevents a harmless-looking
        // symlink name from hiding an executable target.
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues: URLResourceValues
        do {
            // Reading all relevant resource keys together also proves that the
            // canonical target exists and is accessible.
            resourceValues = try canonicalURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .isExecutableKey,
                .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }

        // Exclude devices, sockets, and other special filesystem objects. A
        // directory is safe to reveal in Finder unless its extension or UTI
        // identifies it as an application bundle.
        guard resourceValues.isDirectory == true || resourceValues.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !Self.isUnsafeFile(canonicalURL, resourceValues: resourceValues) else {
            return .deny(.unsafeFile)
        }

        return .allow(canonicalURL)
    }

    static func isUnsafeFile(
        _ url: URL,
        resourceValues: URLResourceValues
    ) -> Bool {
        // Launch Services uses extensions when choosing a handler. Block known
        // executable containers even when their POSIX executable bit is clear.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        // UTIs cover files whose extension is missing or intentionally
        // misleading. Use broad system-declared types so subclasses such as
        // shell scripts and application bundles are included automatically.
        if let contentType = resourceValues.contentType,
           unsafeContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            return true
        }

        // Finally, reject any regular file the filesystem marks executable,
        // regardless of its name or detected content type.
        return resourceValues.isDirectory != true && resourceValues.isExecutable == true
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0/C1 controls include CR, LF, NEL, and other non-printing bytes.
        case 0x00...0x1F, 0x7F...0x9F:
            return true

        // Directional marks and zero-width characters can reorder or conceal
        // portions of the target without changing what the handler receives.
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true

        // Unicode line/paragraph separators create additional visual lines in
        // SwiftUI and AppKit text even though OSC accepts their UTF-8 bytes.
        case 0x2028...0x2029:
            return true

        // Word Joiner and BOM are invisible formatting characters that can be
        // used as padding or to disguise otherwise identical-looking targets.
        case 0x2060, 0xFEFF:
            return true

        // Soft hyphen and Hangul filler: also invisible in rendered text, also usable as
        // padding to disguise a target. Neither appears in a legitimate URL, so blocking them
        // doesn't affect normal use; lmux's one addition to this policy beyond Ghostty's.
        case 0x00AD, 0x3164:
            return true

        default:
            return false
        }
    }

    // Keep the large policy tables after the behavior so the primary type and
    // its decision flow remain easy to scan.
    static let unsafePathExtensions: Set<String> = [
        "action",
        "app",
        "applescript",
        "class",
        "command",
        "desktop",
        "inetloc",
        "jar",
        "mobileconfig",
        "mpkg",
        "pkg",
        "scpt",
        "terminal",
        "tool",
        "url",
        "webloc",
        "workflow",
        // lmux: more types Launch Services hands to something that runs or installs code.
        "appex",
        "bundle",
        "fileloc",
        "kext",
        "mdimporter",
        "osax",
        "plugin",
        "prefpane",
        "qlgenerator",
        "saver",
        "scptd",
        "service",
        "shortcut",
        "xpc",
    ]

    static let unsafeContentTypes: [UTType] = [
        .application,
        .executable,
        .script,
    ]
}

// MARK: - Alerts (UntrustedURLAlert.swift)

/// lmux: what the policy asks the user (tests answer it through `UntrustedURLAlert.testHook`).
public enum UntrustedURLPrompt: Equatable {
    /// A custom scheme: open it in `handler` (an app name, or "the default application")?
    case confirm(url: URL, display: String, handler: String)
    /// Blocked: say why; the only way forward is copying the (sanitized) target.
    case block(reason: UntrustedURL.DenialReason, display: String)
    /// lmux: the link's text reads as `label` but it opens another address: open it anyway?
    case mismatch(url: URL, display: String, label: String)
}

/// Presents decisions for untrusted URLs at the AppKit boundary. lmux: as a sheet on the
/// pane's window (never an app-modal alert), opened through `GhosttyRuntime.openURL`, and
/// "Copy Link" uses `GhosttyRuntime.standardPasteboard`.
public enum UntrustedURLAlert {
    /// Tests: called instead of showing an alert; returns the user's answer (Open Link / Copy Link).
    public static var testHook: ((UntrustedURLPrompt) -> Bool)?

    /// Apply the policy to `value` (terminal output: OSC 8 or a ⌘-clicked link).
    static func open(_ value: String, window: NSWindow?, label: String? = nil) {
        let target = UntrustedURL(value)
        switch target.decision {
        case .allow(let url):
            if let shown = UntrustedURL.misleadingLabel(label, target: url) {
                ask(.mismatch(url: url, display: target.displayString, label: shown), window: window) {
                    GhosttyRuntime.openURL(url)
                }
                return
            }
            GhosttyRuntime.openURL(url)
        case .confirm(let url):
            let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
                .map { "\u{201c}\($0.deletingPathExtension().lastPathComponent)\u{201d}" }
                ?? "the default application"
            ask(.confirm(url: url, display: target.displayString, handler: handler), window: window) {
                GhosttyRuntime.openURL(url)
            }
        case .deny(let reason):
            let display = target.displayString
            ask(.block(reason: reason, display: display), window: window) {
                // Keep blocked targets out of Launch Services. Copying the displayed, sanitized
                // value gives the user an explicit path forward without a one-click bypass.
                let pasteboard = GhosttyRuntime.standardPasteboard
                pasteboard.clearContents()
                pasteboard.setString(display, forType: .string)
            }
        }
    }

    private static func ask(_ prompt: UntrustedURLPrompt, window: NSWindow?, onSecondButton: @escaping () -> Void) {
        if let testHook {
            if testHook(prompt) { onSecondButton() }
            return
        }
        // No window to attach a sheet to, or headless (nothing may be shown): nothing is opened
        // (never an app-modal alert).
        guard let window, !GhosttyRuntime.headless else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        switch prompt {
        case .confirm(_, let display, let handler):
            alert.messageText = "Open Link from Terminal Output?"
            alert.informativeText = """
            This link will open in \(handler). Only continue if you recognize \
            and trust the destination.
            """
            alert.accessoryView = targetView(display)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Link")
        case .mismatch(_, let display, let label):
            alert.messageText = "Open Link from Terminal Output?"
            alert.informativeText = """
            The link's text reads \u{201c}\(label)\u{201d}, but it opens a different address. Only \
            continue if you trust the destination.
            """
            alert.accessoryView = targetView(display)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Link")
        case .block(let reason, let display):
            alert.messageText = "lmux Blocked This Link"
            alert.informativeText = reason.message
            alert.accessoryView = targetView(display)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Link")
        }
        // Cancel / OK is deliberately the default action.
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { onSecondButton() }
        }
    }

    private static func targetView(_ target: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = target
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }
}
