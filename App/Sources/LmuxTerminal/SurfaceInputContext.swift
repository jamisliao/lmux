// Adapted from ghostty-org/ghostty PR #14946 ("macos: preserve initial Korean IME
// composition"). Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Carbon
import ObjectiveC

/// The surface's input context, with TSM *document access* turned off before its first
/// `activate()`.
///
/// AppKit's default context advertises document access, so Apple's Korean IME starts a
/// composition after a passthrough key in "direct" mode: it commits the first jamo with
/// `insertText` and expects to rebuild the syllable later by replacing that committed text.
/// A terminal can't take back bytes already written to the pty, so 하 arrived as ㅎㅏ
/// (ghostty-org/ghostty#13235). Without document access the IME marks the first jamo, as
/// every other composition.
///
/// The TSM document is only reachable through the context's private `_documentID` ivar; its
/// type, alignment and bounds are checked, and on any mismatch this is a plain context.
final class SurfaceInputContext: NSTextInputContext {
    override init(client: NSTextInputClient) {
        super.init(client: client)
        guard let doc = documentID else { return }
        TSMRemoveDocumentProperty(doc, TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
    }

    /// The TSM document behind this context (nil if AppKit's layout isn't the expected one).
    var documentID: TSMDocumentID? {
        guard let offset = Self.documentIDOffset else { return nil }
        return Unmanaged.passUnretained(self).toOpaque().advanced(by: offset).load(as: TSMDocumentID?.self)
    }

    /// Whether the document advertises document access (tests).
    var advertisesDocumentAccess: Bool? {
        guard let doc = documentID else { return nil }
        var size: UInt32 = 0
        return TSMGetDocumentProperty(doc, TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag),
                                      0, &size, nil) == noErr
    }

    private static let documentIDOffset: Int? = {
        guard let ivar = class_getInstanceVariable(NSTextInputContext.self, "_documentID"),
              let enc = ivar_getTypeEncoding(ivar), String(cString: enc) == "^v" else { return nil }
        let off = ivar_getOffset(ivar), l = MemoryLayout<TSMDocumentID?>.self
        guard off >= 0, off % l.alignment == 0,
              off + l.size <= class_getInstanceSize(NSTextInputContext.self) else { return nil }
        return off
    }()
}
