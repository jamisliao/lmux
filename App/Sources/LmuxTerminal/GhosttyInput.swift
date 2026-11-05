// Adapted from Ghostty (https://github.com/ghostty-org/ghostty) at commit ff23824:
//   macos/Sources/Ghostty/Ghostty.Input.swift   (ghosttyMods / eventModifierFlags)
//   macos/Sources/Ghostty/NSEvent+Extension.swift (verbatim)
//   macos/Sources/Helpers/KeyboardLayout.swift   (id only)
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import Carbon
import GhosttyKit

public enum Ghostty {
    /// Returns the event modifier flags set for the Ghostty mods enum.
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Translate event modifier flags to a ghostty mods enum.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Handle sided input. We can't tell that both are pressed in the
        // Ghostty structure but that's okay -- we don't use that information.
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }
}

enum KeyboardLayout {
    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = unsafeBitCast(sourceIdPointer, to: CFString.self)
            return sourceId as String
        }

        return nil
    }

    /// lmux: the character of `keyCode` (unshifted, or with Shift) on the ASCII-capable layout ("c" for
    /// key code 8), if ASCII.
    static func asciiCharacter(keyCode: UInt16, shift: Bool = false) -> UInt32? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt32? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0, len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            guard UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                 OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars) == noErr,
                  len == 1, chars[0] > 0x20, chars[0] < 0x7F else { return nil }
            return UInt32(chars[0])
        }
    }
}

extension Ghostty {
    /// lmux: a character only an input method's own key layout gives a key: Hangul jamo (Korean 2-Set,
    /// ㅊ for C), kana (Japanese Kana Typing, そ for C) or bopomofo and its tone marks (Zhuyin, ㄏ for
    /// C, ˇ for 3). Never a key of a plain keyboard layout (Cyrillic с stays с, as the kitty spec has it).
    public static func isInputMethodKeyCharacter(_ v: UInt32) -> Bool {
        (0x3131...0x318E).contains(v) || (0x1100...0x11FF).contains(v)
            || (0x3041...0x30FF).contains(v) || (0x3100...0x312F).contains(v) || (0x31A0...0x31BF).contains(v)
            || [0x02C7, 0x02CA, 0x02CB, 0x02D9].contains(v)
    }

    /// lmux: the unshifted codepoint to encode for a Control or Command key. With the Korean input
    /// source the key's own character is the Hangul jamo (ㅊ for C), and the kitty keyboard protocol
    /// encodes that codepoint: Ctrl+C would reach a program that enabled it (Claude Code) as Ctrl+ㅊ
    /// (CSI 12618;5u), not an interrupt, and ⌘C as ⌘+ㅊ (CSI 12618;9u) besides copying; both get typed
    /// as "ㅊ". Encode the key as the ASCII layout has it, which also lets ⌘C match its keybind.
    /// The same for kana and bopomofo (`isInputMethodKeyCharacter`).
    public static func controlKeyCodepoint(_ codepoint: UInt32, keyCode: UInt16) -> UInt32 {
        guard isInputMethodKeyCharacter(codepoint),
              let ascii = KeyboardLayout.asciiCharacter(keyCode: keyCode) else { return codepoint }
        return ascii
    }

    /// lmux: the text of a Control key (its character without Control). Ghostty encodes the keys with
    /// no C0 byte of their own (Ctrl+I, Ctrl+M) and Ctrl+Shift+key from it as fixterms CSI u, even in
    /// legacy mode, so with the Korean source Ctrl+I went out as Ctrl+ㅑ (CSI 12625;5u, not 105;5u).
    /// A jamo (or kana, bopomofo) becomes the key's character on the ASCII layout, as in `controlKeyCodepoint`.
    public static func controlKeyText(_ text: String?, keyCode: UInt16, shift: Bool) -> String? {
        guard let text, text.unicodeScalars.count == 1, let v = text.unicodeScalars.first?.value,
              isInputMethodKeyCharacter(v),
              let ascii = KeyboardLayout.asciiCharacter(keyCode: keyCode, shift: shift),
              let scalar = UnicodeScalar(ascii) else { return text }
        return String(Character(scalar))
    }
}

extension NSEvent {
    /// lmux: tests: the keyboard layout's characters for this event's key with `modifiers` applied,
    /// or nil to ask AppKit. The IME harness sets it to the Korean 2-Set layout so its synthetic
    /// events carry the jamo whatever input source the machine has selected.
    public static var layoutCharactersOverride: ((NSEvent, NSEvent.ModifierFlags) -> String?)?

    /// lmux: `characters(byApplyingModifiers:)` through `layoutCharactersOverride`.
    func layoutCharacters(byApplyingModifiers modifiers: NSEvent.ModifierFlags) -> String? {
        Self.layoutCharactersOverride?(self, modifiers) ?? characters(byApplyingModifiers: modifiers)
    }

    /// Create a Ghostty key event for a given keyboard action.
    ///
    /// This will not set the "text" or "composing" fields since these can't safely be set
    /// with the information or lifetimes given.
    ///
    /// The translationMods should be set to the modifiers used for actual character
    /// translation if available.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key_ev: ghostty_input_key_s = .init()
        key_ev.action = action
        key_ev.keycode = UInt32(keyCode)

        // We can't infer or set these safely from this method. Since text is
        // a cString, we can't use self.characters because of garbage collection.
        // We have to let the caller handle this.
        key_ev.text = nil
        key_ev.composing = false

        // macOS provides no easy way to determine the consumed modifiers for
        // producing text. We apply a simple heuristic here that has worked for years
        // so far: control and command never contribute to the translation of text,
        // assume everything else did.
        key_ev.mods = Ghostty.ghosttyMods(modifierFlags)
        key_ev.consumed_mods = Ghostty.ghosttyMods(
            (translationMods ?? modifierFlags)
                .subtracting([.control, .command]))

        // Our unshifted codepoint is the codepoint with no modifiers. We
        // ignore multi-codepoint values. We have to use `byApplyingModifiers`
        // instead of `charactersIgnoringModifiers` because the latter changes
        // behavior with ctrl pressed and we don't want any of that.
        key_ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = layoutCharacters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
            if !modifierFlags.isDisjoint(with: [.control, .command]) {
                key_ev.unshifted_codepoint = Ghostty.controlKeyCodepoint(key_ev.unshifted_codepoint, keyCode: keyCode)
            }
        }

        return key_ev
    }

    /// Returns the text to set for a key event for Ghostty.
    ///
    /// This namely contains logic to avoid control characters, since we handle control character
    /// mapping manually within Ghostty.
    var ghosttyCharacters: String? {
        // If we have no characters associated with this event we do nothing.
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // If we have a single control character, then we return the characters
            // without control pressed. We do this because we handle control character
            // encoding directly within Ghostty's KeyEncoder.
            if scalar.value < 0x20 {
                return Ghostty.controlKeyText(self.layoutCharacters(byApplyingModifiers: modifierFlags.subtracting(.control)),
                                              keyCode: keyCode, shift: modifierFlags.contains(.shift))
            }

            // If we have a single value in the PUA, then it's a function key and
            // we don't want to send PUA ranges down to Ghostty.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}

// From macos/Sources/Helpers/Extensions/String+Extension.swift
extension String {
    /// True when the first scalar is an ASCII control character (C0 or DEL).
    var startsWithASCIIControlCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// The string as the text of a terminal key event, or nil when it is empty
    /// or begins with an ASCII control character.
    ///
    /// - Note: Control characters are encoded by Ghostty itself so that the
    /// physical key and its modifiers remain available to protocols
    /// such as the Kitty keyboard protocol.
    var keyEventText: String? {
        guard !isEmpty, !startsWithASCIIControlCharacter else { return nil }
        return self
    }
}
