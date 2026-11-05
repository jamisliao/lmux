import AppKit
import LmuxTerminal
@testable import LmuxUI

/// Key -> pty latency, headless: from keyDown entry in the surface to the byte showing up
/// in the pane's pty sink (`cat > file`), sampled by a background thread polling the file.
@MainActor
func runLatency() async -> Int32 {
    let c = makeController()
    let w = c.window!
    let p = c.model.selected!.panes[0]
    _ = await sinks.waitReady(p.id)
    let url = sinks.dir.appendingPathComponent("\(p.id).bin")
    var start: UInt64 = 0
    SurfaceView.keyDownProbe = { start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    var samples: [Double] = []
    for i in 0..<200 {
        let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let seen = Task.detached { () -> UInt64 in
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 1_000_000_000
            while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {
                var st = stat()
                if stat(url.path, &st) == 0, Int(st.st_size) > before { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
                usleep(50)
            }
            return 0
        }
        await type(i % 2 == 0 ? "a" : "s", window: w)
        let t = await seen.value
        if t > start, start > 0 { samples.append(Double(t - start) / 1e6) }
        await sleepMs(10)
    }
    SurfaceView.keyDownProbe = nil
    samples.sort()
    func pct(_ q: Double) -> Double { samples.isEmpty ? .nan : samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
    print(String(format: "LATENCY key->pty (n=%d): p50 %.2fms p95 %.2fms max %.2fms", samples.count, pct(0.5), pct(0.95),
                 samples.last ?? .nan))
    c.shutdown()
    return samples.count >= 150 ? 0 : 1
}
