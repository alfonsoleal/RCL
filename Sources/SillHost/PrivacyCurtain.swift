import AppKit

/// Private Mode (RCL): the Mac's own screens black, with one line saying why, while a device works
/// on them; the device still sees everything. A borderless window over each physical screen, above
/// the menu bar and the Dock, that takes no click or key (they reach the apps under it, as the
/// device's own do) and never streams: a Desktop stream leaves RCL's windows out (the coordinator's
/// filter), and a window stream is that window alone.
///
/// Not quite opaque (99.7 % black), on purpose: the window server stops drawing a window it finds
/// wholly covered by an opaque one, and a window stream would then freeze on the device, as it does
/// behind another window on the Mac. RCL's virtual display gets no curtain (nobody looks at it, and
/// a staged window is drawn there). The Mac's pointer still moves over the black: macOS draws it above
/// every window. Main actor, under the AppKit loop (Sill.app); the CLI has none and says so.
@MainActor
final class PrivacyCurtain {
    private var windows: [NSWindow] = []
    private var observer: NSObjectProtocol?
    private(set) var isUp = false
    /// The display RCL made (VirtualStage), never curtained.
    var virtualDisplayID: () -> CGDirectDisplayID? = { nil }
    /// The person at the Mac pressed Esc three times on its own keyboard: the curtain is theirs to lift,
    /// since a paired device could otherwise work on the Mac unseen with no way to stop it from there.
    var liftedHere: () -> Void = {}
    private var keyMonitor: Any?
    private var escapes: [TimeInterval] = []

    func set(_ up: Bool) {
        guard up != isUp else { return }
        isUp = up
        if up {
            place()
            watchEscape()
            // A display plugged in or out, a resolution changed: the curtain follows.
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.isUp == true { self?.place() } }
            }
        } else {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            escapes = []
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            windows.forEach { $0.orderOut(nil) }
            windows = []
        }
    }

    /// Esc three times within 2 s, from a keyboard at the Mac: an event a device sent through RCL
    /// carries RCL's own process as its source, a key on the Mac's keyboard none (Accessibility, which
    /// RCL has, lets it watch keys meant for other apps).
    private func watchEscape() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, Int32(event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0) != getpid() else { return }
            Task { @MainActor in
                guard let self, self.isUp else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.escapes = self.escapes.filter { now - $0 < 2 } + [now]
                if self.escapes.count >= 3 { self.escapes = []; self.liftedHere() }
            }
        }
    }

    private func place() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let skip = virtualDisplayID()
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            if let id, id == skip { continue }
            windows.append(curtain(for: screen))
        }
    }

    private func curtain(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.isReleasedWhenClosed = false
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.997)
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "This Mac is being used from another device. Press Esc three times to show the screens.")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor(white: 0.45, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -48),
        ])
        w.contentView = view
        w.orderFrontRegardless()
        return w
    }
}
