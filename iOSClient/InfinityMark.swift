import SwiftUI

/// RCL's mark on the connect screen, where Sill had its footer of links: Loop's glass infinity
/// (Infinity.metal) with its green light going round. At rest the light makes a turn about every
/// eight seconds; while no Mac is listed yet (`searching`) it runs faster with a longer trail, as
/// Loop's does while it thinks. Decoration only: no touch, no VoiceOver.
struct InfinityMark: View {
    var searching = false
    @State private var motion = InfinityMotion()

    var body: some View {
        GeometryReader { geo in
            // 60 frames are plenty for light that glides; 120 would only spend battery.
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                let frame = motion.frame(at: context.date, size: geo.size, searching: searching)
                Rectangle()
                    .fill(.black)
                    .colorEffect(ShaderLibrary.tuboInfinito(
                        .floatArray(frame.points), .floatArray(frame.particles),
                        .floatArray(frame.waves), .floatArray(frame.settings)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Loop's InfinitoMotor (~/Trabajo/Asistente) reduced to what the connect screen needs: its
/// neutral pose, its idle drift and its "thinking" run. No voice, no emotions. A class, so the
/// frame before lives outside SwiftUI's state (writing state while drawing would redraw forever).
final class InfinityMotion {
    struct Frame {
        var points: [Float] = []      // x, y, e, f a point
        var particles: [Float] = []   // x, y, f a particle
        var waves: [Float] = [0, 0, 0]
        var settings: [Float] = []    // the shader's enum, kR…kY1
    }

    // The settings Alfonso chose in Loop's mock-up.
    private static let glass = 0.3, thickness = 0.9, particleLight = 1.2, segments = 90
    private var t = 0.0, turn = 0.0, pos = 0.12, trail = 1.0
    private var last: Date?

    func frame(at date: Date, size: CGSize, searching: Bool) -> Frame {
        let dt = min(1 / 20, max(1 / 240, last.map { date.timeIntervalSince($0) } ?? 1 / 60))
        last = date
        t += dt
        turn += dt * 0.18
        // Searching: the light runs (a turn in about two seconds) and its trail stretches.
        pos = wrap(pos + (searching ? 0.55 : 0.12) * dt)
        trail += ((searching ? 6 : 1) - trail) * 0.05

        let W = size.width, H = size.height
        let A = W * 0.40
        let cy = H * 0.5 + sin(t * 0.9) * 3 * 1.4
        let yaw = 0.25 + sin(turn) * 0.16, pitch = 1.0
        let (cyw, syw, cp, sp, F) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch), W * 1.35)
        // A lemniscate of Gerono-like loops, a little depth so it reads as a tube in space.
        func point(_ f: Double) -> (Double, Double, Double) {
            let u = f * 2 * .pi, s = sin(u), k = 1 + s * s
            let x = A * cos(u) / k, y = A * s * cos(u) / k, z = sin(u) * A * 0.14 + sin(u * 2) * A * 0.04
            let y2 = y * cp - z * sp, z2 = y * sp + z * cp
            let x3 = x * cyw + z2 * syw, z3 = -x * syw + z2 * cyw
            let e = F / (F + z3)
            return (W / 2 + x3 * e, cy - y2 * e * 0.95, e)
        }
        var out = Frame()
        var (x0, y0, x1, y1) = (Double.infinity, Double.infinity, -Double.infinity, -Double.infinity)
        for i in 0...Self.segments {
            let f = Double(i) / Double(Self.segments)
            let (x, y, e) = point(f)
            out.points += [Float(x), Float(y), Float(e), Float(f)]
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        let (px, py, _) = point(pos)
        out.particles = [Float(px), Float(py), Float(pos)]
        // Scaled to the view: Loop's tube is drawn for a phone-wide figure.
        let R = 9 * Self.thickness * min(1, W / 360)
        let margin = R * 2.4
        let intensity = Self.particleLight * (searching ? 1 : 0.78 + 0.14 * sin(t * 1.2))
        let particle = 4 * (searching ? 1.15 : 1) * min(1, W / 360)
        out.settings = [R, 0.04, trail, intensity, 0, Self.glass, t, H * 0.9,
                        particle, 0, 1, 0, x0 - margin, y0 - margin, x1 + margin, y1 + margin].map(Float.init)
        return out
    }

    private func wrap(_ x: Double) -> Double { let r = x.truncatingRemainder(dividingBy: 1); return r < 0 ? r + 1 : r }
}
