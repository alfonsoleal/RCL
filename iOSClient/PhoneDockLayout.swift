import CoreGraphics

/// A phone held upright, RCL's compact controls: the picture in a tall pane at the top, the trackpad
/// under it, and one dock of buttons at the bottom, in the thumb's reach. The keys (esc, tab, the
/// modifiers, the arrows) show only while the keyboard is up, just above it; the windows are in Apps.
/// The pane is taller than the Mac's 16:10 so the magnifier (PictureZoom's cover) has room to show
/// the Mac legibly. Rects in the stream screen's space (the screen less its top inset), as
/// PhonePortraitLayout's. Pure: CoreGraphics only.
struct PhoneDockLayout {
    static let margin: CGFloat = 8
    static let gap: CGFloat = 8
    static let dockHeight: CGFloat = 50
    /// Above the home indicator, so a swipe home never starts on a button.
    static let bottomInset: CGFloat = 22
    static let minTrackpad: CGFloat = 130
    static let capHeight: CGFloat = 44

    let size: CGSize
    let picture: CGRect
    let trackpad: CGRect
    let dock: CGRect
    /// Where an open drawer or Settings panel goes: over the picture and the trackpad, above the dock.
    let sheet: CGRect

    init(size: CGSize) {
        self.size = size
        let w = size.width - 2 * Self.margin
        dock = CGRect(x: Self.margin, y: size.height - Self.bottomInset - Self.dockHeight, width: w, height: Self.dockHeight)
        // The trackpad: a fifth of the screen (130 to 190 pt), enough for a thumb's strokes; the
        // picture takes the rest, the room the magnifier shows the Mac in.
        let pad = min(max((size.height * 0.2).rounded(.down), Self.minTrackpad), 190)
        let pictureHeight = max(dock.minY - Self.gap - pad - Self.gap, (w / 1.6).rounded(.down))
        picture = CGRect(x: Self.margin, y: 0, width: w, height: pictureHeight)
        trackpad = CGRect(x: Self.margin, y: picture.maxY + Self.gap, width: w, height: max(0, dock.minY - Self.gap - picture.maxY - Self.gap))
        sheet = CGRect(x: Self.margin, y: Self.margin, width: w, height: max(0, dock.minY - Self.gap - Self.margin))
    }

    /// One hand (RCL): the drawer and the Settings panel rise from the dock to at most two thirds
    /// of the screen, so their top (the search field, Done) stays in the thumb's reach.
    var reach: CGRect {
        let height = min(sheet.height, (size.height * 0.66).rounded(.down))
        return CGRect(x: sheet.minX, y: sheet.maxY - height, width: sheet.width, height: height)
    }

    /// `count` buttons across the dock, the gap between them.
    func buttons(_ count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let width = ((dock.width - CGFloat(count - 1) * Self.gap) / CGFloat(count)).rounded(.down)
        return (0..<count).map { CGRect(x: dock.minX + CGFloat($0) * (width + Self.gap), y: dock.minY, width: width, height: dock.height) }
    }

    /// The keys' row while the person's keyboard is up: 10 pt above it (its height `keyboard`, from
    /// PhonePortraitLayout.keyboardHeight), over the picture's foot (the magnifier keeps the pointer
    /// clear of it), never above the picture's top half.
    func keys(keyboard: CGFloat) -> CGRect {
        let y = max(picture.midY, size.height - keyboard - 10 - Self.capHeight)
        return CGRect(x: Self.margin, y: y, width: size.width - 2 * Self.margin, height: Self.capHeight)
    }
}
