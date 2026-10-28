// The auto-quality check compiles this file with Sources/StreamProtocol/HostSettings.swift as one
// module, where there is nothing to import.
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// Automatic quality (RCL): the device lowers the Mac's quality by itself when the Mac reports the
/// link can't carry it (kind 16's `link`, the same suggestion the Settings panel's button offers),
/// and brings it back a step at a time toward what the person picked once the picture has kept up
/// a while. Meant for the road: a café's Wi-Fi or a hotspot changes from minute to minute, and
/// nobody wants to open Settings mid-work.
///
/// A step up that the link can't carry within a minute doubles the wait before the next try (30 s,
/// 60, 120, up to 4 minutes), so a link that sits between two qualities doesn't flap. A still
/// window keeps up at any quality, so only seconds with a moving picture count toward a step up.
/// A pick of the person's own forgets all of it: that pick is the new quality to come back to.
/// Pure: one call a second, from the client's closed seconds.
struct AutoQuality: Equatable {
    struct Quality: Equatable {
        var bitrate: Int
        var captureScale: Double
    }

    enum Step: Equatable {
        case none
        /// Ask the Mac for this; `down` when the link couldn't carry the running quality.
        case change(Quality, down: Bool)
    }

    /// Two lowerings at least this far apart: the Mac's judge needs a few seconds at the new
    /// quality before its report means anything.
    static let downSpacing = 8.0
    /// A second counts toward a step up only with at least this many frames: a moving picture.
    static let movingFPS = 15
    static let firstUpWait = 30
    static let maxUpWait = 240
    /// A lowering this soon after a step up means the step up failed.
    static let failedUpWithin = 60.0

    /// What the person picked, to come back to; nil while nothing is lowered.
    private(set) var ceiling: Quality?
    private(set) var upWait = firstUpWait
    private(set) var movingSeconds = 0
    private var lastChangeAt = -Double.infinity
    private var lastUpAt: Double?

    /// The person picked a quality: nothing to come back to, the patience back to its first.
    mutating func picked() { self = AutoQuality() }

    /// One closed second: what the Mac runs now, its link report, and the frames that arrived.
    mutating func second(now: Double, current: Quality, link: LinkReport?, away: AwayQuality?, fps: Int) -> Step {
        if let link, link.isBehind {
            movingSeconds = 0
            // Away while a device at home is connected, the Mac keeps the home quality: no pick
            // of this device changes it.
            if let away, away.thisConnectionAway, !away.awayRunning { return .none }
            guard let bitrate = link.suggestedBitrate, now - lastChangeAt >= Self.downSpacing else { return .none }
            if ceiling == nil { ceiling = current }
            if let up = lastUpAt, now - up < Self.failedUpWithin { upWait = min(upWait * 2, Self.maxUpWait) }
            lastUpAt = nil
            lastChangeAt = now
            return .change(Quality(bitrate: bitrate, captureScale: link.suggestedCaptureScale ?? current.captureScale), down: true)
        }
        if link != nil { movingSeconds = 0; return .none }   // stalled: nothing gets through, nothing to judge
        guard let ceiling else { return .none }
        if current.bitrate >= ceiling.bitrate, current.captureScale >= ceiling.captureScale {
            self.ceiling = nil   // back where the person left it
            return .none
        }
        if fps >= Self.movingFPS { movingSeconds += 1 }
        guard movingSeconds >= upWait, now - lastChangeAt >= Double(upWait) else { return .none }
        movingSeconds = 0
        lastChangeAt = now
        lastUpAt = now
        return .change(Self.stepUp(from: current, toward: ceiling), down: false)
    }

    /// One step toward `ceiling`: the next preset's bitrate first (never past the ceiling's), the
    /// resolution last, once the bitrate is back, since it multiplies what every frame weighs.
    static func stepUp(from current: Quality, toward ceiling: Quality) -> Quality {
        if current.bitrate < ceiling.bitrate {
            let next = QualityPreset.allCases.map(\.rawValue).sorted().first { $0 > current.bitrate } ?? ceiling.bitrate
            return Quality(bitrate: min(next, ceiling.bitrate), captureScale: current.captureScale)
        }
        return Quality(bitrate: current.bitrate, captureScale: ceiling.captureScale)
    }
}
