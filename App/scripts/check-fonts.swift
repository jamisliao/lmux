// bundle.sh: the TTFs it unpacked from the WOFFs register with CoreText as D2Coding Regular + Bold
// and cover ASCII and Hangul. Exit 1 otherwise.
//   xcrun swift App/scripts/check-fonts.swift DIR
import CoreText
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "ttf" }
var styles: Set<String> = [], ok = true
for url in files {
    var err: Unmanaged<CFError>?
    let descs = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
    guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err), let d = descs.first else {
        print("error: \(url.lastPathComponent): CoreText can't register it"); ok = false; continue
    }
    let font = CTFontCreateWithFontDescriptor(d, 13, nil)
    let family = CTFontCopyFamilyName(font) as String, style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? ""
    let text = Array("Ag한글".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: text.count)
    let covers = CTFontGetGlyphsForCharacters(font, text, &glyphs, text.count) && !glyphs.contains(0)
    if family != "D2Coding" || !covers {
        print("error: \(url.lastPathComponent): family \(family), ASCII + Hangul glyphs \(covers)"); ok = false
    }
    styles.insert(style)
}
if styles != ["Regular", "Bold"] { print("error: \(dir.path): faces \(styles.sorted()), expected Bold + Regular"); ok = false }
if ok { print("fonts: D2Coding Regular + Bold (TTF) register with CoreText, ASCII + Hangul") }
exit(ok ? 0 : 1)
