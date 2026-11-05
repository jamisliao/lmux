// Enable the macOS Korean 2-Set (두벌식) input source on a CI runner, so
// `App/scripts/imetest.sh --visible` can run its real-IME checks instead of
// skipping them. CI only: it changes the machine's enabled input sources, so it
// refuses to run unless GITHUB_ACTIONS=true (never on a developer's Mac).
//
//   swift .github/scripts/enable-korean-ime.swift
import Carbon
import Foundation

guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
    FileHandle.standardError.write("enable-korean-ime: refusing to run outside GitHub Actions (GITHUB_ACTIONS != true)\n".data(using: .utf8)!)
    exit(2)
}

let korean = "com.apple.inputmethod.Korean.2SetKorean"

func sources(includeAllInstalled: Bool) -> [TISInputSource] {
    (TISCreateInputSourceList(nil, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

func id(_ s: TISInputSource) -> String {
    guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func isEnabled(_ want: String) -> Bool { sources(includeAllInstalled: false).contains { id($0) == want } }

// The Korean input method itself (com.apple.inputmethod.Korean) and its 2-Set mode.
for s in sources(includeAllInstalled: true) where id(s) == "com.apple.inputmethod.Korean" || id(s) == korean {
    let err = TISEnableInputSource(s)
    print("TISEnableInputSource(\(id(s))) = \(err)")
}

// The enabled list can take a moment to reflect the change.
for _ in 0..<50 where !isEnabled(korean) { usleep(100_000) }
guard isEnabled(korean) else {
    print("\(korean) is still not enabled; installed Korean sources:",
          sources(includeAllInstalled: true).map(id).filter { $0.contains("Korean") })
    exit(1)
}
print("\(korean) is enabled. Enabled keyboard sources:",
      sources(includeAllInstalled: false).map(id).filter { $0.hasPrefix("com.apple.inputmethod") || $0.hasPrefix("com.apple.keylayout") })
