import CoreGraphics

/// The picture's zoom on this device (#65, #146): how far it is magnified and where, in the stream
/// view's own points. The picture view (HEVCDisplayView) is drawn through `transform`, and the input
/// view (InputOverlayView) maps a touch through `rect(_:in:)`, so a tap lands on what is under the
/// finger at any zoom. Nothing goes to the Mac: its window keeps its size and only this device sees
/// it larger. Pure: CoreGraphics only, checked in Tests/checks/picture-zoom.
struct PictureZoom: Equatable {
    /// 1 is the picture as the layout fits it; at most `maxScale`.
    private(set) var scale: CGFloat = 1
    /// Where the magnified picture's centre sits from the view's centre, in view points.
    private(set) var offset: CGPoint = .zero

    static let maxScale: CGFloat = 5
    /// A pinch that ends below this goes back to 1: a near miss of the whole picture is the whole
    /// picture.
    static let snapBack: CGFloat = 1.08

    var isZoomed: Bool { scale > 1.0001 }

    /// The transform for the picture view, about its centre (UIView's anchor): scaled, then moved.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
    }

    /// `rect` (in a view of `size`) as it shows at this zoom: where the video really is on screen.
    func rect(_ rect: CGRect, in size: CGSize) -> CGRect {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGRect(x: c.x + offset.x + (rect.minX - c.x) * scale,
                      y: c.y + offset.y + (rect.minY - c.y) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// A pinch's step: from `scale` to `scale * factor`, keeping what is under `focus` (view points)
    /// under it, as a map does.
    mutating func pinch(by factor: CGFloat, at focus: CGPoint, in size: CGSize) {
        let new = min(max(scale * factor, 1), Self.maxScale)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let k = new / scale
        offset = CGPoint(x: (focus.x - c.x) - k * (focus.x - c.x - offset.x),
                         y: (focus.y - c.y) - k * (focus.y - c.y - offset.y))
        scale = new
        clamp(size)
    }

    /// Two fingers, or the pointer at an edge, move the magnified picture by `delta` view points.
    mutating func pan(by delta: CGPoint, in size: CGSize) {
        offset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
        clamp(size)
    }

    /// The pinch ended: below `snapBack`, the whole picture again.
    mutating func settle() {
        if scale < Self.snapBack { self = PictureZoom() }
    }

    /// The magnified picture always covers the view: it never slides off and shows black beside it.
    private mutating func clamp(_ size: CGSize) {
        let mx = (scale - 1) * size.width / 2, my = (scale - 1) * size.height / 2
        offset = CGPoint(x: min(max(offset.x, -mx), mx), y: min(max(offset.y, -my), my))
    }

    // MARK: The magnifier (RCL's compact controls on a phone)

    /// The picture (`video`, where the layout fits it in a view of `size`) magnified until it fills the
    /// view's height or width, whichever it falls short of, centred. 1 when it already fills both.
    mutating func cover(video: CGRect, in size: CGSize) {
        guard video.width > 0, video.height > 0 else { self = PictureZoom(); return }
        scale = min(max(size.width / video.width, size.height / video.height, 1), Self.maxScale)
        offset = .zero
        clamp(video: video, in: size)
    }

    /// The magnifier at a chosen level (`scale` times the picture as the layout fits it), about the
    /// view's centre, then kept on the picture as `cover` keeps it.
    mutating func magnify(to level: CGFloat, video: CGRect, in size: CGSize) {
        let new = min(max(level, 1), Self.maxScale)
        offset = CGPoint(x: offset.x * new / scale, y: offset.y * new / scale)
        scale = new
        clamp(video: video, in: size)
    }

    /// Keeps `point` (where it is on the unmagnified picture, view points) at least `margin` of the
    /// view from its sides, moving the magnified picture as little as that takes.
    mutating func follow(_ point: CGPoint, video: CGRect, in size: CGSize, margin: CGFloat) {
        let at = rect(CGRect(origin: point, size: .zero), in: size).origin
        var d = CGPoint.zero
        if at.x < margin { d.x = margin - at.x } else if at.x > size.width - margin { d.x = size.width - margin - at.x }
        if at.y < margin { d.y = margin - at.y } else if at.y > size.height - margin { d.y = size.height - margin - at.y }
        guard d != .zero else { return }
        offset = CGPoint(x: offset.x + d.x, y: offset.y + d.y)
        clamp(video: video, in: size)
    }

    /// The magnified picture covers the view where it is larger than it, and stays centred where it
    /// is not: no black beside it that the picture could fill.
    mutating func clamp(video: CGRect, in size: CGSize) {
        let r = rect(video, in: size)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if r.width >= size.width {
            if r.minX > 0 { dx = -r.minX } else if r.maxX < size.width { dx = size.width - r.maxX }
        } else { dx = size.width / 2 - r.midX }
        if r.height >= size.height {
            if r.minY > 0 { dy = -r.minY } else if r.maxY < size.height { dy = size.height - r.maxY }
        } else { dy = size.height / 2 - r.midY }
        offset = CGPoint(x: offset.x + dx, y: offset.y + dy)
    }

    /// The pointer resting within `edge` points of a side moves the picture that way by `step`, so a
    /// trackpad or a mouse can reach all of it: the pointer cannot leave the screen to drag it.
    static func edgePan(at point: CGPoint, in size: CGSize, edge: CGFloat = 28, step: CGFloat = 14) -> CGPoint {
        var d = CGPoint.zero
        if point.x < edge { d.x = step } else if point.x > size.width - edge { d.x = -step }
        if point.y < edge { d.y = step } else if point.y > size.height - edge { d.y = -step }
        return d
    }
}
