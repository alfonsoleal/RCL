// iOSClient/AutoQuality.swift on its own, with StreamProtocol's HostSettings.swift: the device lowers
// the Mac's quality when the link is behind, at most every 8 s, comes back a step at a time toward
// what the person picked once a moving picture has kept up, waits twice as long after a step up that
// failed, never past 4 minutes, counts no still seconds, and forgets it all at the person's own pick.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok" : "FAIL") \(what)")
    if !ok { failures += 1 }
}
typealias Q = AutoQuality.Quality
let pro = Q(bitrate: 40_000_000, captureScale: 2), lowStd = Q(bitrate: 4_000_000, captureScale: 1)
func behind(_ at: Q, to s: Q?) -> LinkReport {
    LinkReport(state: LinkReport.behind, withheldPerSecond: 30, bitrate: at.bitrate, carriedKbps: 5_000,
               suggestedBitrate: s?.bitrate, suggestedCaptureScale: s.flatMap { $0.captureScale != at.captureScale ? $0.captureScale : nil })
}

// Down at once to the suggestion; the ceiling is what ran.
var a = AutoQuality()
check(a.second(now: 0, current: pro, link: nil, away: nil, fps: 60) == .none, "keeping up, nothing lowered: nothing")
check(a.second(now: 1, current: pro, link: behind(pro, to: lowStd), away: nil, fps: 5) == .change(lowStd, down: true), "behind: down to the suggestion")
check(a.ceiling == pro, "the ceiling is what the person had")
check(a.second(now: 5, current: lowStd, link: behind(lowStd, to: nil), away: nil, fps: 5) == .none, "nothing lower to offer: nothing")
check(a.second(now: 6, current: pro, link: behind(pro, to: lowStd), away: nil, fps: 5) == .none, "within 8 s of the last change: nothing")

// Up: 30 moving seconds, a step at a time, bitrate first, resolution last.
var t = 10.0, cur = lowStd, ups: [Q] = []
for _ in 0..<400 {
    t += 1
    if case .change(let q, let down) = a.second(now: t, current: cur, link: nil, away: nil, fps: 60) { check(!down, "a step up"); ups.append(q); cur = q }
}
check(ups.map(\.bitrate) == [8_000_000, 15_000_000, 25_000_000, 40_000_000, 40_000_000], "presets in order to the ceiling: \(ups.map(\.bitrate))")
check(ups.last == pro && ups.dropLast().allSatisfy { $0.captureScale == 1 }, "the resolution comes back last")
check(a.ceiling == nil, "back at the ceiling: nothing to come back to")

// Still seconds don't count.
var b = AutoQuality()
_ = b.second(now: 0, current: pro, link: behind(pro, to: lowStd), away: nil, fps: 5)
var stepped = false
for i in 1...200 { if case .change = b.second(now: Double(i), current: lowStd, link: nil, away: nil, fps: 2) { stepped = true } }
check(!stepped, "a still window never steps up")

// A failed step up doubles the wait, up to 4 minutes.
var c = AutoQuality(); var now = 0.0; var q = pro
_ = c.second(now: now, current: q, link: behind(q, to: lowStd), away: nil, fps: 5); q = lowStd
var waits: [Int] = []
for _ in 0..<6 {
    var up: Q?
    while up == nil { now += 1; if case .change(let n, _) = c.second(now: now, current: q, link: nil, away: nil, fps: 60) { up = n } }
    q = up!
    now += 10
    _ = c.second(now: now, current: q, link: behind(q, to: lowStd), away: nil, fps: 5); q = lowStd
    waits.append(c.upWait)
}
check(waits == [60, 120, 240, 240, 240, 240], "the wait doubles after each failed step up: \(waits)")

// Away while a device at home is connected: the Mac keeps the home quality.
var d = AutoQuality()
let mixed = AwayQuality(homeBitrate: 40_000_000, homeCaptureScale: 2, awayBitrate: 4_000_000, awayCaptureScale: 1, thisConnectionAway: true, awayRunning: false)
check(d.second(now: 0, current: pro, link: behind(pro, to: lowStd), away: mixed, fps: 5) == .none, "a device at home keeps the quality: nothing")

// Stalled: nothing to judge.
var e = AutoQuality()
let stalled = LinkReport(state: LinkReport.stalled, withheldPerSecond: 0, bitrate: pro.bitrate)
check(e.second(now: 0, current: pro, link: stalled, away: nil, fps: 0) == .none, "stalled: nothing")

// The person's pick forgets everything.
var f = AutoQuality()
_ = f.second(now: 0, current: pro, link: behind(pro, to: lowStd), away: nil, fps: 5)
f.picked()
check(f.ceiling == nil && f.upWait == 30, "a pick of the person's own: nothing to come back to")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
