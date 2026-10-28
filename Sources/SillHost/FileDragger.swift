import AppKit

/// Files dropped on the picture (RCL): once they are saved, the Mac drags them to the point where
/// they were dropped, so they land in the app under it (a Mail message, a canvas, a Finder folder)
/// as a drag from the Finder would.
///
/// No app can start a drag for another, so RCL starts its own: a tiny panel of its own under the
/// point takes a posted mouse down and begins a drag session there with the files; the panel then
/// moves away and a few posted drags end at the point, where a posted mouse up drops them. The panel
/// never activates RCL (non-activating) and takes the click without being clicked first
/// (`acceptsFirstMouse`). Main actor, under the AppKit loop (Sill.app) only; the files stay in
/// Downloads whatever happens.
@MainActor
final class FileDragger {
    private var panel: NSPanel?
    private var source: DragSourceView?
    private var finished: ((Bool) -> Void)?
    private let events = CGEventSource(stateID: .hidSystemState)

    var busy: Bool { panel != nil }

    /// Drags `urls` to `point` (CG global points, top-left origin). `done(true)` when an app took them.
    func drag(_ urls: [URL], to point: CGPoint, done: @escaping (Bool) -> Void) {
        guard !urls.isEmpty, panel == nil, let main = NSScreen.screens.first else { done(false); return }
        finished = done
        // AppKit's screens have their origin at the bottom left of the main display.
        let cocoa = NSPoint(x: point.x, y: main.frame.maxY - point.y)
        let side: CGFloat = 24
        let p = NSPanel(contentRect: NSRect(x: cocoa.x - side / 2, y: cocoa.y - side / 2, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = NSColor.white.withAlphaComponent(0.02)
        // Said outright, a nearly clear window takes clicks on all of it, not only where it draws.
        p.ignoresMouseEvents = false
        p.hasShadow = false
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = DragSourceView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.urls = urls
        view.started = { [weak self] in self?.dragStarted(to: point) }
        view.ended = { [weak self] ok in self?.end(ok) }
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
        source = view
        post(.mouseMoved, at: point)
        after(0.06) { self.post(.leftMouseDown, at: point) }
        // A drag that never began (the panel missed the click) or never ended: let go, give up.
        after(0.6) { if self.source?.didStart == false { self.post(.leftMouseUp, at: point); self.end(false) } }
        after(6) { if self.panel === p { self.post(.leftMouseUp, at: point); self.end(false) } }
    }

    /// The session is under way: the panel steps aside, the pointer wanders a little and comes back,
    /// so the app under the point sees a drag enter and move, then the drop.
    private func dragStarted(to point: CGPoint) {
        panel?.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let path: [CGFloat] = [4, 10, 16, 20, 16, 10, 6, 3, 1, 0]
        for (i, dx) in path.enumerated() {
            after(0.03 + Double(i) * 0.025) { self.post(.leftMouseDragged, at: CGPoint(x: point.x + dx, y: point.y + dx / 2)) }
        }
        after(0.03 + Double(path.count) * 0.025 + 0.18) { self.post(.leftMouseUp, at: point) }
    }

    private func end(_ ok: Bool) {
        guard let finished else { return }
        self.finished = nil
        panel?.orderOut(nil)
        panel = nil
        source = nil
        finished(ok)
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: events, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        // Never MainActor.assumeIsolated in core code (the CLI's main queue drains off the main thread).
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { Task { @MainActor in work() } }
    }
}

/// The panel's view: a mouse down begins the drag of its files.
private final class DragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var started: () -> Void = {}
    var ended: (Bool) -> Void = { _ in }
    private(set) var didStart = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !didStart else { return }
        didStart = true
        let items = urls.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            item.setDraggingFrame(NSRect(x: CGFloat(i) * 6 - 32, y: CGFloat(i) * -6 - 32, width: 64, height: 64), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
        started()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ended(!operation.isEmpty)
    }
}
