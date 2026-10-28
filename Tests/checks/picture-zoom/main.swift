import CoreGraphics

var failures = 0, checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL (line \(line)): \(what())") }
}
func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.001) -> Bool { abs(a - b) < eps }
func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

let size = CGSize(width: 1000, height: 700)
let video = CGRect(x: 0, y: 50, width: 1000, height: 600)       // a letterboxed picture
/// Where a view point lands in the video, as a fraction (what InputOverlayView sends the Mac).
func fraction(_ p: CGPoint, _ z: PictureZoom) -> CGPoint {
    let r = z.rect(video, in: size)
    return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
}
/// Where the picture view draws a view point of its own after the zoom's transform (about its centre).
func drawn(_ p: CGPoint, _ z: PictureZoom) -> CGPoint {
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    let q = CGPoint(x: p.x - c.x, y: p.y - c.y).applying(z.transform)
    return CGPoint(x: q.x + c.x, y: q.y + c.y)
}

// Unzoomed: nothing moves.
var z = PictureZoom()
check(!z.isZoomed && z.transform == .identity && z.rect(video, in: size) == video, "unzoomed is the identity")

// A pinch keeps what is under the fingers under them.
let focus = CGPoint(x: 800, y: 200)
let before = fraction(focus, z)
z.pinch(by: 2, at: focus, in: size)
check(near(z.scale, 2) && z.isZoomed, "pinched to 2×")
check(near(fraction(focus, z), before), "the point under the fingers stays: \(fraction(focus, z)) vs \(before)")

// The input's mapping and the picture's drawing agree: a video point drawn at p maps back from p.
let videoPoint = CGPoint(x: video.minX + 0.3 * video.width, y: video.minY + 0.7 * video.height)
check(near(fraction(drawn(videoPoint, z), z), CGPoint(x: 0.3, y: 0.7)), "a tap lands on what is drawn under it")

// Never below 1 or above the most.
z.pinch(by: 100, at: focus, in: size)
check(near(z.scale, PictureZoom.maxScale), "at most \(PictureZoom.maxScale)×")
z.pinch(by: 0.001, at: focus, in: size)
check(near(z.scale, 1) && near(z.offset, .zero), "never below 1×, and then centred")

// A near-whole pinch snaps back; a real one stays.
z = PictureZoom(); z.pinch(by: 1.05, at: focus, in: size); z.settle()
check(z == PictureZoom(), "1.05× settles to the whole picture")
z = PictureZoom(); z.pinch(by: 1.5, at: focus, in: size); z.settle()
check(near(z.scale, 1.5), "1.5× stays")

// Panning stops where the magnified picture would leave the view.
z = PictureZoom(); z.pinch(by: 2, at: CGPoint(x: 500, y: 350), in: size)
z.pan(by: CGPoint(x: 10_000, y: -10_000), in: size)
check(near(z.offset, CGPoint(x: 500, y: -350)), "clamped at the edges: \(z.offset)")

// The pointer at an edge moves the picture so more of that side shows.
check(PictureZoom.edgePan(at: CGPoint(x: 995, y: 350), in: size).x < 0, "the right edge moves the picture left")
check(PictureZoom.edgePan(at: CGPoint(x: 3, y: 3), in: size) == CGPoint(x: 14, y: 14), "the top left corner, both ways")
check(PictureZoom.edgePan(at: CGPoint(x: 500, y: 350), in: size) == .zero, "the middle, nowhere")

// Random pinches and pans: always within the limits, always covering the view, and the mapping
// always the inverse of the drawing.
var seed: UInt64 = 0x5EED_2006
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 11) / CGFloat(1 << 53) }
var broken = 0
for _ in 0..<20_000 {
    if rnd() < 0.5 { z.pinch(by: 0.5 + rnd() * 1.5, at: CGPoint(x: rnd() * size.width, y: rnd() * size.height), in: size) }
    else { z.pan(by: CGPoint(x: (rnd() - 0.5) * 400, y: (rnd() - 0.5) * 400), in: size) }
    if rnd() < 0.05 { z.settle() }
    let full = z.rect(CGRect(origin: .zero, size: size), in: size)
    let covers = full.minX <= 0.001 && full.minY <= 0.001 && full.maxX >= size.width - 0.001 && full.maxY >= size.height - 0.001
    let p = CGPoint(x: video.minX + rnd() * video.width, y: video.minY + rnd() * video.height)
    let back = fraction(drawn(p, z), z)
    let expect = CGPoint(x: (p.x - video.minX) / video.width, y: (p.y - video.minY) / video.height)
    if !(z.scale >= 1 && z.scale <= PictureZoom.maxScale && covers && near(back, expect)) { broken += 1 }
}
check(broken == 0, "random: \(broken) of 20,000 steps broke a limit, the cover or the mapping")

print(failures == 0 ? "ok: \(checks) checks" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
