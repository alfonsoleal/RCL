import SwiftUI
import Combine
import StreamProtocol

// MARK: - Palette

extension Color {
    /// 0xRRGGBB, the way the design boards write colours.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Palette {
    static let bar = Color(hex: 0x18181A)          // top bar and drawer background: Agencia 85's carbón
    static let control = Color(hex: 0x27272A)      // bar buttons, search field, selected row
    static let controlOpen = Color(hex: 0x123A22)  // a bar button whose thing is showing: the accent's dark tint
    static let accent = Color(hex: 0x00D749)  // Agencia 85's green, the one accent
    static let text = Color(hex: 0xF4F4F5)
    static let barLabel = Color(hex: 0xD4D4D8)     // the 11pt labels under the bar icons
    static let muted = Color(hex: 0xA1A1AA)        // section headers, window counts, placeholder
    static let panel = Color(hex: 0x1F1F22)        // the stream panel behind the video
    static let trackpad = Color(hex: 0x111113)     // the portrait trackpad's well
    static let thumbBody = Color(hex: 0x27272A)    // thumbnail placeholder
    static let thumbTitleBar = Color(hex: 0x3F3F46)
    static let iconFallback = Color(hex: 0x3F3F46) // two-letter app badge
}

// MARK: - Layout selection

/// Which layout a screen gets, decided from its size in points alone: no device check, no idiom,
/// so an iPad at an odd split size and an iPhone each get the layout their dimensions deserve (only
/// the arrangement `.outerPortrait` draws depends on the device; below). The numbers are written
/// for the iPhone Duo (first guessed at 1000×710 and 500×710; the real sizes, from the iOS 27.1
/// simulator, are these, the stream screen's: docs/iphone-duo-plan.md):
///
/// * inner display sideways, open flat or half-folded (the book pose) — 951×669 → `.innerLandscape`
///   (top bar over the stream)
/// * inner display upright, open flat or half-folded (the laptop pose) — 669×951 → `.innerPortrait`
///   (stream over controls)
/// * the cover on its side — 594×466 (678×466 less the camera's strip) → `.outerLandscape`
/// * the cover upright — 382×678 (466×678 less that strip) → `.outerPortrait`
///
/// The outer display is not a different app: it is the same two layouts at compact sizes, because
/// the posture only changed how much room there is, not what the screen is for. The thresholds sit
/// between those sizes with room to spare — 600 separates the cover's 382 pt width from the inner
/// 669, and 560 the cover's 466 pt height from the inner 669. Where the fold runs across the inner
/// display, and whether it is in the way, is the device's word (iOS 27.1, DuoPosture), not the size's.
///
/// The same sizes catch the phones: every iPhone held upright (375–440 pt wide, 320 with Display
/// Zoom) is `.outerPortrait` and on its side `.outerLandscape`, and so is an iPad window narrower
/// than 600 pt held upright (Slide Over, a narrow Split View). On an iPhone `.outerPortrait` draws
/// the phone's arrangement (Noah, 2026-09-27: the picture in a fixed 16:10 pane on top, then the
/// Keyboard button's row, the thumbnails, six keys and the trackpad; `PhonePortraitLayout`), the
/// Duo's outer display included: it has a phone's shape and the same keyboard over its key row. An
/// iPad keeps the compact halves in such a window, as before: the approval covered iPhones and left
/// the iPad as it was (`phoneArrangement`, the one place the layout reads the idiom). To give the
/// Duo's outer display back the halves, draw `.compact` from 480 pt wide (phones are at most 440;
/// docs/iphone-portrait-plan.md, Detection).
enum DuoLayout {
    case innerLandscape, innerPortrait, outerPortrait, outerLandscape

    /// Narrower than this and taller than wide: the outer display held upright.
    static let outerMaxWidth: CGFloat = 600
    /// Shorter than this and wider than tall: the outer display on its side.
    static let outerMaxHeight: CGFloat = 560

    static func of(_ size: CGSize) -> DuoLayout {
        if size.height > size.width, size.width < outerMaxWidth { return .outerPortrait }
        if size.width > size.height, size.height < outerMaxHeight { return .outerLandscape }
        return size.width > size.height ? .innerLandscape : .innerPortrait
    }

    /// The laptop layout, inner or outer: stream on top, the key row and the trackpad below. Only
    /// there does the device draw its own pointer, for the trackpad (PointerPresence).
    var isPortrait: Bool { self == .innerPortrait || self == .outerPortrait }

    /// Whether `.outerPortrait` draws the phone's arrangement: on an iPhone, yes; on an iPad (a
    /// window narrower than 600 pt held upright), no: the compact halves, as before. DEBUG:
    /// `-SillIdiom pad` (or `phone`) draws the other device's, so the harness can photograph an
    /// iPad window's on an iPhone simulator (ContentView's contract).
    static var phoneArrangement: Bool {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "SillIdiom") {
        case "pad"?: return false
        case "phone"?: return true
        default: break
        }
        #endif
        return UIDevice.current.userInterfaceIdiom == .phone
    }

    /// Whether a screen of this size draws the phone's arrangement.
    static func drawsPhone(_ size: CGSize) -> Bool { of(size) == .outerPortrait && phoneArrangement }
}

// MARK: - Screen

struct StreamScreen: View {
    @ObservedObject var client: StreamClient
    @State private var drawerOpen = false
    @State private var keyboardShown = false
    /// Modifiers held down by the portrait key row until the next key, character or click uses
    /// them. Lives up here so rotating the iPad does not drop a half-typed shortcut.
    @State private var latched: KeyModifiers = []
    /// The bar's Keyboard button drives the overlay's first responder through this.
    @State private var overlay = InputOverlayProxy()
    /// The Aa control's text scale, device points per Mac point; nil means the Mac window has never
    /// been asked to fit (the control shows 1× for it). Up here, like `latched`, so it survives
    /// rotation and both layouts share it.
    @State private var textScale: Double? = nil
    /// The Aa slider is unfolded (finger down): the bars fade their other buttons meanwhile.
    @State private var scaleOpen = false
    /// The thumbnail whose traffic-light submenu is open (held for half a second). The bars clip their
    /// content, so the submenu is drawn by this root, anchored to the thumbnail's frame.
    @State private var windowMenu: UInt32? = nil
    /// The Settings panel (the Mac's streaming settings) is open. Up here, next to the drawer, so a
    /// rotation keeps it open and it re-anchors in the other layout.
    @State private var settingsOpen = false
    /// The keyboard was up (the overlay first responder) when the panel opened: closing the panel
    /// puts it back.
    @State private var keyboardBeforeSettings = false
    /// The Menus pull-down closed the Settings panel, which had taken the keyboard down: it comes
    /// back when the pull-down goes (`menusClosed`).
    @State private var keyboardAfterMenus = false
    /// The Menus pull-down is open: it takes the arrows and Return itself, so a hardware keyboard's
    /// hold lets go meanwhile (`keyboardTakers`).
    @State private var menusOpen = false
    /// Pair This iPad… (the panel's Away from home group): the pairing overlay covers the stream.
    /// Up here, like the panel, so a rotation keeps it. An outside rcl://pair link shows the same
    /// overlay with its confirmation.
    @State private var pairingOverlay = false
    /// The DEBUG harness's stand-in for the camera (the simulator has none); nil on a device.
    private var scannerOverride: CodeScanner.Mode? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The stream panel's size in points, reported by whichever layout is showing.
    @State private var panelSize: CGSize = .zero
    /// The viewport send waiting out its debounce, if any.
    @State private var pendingViewport: Task<Void, Never>? = nil
    /// The line over the stream while the link cannot carry the quality (docs/remote-bundle-plan.md
    /// §6.7; AwayCopy's LinkLine), and its next look (the linger's end).
    @State private var linkLine = LinkLine()
    @State private var linkLineCheck: Task<Void, Never>? = nil

    // The first-run tour (TourPolicy, TourOverlay; docs/first-run-walkthrough-plan.md). One stream
    // screen is one session. What the session decided is `client.tourSession`, which outlives the
    // screen: the automatic reconnect's session goes on with it (TourPolicy.nextSession).
    /// The tour on screen, if any. While it shows the layouts take no touch and the keyboard is down.
    @State private var tour: TourRun? = nil
    /// Where the tour's targets are, as the layout on screen reports them.
    @State private var tourTargets: [TourTarget: CGRect] = [:]
    /// This session's first picture (the Mac's name, a frame size, a source), systemUptime.
    @State private var pictureAt: Double? = nil
    /// The layout on screen (nil until the screen has a size), and when it began.
    @State private var tourLayout: TourLayout? = nil
    @State private var layoutAt: Double = ProcessInfo.processInfo.systemUptime
    /// The decision waiting out its beat.
    @State private var tourWait: Task<Void, Never>? = nil
    /// Every touch on the screen, taken by none.
    @State private var touches = TouchWatch()
    @State private var tourStore = TourStore()
    /// The keyboard comes back when the tour ends: it was up when the tour came, or when the
    /// Settings panel that started it opened.
    @State private var tourKeyboardAfter = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// The Duo's hinge (iOS 27.1, DuoPostureReader): with the fold, the book and laptop poses.
    @Environment(\.duoEnvironment) private var duoEnvironment
    /// This device's Larger Picture switch (the Settings panel's This iPhone; docs/larger-picture-plan.md).
    /// It acts only while a window streams (`largerPictureNow`).
    @AppStorage(StreamClient.largerPictureKey) private var largerPicture = false
    /// Larger Picture as it was in effect when the Settings panel opened (`largerPictureNow`), which
    /// the arrangement keeps until the panel closes; nil while it is closed. The panel hangs under row
    /// 1, which the arrangement moves by the picture's growth (157 pt on an 18 Pro Max), so a change
    /// applied at once would move the panel under the finger: the switch flipped there, or what
    /// streams changing meanwhile (a window closed on the Mac, another device's pick). It applies as
    /// the panel goes, in the same motion.
    @State private var largerPictureHeld: Bool? = nil
    /// This device's Hide the Bar switch (the Settings panel's This iPad): sideways, the picture takes
    /// the bar's place, and the bar comes down over it from the handle at the top (`barRevealed`).
    @AppStorage(StreamClient.hideBarKey) private var hideBar = false
    /// The Pill (FloatingPill.swift): sideways, a floating capsule and the window switcher instead of the bar.
    @AppStorage(PillBar.key) private var pillBar = false
    @AppStorage(PillBar.cornerKey) private var pillCorner = PillBar.Corner.topTrailing.rawValue
    @Namespace private var pillSpace
    /// RCL's compact controls on a phone upright (PhoneDockLayout); on unless turned off.
    @AppStorage(StreamClient.compactControlsKey) private var compactControls = true
    @AppStorage(BarItems.slimKey) private var slimBar = false
    @AppStorage(StreamClient.matchScreenKey) private var matchScreen = false
    @AppStorage(StreamClient.wideColorKey) private var wideColor = false
    @AppStorage(BarItems.hiddenKey) private var barHiddenRaw = ""
    /// Apps, Menus and Settings, the person's shown buttons, and More when some are tucked away.
    private var barButtonCount: Int {
        let hidden = BarItems.hidden(barHiddenRaw)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let shown = BarItems.Item.allCases.filter { !hidden.contains($0) && (pad || ($0 != .shortcuts && $0 != .magnifier)) }
        return 4 + shown.count + (hidden.isEmpty ? 0 : 1)   // and the status pill, about a button wide
    }
    /// The magnifier (InputOverlayView.followPointer): on by default on an iPhone, off on an iPad (SillApp).
    @AppStorage(StreamClient.magnifierKey) private var magnifier = false
    @AppStorage(StreamClient.magnifierLevelKey) private var magnifierLevel = 0.0
    /// With Hide the Bar on, the bar is down over the picture: pulled from the handle, until it has
    /// been left alone a while (`hideBarLater`) or swiped back up.
    @State private var barRevealed = false
    @State private var barHideTask: Task<Void, Never>? = nil
    /// The pointer left the pulled-down bar (RCL): it goes back up half a second later unless the
    /// pointer comes back or something hangs from it.
    @State private var barLeaveTask: Task<Void, Never>? = nil
    /// Picture Only (#145): the picture alone fills the screen in any orientation, with the handle
    /// at the top to come back. For this session only: the next one starts with the usual layout.
    @State private var pictureOnly = false
    #if DEBUG
    /// The console says once when a decision starts to wait.
    @State private var tourWaitLogged: Double? = nil
    /// `-SillTourPress skip@S` skips once.
    @State private var tourSkipPressed = false
    #endif

    #if DEBUG
    /// DEBUG only, for the layout harness: start on a given state so a posture can be photographed
    /// with the drawer already open. `StreamScreen(client:)` still means exactly what it did.
    init(client: StreamClient, drawerOpen: Bool = false, keyboardShown: Bool = false,
         scaleOpen: Bool = false, textScale: Double? = nil, settingsOpen: Bool = false,
         pairingOverlay: Bool = false, scannerOverride: CodeScanner.Mode? = nil) {
        self.client = client
        _drawerOpen = State(initialValue: drawerOpen)
        _keyboardShown = State(initialValue: keyboardShown)
        _scaleOpen = State(initialValue: scaleOpen)
        _textScale = State(initialValue: textScale)
        _settingsOpen = State(initialValue: settingsOpen)
        // The panel open over the keyboard, as in a session: it took the keyboard down, and closing
        // it puts it back (`-SillSettings 1 -SillKeyboard 1`).
        _keyboardBeforeSettings = State(initialValue: settingsOpen && keyboardShown)
        // And it holds the Larger Picture it opened with, as `setSettings` does.
        _largerPictureHeld = State(initialValue: settingsOpen
            ? PhonePortraitLayout.largerPicture(switchOn: UserDefaults.standard.bool(forKey: StreamClient.largerPictureKey),
                                                streaming: .init(client.active))
            : nil)
        _pairingOverlay = State(initialValue: pairingOverlay)
        self.scannerOverride = scannerOverride
    }
    #endif

    var body: some View {
        // Which layout, and at which size — see `DuoLayout` for the thresholds and the Duo posture
        // behind each one.
        GeometryReader { geo in
            let duo = DuoLayout.of(geo.size)
            let layout: TourLayout = duo == .innerLandscape || duo == .outerLandscape ? .landscape
                : (DuoLayout.drawsPhone(geo.size) ? .phone : .portrait)
            // The fold across this screen, in its own space (iOS 27.1 on the Duo; else as before).
            let posture = DuoPosture.read(geo, duoEnvironment)
            // Larger Picture on a phone held upright: the software keyboard its rows are kept above;
            // none with the switch off, while the Desktop or nothing streams (`largerPictureNow`),
            // sideways, on an iPad, on the iPhone Duo (a hinge), and where the picture would be no
            // larger (Display Zoom at 320 pt wide). While the Settings panel is open, Larger Picture
            // as it was in effect when it opened (`largerPictureHeld`). The arrangement, its viewport
            // (PortraitStreamScreen's picture) and the tour's targets and words all follow from this.
            let largerKeyboard = layout == .phone
                ? PhonePortraitLayout.keyboard(for: geo.size, largerPicture: largerPictureHeld ?? largerPictureNow,
                                               foldable: posture.hinge != .unknown) : nil
            // The Settings panel's switch: on an iPhone without a hinge whose picture Larger Picture
            // makes larger, judged on this screen held upright, whichever way it is held now.
            let offersLarger = DuoLayout.phoneArrangement && posture.hinge == .unknown
                && PhonePortraitLayout.offersLargerPicture(screen: geo.size)
            ZStack {
                Group {
                    if pictureOnly, tour == nil {
                        pictureOnlyView
                    } else {
                    switch duo {
                    case .innerLandscape:
                        landscape(bar: slimBar && UIDevice.current.userInterfaceIdiom == .pad ? .slim : .regular,
                                  width: geo.size.width, fold: posture.info(in: geo.size))
                    case .outerLandscape:
                        landscape(bar: .compact, width: geo.size.width, fold: posture.info(in: geo.size))
                    case .innerPortrait:
                        portrait(metrics: .regular)
                    case .outerPortrait:
                        portrait(metrics: DuoLayout.phoneArrangement ? .phone : .compact,
                                 largerKeyboard: compactControls && DuoLayout.phoneArrangement ? nil : largerKeyboard,
                                 dock: compactControls && DuoLayout.phoneArrangement)
                    }
                    }
                }
                // Under the pairing overlay and the tour nothing takes a touch: not the bar, and
                // not the stream's UIKit input view (nor, so, the Pencil, a hover or a key).
                .allowsHitTesting(!overlayShown && tour == nil)
                // The pointer sprite follows the layout: the trackpad's arrow shows only in the
                // laptop layout, and a rotation re-renders it at once; the Mac's arrow stays.
                .onChange(of: DuoLayout.of(geo.size).isPortrait, initial: true) { _, portrait in
                    client.setPointerLayout(portrait: portrait)
                }
                // The clipboard's chip on screen or not: its 20 s run only while it is, and VoiceOver
                // is told when it first shows (ClipboardPolicy.chipCounts).
                .onChange(of: clipboardChipOnScreen, initial: true) { _, onScreen in
                    client.clipboardChipShown(onScreen)
                }
                // Every notice in one place (RCL): the clipboard's chip (docs/clipboard-plan.md), the
                // files chip, a screenshot's outcome and the Mac's lock screen, stacked in the stream
                // panel's top-trailing corner, newest concerns last. A sibling after the layouts, so
                // their buttons take touches over the stream's UIKit input view and nothing else does;
                // never while something is open over the stream (the lock card always: it is how in).
                if let panel = tourTargets[.stream], noticesShown {
                    VStack(alignment: .trailing, spacing: 8) {
                        if clipboardChipAllowed, client.clipboardChip || client.clipboardNote != nil {
                            ClipboardChip(client: client)
                        }
                        if clipboardChipAllowed, !client.fileTransfers.isEmpty {
                            FilesChip(client: client).frame(maxWidth: 440)
                        }
                        if let note = client.screenshotNote {
                            Label(note, systemImage: "camera")
                                .font(.geist(.subheadline, .medium))
                                .foregroundStyle(Palette.text)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .rclGlass(in: Capsule(), tint: 0.7)
                        }
                        if client.macLocked, client.offersMacPassword { MacLockedCard(client: client) }
                    }
                    .frame(maxWidth: max(0, panel.width - 16), alignment: .trailing)
                    .padding(.top, shownLinkLine != nil ? 52 : 8).padding(.trailing, 8)
                    .frame(width: panel.width, height: panel.height, alignment: .topTrailing)
                    .position(x: panel.midX, y: panel.midY)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: client.screenshotNote)
                    .animation(.easeOut(duration: 0.2), value: client.macLocked)
                }
                // The tour: a sibling above the layouts, as the pairing overlay is, and under it: an
                // outside link puts the tour aside until the overlay has closed.
                if let run = tour, !overlayShown {
                    // With Larger Picture no thumbnails: the bar card is about Apps, and the cards
                    // upright stand in the picture's whole room, the black under a short picture.
                    TourOverlay(run: run, copy: tourCopy(run, layout, keysOnItsSide: posture.onInnerDisplay,
                                                         thumbnails: largerKeyboard == nil),
                                layout: layout, targets: tourTargets,
                                thumbnails: largerKeyboard == nil,
                                room: largerKeyboard.map { PhonePortraitLayout(size: geo.size, keyboard: $0).picture },
                                screen: geo.size, bottomInset: geo.safeAreaInsets.bottom,
                                next: tourNext, skip: tourSkip)
                        .transition(.opacity)
                }
                // A sibling in the same stack, not an `.overlay`: over the stream's UIKit input
                // view, only a sibling drawn after it received the touches (measured on the
                // simulator: an overlay's buttons were drawn but never tapped).
                if overlayShown {
                    PairingOverlay(client: client, scannerMode: scannerOverride ?? CodeScanner.currentMode,
                                   close: { withAnimation(.easeOut(duration: 0.2)) { pairingOverlay = false } })
                }
            }
            .coordinateSpace(.named(TourSpace.name))
            .onPreferenceChange(TourTargetsKey.self) { tourTargets = $0 }
            .onChange(of: layout, initial: true) { _, now in layoutChanged(to: now) }
            // A thumbnail's lights hang from the strip, which Larger Picture's arrangement has none
            // of: when the arrangement changes under them (what streams changed, or a turn), they
            // close rather than wait, unseen, to come back with the strip.
            .onChange(of: largerKeyboard != nil) { _, _ in
                #if DEBUG
                if windowMenu != nil { print("lights: closed, the phone's arrangement changed under them") }
                #endif
                closeWindowMenu()
            }
            .background(TouchWatcher(watch: touches))
            // The layouts and the overlays share this screen's space, and so its fold; the inner
            // display gives the picture the status bar's strip in every pose.
            .duoFold(posture, size: geo.size, screen: String(localized: "stream screen"))
            .duoStatusBar(posture, size: geo.size)
            .environment(\.largerPictureOffered, offersLarger)
            #if DEBUG
            // The console's line for the gates: what Larger Picture's rule made of the switch and of
            // what streams, on a phone held upright, each time one of them or the outcome changes.
            .onChange(of: layout == .phone ? largerPictureLine(largerKeyboard) : "", initial: true) { _, line in
                if !line.isEmpty { print(line) }
            }
            #endif
        }
        .background(Color.black)
        .overlayPreferenceValue(WindowMenuAnchorKey.self) { anchor in
            if let anchor, let id = windowMenu, let window = client.windows.first(where: { $0.id == id }) {
                WindowLightsMenu(anchor: anchor, window: window,
                                 command: { action in client.command(action, window: id); closeWindowMenu() },
                                 beside: besideOffer(for: id),
                                 toggleBeside: { client.setBeside(client.beside == id ? nil : id); closeWindowMenu() },
                                 quit: (client.hostAppCommands ?? 0) >= AppCommand.generation
                                     ? { client.appCommand("quit", bundleID: window.bundleID); closeWindowMenu() } : nil,
                                 dismiss: closeWindowMenu,
                                 alwaysBelow: DuoLayout.drawsPhone)
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: windowMenu)
        .onChange(of: client.pendingLink) { _, link in
            // An outside link while streaming: the panel and the keyboard go first, as for Pair This iPad….
            if link != nil { openLinkOverlay() }
        }
        .onChange(of: scenePhase) { _, phase in
            // A gesture cut short by a scene change never ends: put the transient UI away.
            if phase != .active { scaleOpen = false; windowMenu = nil }
        }
        // One thing open at a time: the Aa ruler and a thumbnail's traffic lights put the Settings
        // panel away. (Opening the panel closes them, the drawer and the keyboard.)
        .onChange(of: scaleOpen) { _, open in if open { setSettings(false) } }
        .onChange(of: windowMenu) { _, menu in if menu != nil { setSettings(false) } }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            // The picture follows the input view's zoom (#65): one picture view, whichever layout.
            overlay.onZoom = { [weak client] transform in client?.pictureZoom.apply(transform) }
            // The magnifier follows the pointer, whichever layout's input view is on screen.
            client.onPointerFollow = { [weak overlay] p in overlay?.view?.follow(to: p) }
            // A fresh connection starts on the Desktop (the client asks for it as soon as the host
            // reports nothing streaming), so the drawer stays closed until the user opens it.
            sendViewport()
            // A link that came in before this connection did waits here now.
            if client.pendingLink != nil { openLinkOverlay() }
            #if DEBUG
            runLaunchArguments()
            #endif
        }
        .onChange(of: client.active) { _, source in
            if source != .none { withAnimation(.easeOut(duration: 0.18)) { drawerOpen = false } }
            // The host sizes a window as it selects it, from the last viewport it has; this repeat
            // is for a host that restarted, or a window that was picked from the Mac's side.
            sendViewport()
        }
        .onChange(of: client.connected) { _, up in
            if up { sendViewport() }
        }
        // A hardware keyboard (docs/hardware-keyboard-plan.md §2): the input view takes the keyboard by
        // itself while one is attached and nothing open takes it, never as the person's own.
        .onReceive(HardwareKeyboardMonitor.shared.$attached) { overlay.update(attached: $0) }
        .onChange(of: keyboardTakers, initial: true) { _, takers in overlay.update(takers: takers) }
        // Rotation animates, and a Mac window resize restarts the stream, so let the size settle.
        .onChange(of: panelSize) { _, _ in sendViewport(after: 0.25) }
        // Same wait for Aa: cycling from Off to 0.8× passes three sizes nobody wants the Mac to try.
        .onChange(of: textScale) { _, _ in sendViewport(after: 0.25) }
        // The stream rate follows the panel (`StreamClient.wantedFPS`): re-send when Low Power Mode
        // toggles or the screen's mode changes. Both notifications can arrive off the main thread.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            sendViewport(after: 0.25)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.modeDidChangeNotification).receive(on: RunLoop.main)) { _ in
            sendViewport(after: 0.25)
        }
        // Away from home the stream rate follows the route (60 fps through a VPN or the internet): a
        // session that stops being away (the move home) asks for its full rate whatever path it took
        // (docs/remote-bundle-plan.md §7.3).
        .onChange(of: client.remoteRoute) { _, _ in sendViewport() }
        // The link's line over the stream (§6.7): a report arriving or clearing, or the panel, the
        // drawer or the pairing overlay opening or closing over it.
        .onChange(of: linkReportLine, initial: true) { _, _ in updateLinkLine() }
        .onChange(of: linkLineAllowed) { _, _ in updateLinkLine() }
        .onChange(of: matchScreen) { _, _ in sendViewport() }
        .onChange(of: wideColor) { _, _ in sendViewport() }
        // The zoom settles: with Match the Screen, the Mac's capture follows it, in half steps, once
        // the pinch or the magnifier has rested 0.6 s (each change restarts the stream).
        .onReceive(client.pictureZoom.$scale.map(Self.zoomBucket).removeDuplicates()
                    .debounce(for: .seconds(0.6), scheduler: RunLoop.main).dropFirst()) { _ in
            if matchScreen { sendViewport() }
        }
        // The tour: the first picture starts its beat; an outside link puts it aside and back.
        .onChange(of: pictureReady, initial: true) { _, ready in if ready { pictureCame() } }
        // The bar's own controls used, by a tap or by VoiceOver, Switch Control, Voice Control or
        // Full Keyboard Access (none of which makes a touch): something happening, for its rule.
        .onChange(of: drawerOpen) { _, _ in client.noteAction() }
        .onChange(of: settingsOpen) { _, _ in client.noteAction() }
        .onChange(of: keyboardShown) { _, _ in client.noteAction() }
        .onChange(of: scaleOpen) { _, _ in client.noteAction() }
        .onChange(of: textScale) { _, _ in client.noteAction() }
        .onChange(of: tourCard, initial: true) { _, card in tourCardChanged(card) }
        .onChange(of: tourVoiceOver) { _, _ in carryTour(reason: "VoiceOver") }
        // The session is over: a decision still waiting out its beat must not land in the next
        // session's `client.tourSession`.
        .onDisappear {
            tourWait?.cancel()
            tourWait = nil
        }
    }

    // MARK: The link's line

    /// What the Mac's report says for the line now: nil while the link keeps up.
    private var linkReportLine: String? {
        let host = client.settings.host
        return AwayCopy.streamLine(link: host?.link, away: host?.away, mac: client.macName.isEmpty ? String(localized: "the Mac") : client.macName)
    }

    /// Nothing open over the stream: the Settings panel (which has the callout), the drawer, the
    /// pairing overlay, the first-run tour (its dim and card; VoiceOver is on its card meanwhile).
    private var linkLineAllowed: Bool { !settingsOpen && !drawerOpen && !overlayShown && !tourOnScreen }

    /// The clipboard's chip shows where the link's line may, and not over a thumbnail's lights or the
    /// Aa ruler either (the Settings panel has its own Paste).
    /// Whether the corner's notices show at all: one of them has something to say.
    private var noticesShown: Bool {
        (client.macLocked && client.offersMacPassword) || client.screenshotNote != nil
            || (clipboardChipAllowed && (client.clipboardChip || client.clipboardNote != nil || !client.fileTransfers.isEmpty))
    }

    private var clipboardChipAllowed: Bool { linkLineAllowed && windowMenu == nil && !scaleOpen }

    /// The chip itself on screen, not its note in its place: its time runs only then.
    private var clipboardChipOnScreen: Bool {
        clipboardChipAllowed && client.clipboardChip && client.clipboardNote == nil && tourTargets[.stream] != nil
    }

    /// Runs LinkLine on the report and what is open, says the line once a spell, and looks again at
    /// the linger's end.
    private func updateLinkLine() {
        if let words = linkLine.update(report: linkReportLine, allowed: linkLineAllowed, now: ProcessInfo.processInfo.systemUptime) {
            AccessibilityNotification.Announcement(words).post()
            #if DEBUG
            print("link: the stream's line “\(words)” (announced)")
            #endif
        }
        linkLineCheck?.cancel()
        linkLineCheck = nil
        guard let at = linkLine.recheckAt else { return }
        linkLineCheck = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0.01, at - ProcessInfo.processInfo.systemUptime)))
            if !Task.isCancelled { updateLinkLine() }
        }
    }

    /// The line as it shows over the stream now, or nil.
    private var shownLinkLine: String? { linkLine.visible ? linkLine.text : nil }

    // MARK: Viewport

    /// Tells the host the panel size and text scale, now or after `delay` seconds. A newer call
    /// replaces a pending one, so a burst of changes sends only the last. Nothing goes out until the
    /// panel has been measured, or while disconnected.
    private func sendViewport(after delay: Double = 0) {
        pendingViewport?.cancel()
        pendingViewport = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            guard client.connected, panelSize.width > 0, panelSize.height > 0 else { return }
            let fps = StreamClient.wantedFPS(remote: client.awayCapsFrameRate)
            #if DEBUG
            print("viewport: \(Self.points(panelSize.width))×\(Self.points(panelSize.height)) pt, scale "
                  + (textScale.map { TextScaleControl.label($0) } ?? "none") + String(localized: ", \(fps) fps"))
            #endif
            // Match the Screen: the panel in this device's pixels, so the Mac sends no more than it shows.
            // Zoomed in, it shows more of each pixel of the Mac's: ask for that many more, so the
            // magnified picture is sharp (the Mac never captures above its own Retina or Standard).
            let px = UIScreen.main.scale * Self.zoomBucket(client.pictureZoom.scale)
            client.sendViewport(Viewport(width: Double(panelSize.width),
                                         height: Double(panelSize.height),
                                         scale: textScale,
                                         fps: fps,
                                         pixelWidth: matchScreen ? Int((panelSize.width * px).rounded()) : nil,
                                         pixelHeight: matchScreen ? Int((panelSize.height * px).rounded()) : nil,
                                         wideColor: wideColor ? true : nil))
        }
    }

    /// The zoom in half steps, 1 to 3: what Match the Screen multiplies the panel's pixels by.
    nonisolated static func zoomBucket(_ scale: CGFloat) -> CGFloat {
        min(max((scale * 2).rounded() / 2, 1), 3)
    }

    #if DEBUG
    /// A length for the console: whole points as whole numbers (within a hundredth: a scaled harness
    /// screen measures 693.99…), anything else to a tenth.
    private static func points(_ value: CGFloat) -> String {
        abs(value - value.rounded()) < 0.01 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
    }

    /// `larger picture: the switch on, the Desktop streams: the standard arrangement`, or `…, a window
    /// streams: Larger Picture above a 301 pt keyboard`, with `(held … while Settings is open)` while
    /// the panel holds it; nothing while the switch is off and nothing is held (the other gates'
    /// consoles stay as they were).
    private func largerPictureLine(_ keyboard: CGFloat?) -> String {
        guard largerPicture || largerPictureHeld != nil || keyboard != nil else { return "" }
        let streaming: String
        switch client.active {
        case .none: streaming = String(localized: "nothing streams")
        case .desktop: streaming = String(localized: "the Desktop streams")
        case .window: streaming = String(localized: "a window streams")
        }
        var line = String(localized: "larger picture: the switch ") + (largerPicture ? "on" : "off") + ", " + streaming + ": "
        line += keyboard.map { String(localized: "Larger Picture above a \(Self.points($0)) pt keyboard") } ?? String(localized: "the standard arrangement")
        if let held = largerPictureHeld { line += String(localized: " (held ") + (held ? "on" : "off") + String(localized: " while Settings is open)") }
        return line
    }

    /// The harness's arguments that act once the stream screen shows (ContentView's contract), once
    /// per launch. `-SillKeyboard 1` brings the software keyboard up for real in a live session (the
    /// mock only lights the button, from its init); `-SillKeyboardToggle <s>[,<s>…]` toggles it at
    /// those seconds as the Keyboard button does, a stand-in for a tap. In a live session (the
    /// normal app with `-SillConnect`, or `-SillLive 1`) `-SillDrawer 1`, `-SillSettings 1` and
    /// `-SillScaleOpen 1` (with `-SillScale`) open theirs 1.5 s in, once the Desktop has started
    /// (`-SillSettingsCloseAt <s>` closes the panel again s seconds in):
    /// its start closes a drawer opened before it, and the normal app has no harness to pass them
    /// in at the start.
    private func runLaunchArguments() {
        guard !Self.launchArgumentsRan else { return }
        Self.launchArgumentsRan = true
        let defaults = UserDefaults.standard
        let live = !client.mockDiscovery
        func after(_ seconds: Double, _ step: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: step)
        }
        if defaults.bool(forKey: "SillKeyboard"), live {
            after(0.5) {
                print("keyboard: -SillKeyboard 1, the input view takes first responder")
                overlay.setKeyboard(shown: true)
            }
        }
        let times = (defaults.string(forKey: "SillKeyboardToggle") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }.filter { $0 >= 0 }
        for time in times {
            after(time) {
                print("keyboard: toggled at \(Self.points(CGFloat(time))) s, as the Keyboard button does (it was "
                      + (keyboardShown ? "up" : "down") + ")")
                setSettings(false, restoreKeyboard: false)
                overlay.toggleKeyboard()
            }
        }
        // `-SillTurnAt <s>[,<s>…]`: at each second the scene is asked for the other orientation (upright
        // or sideways, from the screen's shape then), a turn mid-session with no hand on the simulator
        // (an iPhone's; iPadOS's windowing refuses it, and says so).
        let turns = (defaults.string(forKey: "SillTurnAt") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }.filter { $0 >= 0 }
        for time in turns {
            after(time) {
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    let bounds = scene.keyWindow?.bounds ?? .zero
                    let mask: UIInterfaceOrientationMask = bounds.width > bounds.height ? .portrait : .landscapeRight
                    print("turn: at \(Self.points(CGFloat(time))) s, asking for " + (mask == .portrait ? "portrait" : "landscape"))
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                        print("turn: refused: \(error.localizedDescription)")
                    }
                }
            }
        }
        // `-SillAXDump <s>`: s seconds in, the screen's accessibility elements in the order the
        // accessibility tree hands them out (VoiceOver's order, without VoiceOver), labels and frames.
        let dump = defaults.double(forKey: "SillAXDump")
        if dump > 0 { after(dump) { Self.accessibilityDump() } }
        // `-SillPictureOnly 1`: Picture Only a second in, as the panel's row does.
        if defaults.bool(forKey: "SillPictureOnly") { after(1) { print("harness: Picture Only"); enterPictureOnly() } }
        // `-SillZoom <scale>`: the picture zoomed that much about its centre five seconds in (after the first frame, whose size resets a zoom), as a pinch.
        let zoomTo = defaults.double(forKey: "SillZoom")
        if zoomTo > 1 { after(5) { print("harness: zoomed to \(zoomTo)×"); overlay.view?.zoomForHarness(CGFloat(zoomTo)) } }
        // `-SillBarRevealAt <s>[,<s>…]`: with Hide the Bar on, the bar pulled down at those seconds, as
        // the handle does; it goes back up by itself after 4 s with no touch.
        let reveals = (defaults.string(forKey: "SillBarRevealAt") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }.filter { $0 >= 0 }
        for time in reveals {
            after(time) {
                print("harness: the bar pulled down at \(Self.points(CGFloat(time))) s")
                revealBar()
            }
        }
        // `-SillLargerPictureToggle <s>[,<s>…]`: Larger Picture switched at those seconds, as the
        // Settings panel's switch does (saved; without `-Sill.largerPicture`, which would hold it).
        let toggles = (defaults.string(forKey: "SillLargerPictureToggle") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }.filter { $0 >= 0 }
        for time in toggles {
            after(time) {
                largerPicture.toggle()
                print("harness: Larger Picture switched " + (largerPicture ? "on" : "off") + " at " + Self.points(CGFloat(time)) + " s"
                      + (largerPictureHeld != nil ? String(localized: "; the Settings panel is open, so it applies when the panel closes") : ""))
            }
        }
        guard live else { return }
        if defaults.bool(forKey: "SillDrawer") {
            after(1.5) { print("harness: the drawer opened"); withAnimation(.easeOut(duration: 0.18)) { drawerOpen = true } }
        }
        if defaults.bool(forKey: "SillSettings") {
            after(1.5) { print("harness: the Settings panel opened"); setSettings(true) }
            // `-SillSettingsCloseAt <s>`: closed again s seconds in, as Done does (the clipboard's chip
            // waiting under it, then showing: docs/clipboard-plan.md).
            let closeAt = defaults.double(forKey: "SillSettingsCloseAt")
            if closeAt > 1.5 { after(closeAt) { print("harness: the Settings panel closed"); setSettings(false) } }
        }
        if defaults.bool(forKey: "SillScaleOpen") {
            after(1.5) {
                let scale = defaults.double(forKey: "SillScale")
                if scale > 0 { textScale = scale }
                print("harness: the Aa ruler opened")
                scaleOpen = true
            }
        }
    }
    private static var launchArgumentsRan = false

    /// `-SillAXDump`: walks the key window as an assistive technology does (an element, else its
    /// `accessibilityElements`, else its element count, else its subviews) and prints one line per
    /// element: "ax: 1 Apps (14,454 76×50)".
    private static func accessibilityDump() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            print("ax: no key window"); return
        }
        var lines: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, _ depth: Int) {
            guard depth < 60, seen.count < 5000, let element = object as? NSObject, !element.accessibilityElementsHidden,
                  seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.isAccessibilityElement {
                let f = element.accessibilityFrame
                let label = element.accessibilityLabel ?? element.accessibilityValue ?? String(localized: "(no label)")
                lines.append(String(localized: "\(label) (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"))
                return
            }
            if let children = element.accessibilityElements, !children.isEmpty {
                children.forEach { visit($0, depth + 1) }
                return
            }
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                (0..<count).forEach { if let child = element.accessibilityElement(at: $0) { visit(child, depth + 1) } }
                return
            }
            if let view = element as? UIView {
                view.subviews.filter { !$0.isHidden && $0.alpha > 0 }.forEach { visit($0, depth + 1) }
            }
        }
        visit(window, 0)
        for (i, line) in lines.enumerated() { print("ax: \(i + 1) \(line)") }
    }
    #endif

    private func closeWindowMenu() { windowMenu = nil }

    /// Side by side's button in a window's menu: none from a Mac that cannot, while the Desktop or
    /// nothing streams, or for the window streaming itself.
    private func besideOffer(for id: UInt32) -> BesideOffer? {
        guard (client.hostSideBySide ?? 0) >= 1, case .window(let active) = client.active, active != id else { return nil }
        return client.beside == id ? .remove : .add
    }

    /// Pair This iPad…, or an outside link waiting for its confirmation.
    private var overlayShown: Bool { pairingOverlay || client.pendingLink != nil }

    /// What is open over the stream that takes the keyboard for itself or must keep keys from the Mac
    /// (HardwareKeyboardPolicy.Taker): while any is, a hardware keyboard's hold lets go, and it comes
    /// back when the last closes.
    private var keyboardTakers: Set<HardwareKeyboardPolicy.Taker> {
        var takers: Set<HardwareKeyboardPolicy.Taker> = []
        if settingsOpen { takers.insert(.settings) }
        if overlayShown { takers.insert(.pairing) }
        if tour != nil { takers.insert(.tour) }
        if drawerOpen { takers.insert(.drawer) }
        if menusOpen { takers.insert(.menus) }
        return takers
    }

    /// Pair This iPad…: the panel and the keyboard are put away first, so no key reaches the Mac
    /// while the code is typed, then the overlay covers the stream. What an earlier pairing left
    /// (a "Paired with…" whose fade never ran, an error) goes first: the overlay would show it,
    /// and a stale "Paired" closed it after a second.
    private func openPairingOverlay() {
        putAwayForOverlay()
        client.cancelPairing()
        withAnimation(.easeOut(duration: 0.2)) { pairingOverlay = true }
    }

    /// An outside link to confirm over the stream. The overlay is held open, not shown only while
    /// the link waits: Pair clears the link, and the overlay went with it, before "Pairing with…",
    /// any error or "Paired with…" could show. A pairing still running is left alone; one that
    /// ended earlier leaves nothing behind.
    private func openLinkOverlay() {
        putAwayForOverlay()
        if !pairingOverlay {
            switch client.pairing {
            case .working, .idle: break
            case .failed, .paired: client.pairing = .idle
            }
        }
        withAnimation(.easeOut(duration: 0.2)) { pairingOverlay = true }
    }

    private func putAwayForOverlay() {
        setSettings(false, restoreKeyboard: false)
        withAnimation(.easeOut(duration: 0.18)) { drawerOpen = false }
        windowMenu = nil
        scaleOpen = false
        overlay.setKeyboard(shown: false)
    }

    /// Larger Picture in effect now (PhonePortraitLayout's rule): the switch, while a window streams.
    /// The Desktop, which Aa never resizes, and nothing streaming keep the standard arrangement.
    private var largerPictureNow: Bool {
        PhonePortraitLayout.largerPicture(switchOn: largerPicture, streaming: .init(client.active))
    }

    /// Opens or closes the Settings panel. Opening puts the drawer, the traffic lights and the Aa
    /// ruler away and takes the keyboard down: with the overlay not first responder no hardware
    /// key reaches the Mac, and Esc (or ⌘.) reaches the panel's Done instead. Closing (Done, a tap
    /// outside, the Settings button, Esc, the VoiceOver escape gesture) puts the keyboard back if
    /// the panel took it down; the Apps and Keyboard buttons close it with `restoreKeyboard: false`
    /// because they decide about the keyboard themselves. While it is open the arrangement keeps the
    /// Larger Picture it opened with (`largerPictureHeld`); a change of the switch, or of what
    /// streams, applies as it closes.
    private func setSettings(_ open: Bool, restoreKeyboard: Bool = true) {
        guard open != settingsOpen else { return }
        if open {
            withAnimation(.easeOut(duration: 0.18)) { drawerOpen = false }
            windowMenu = nil
            scaleOpen = false
            keyboardBeforeSettings = keyboardShown
            overlay.setKeyboard(shown: false)
        }
        let motion: Animation = open && !reduceMotion ? .spring(duration: 0.25, bounce: 0.15) : .easeOut(duration: 0.18)
        withAnimation(motion) {
            settingsOpen = open
            // Larger Picture keeps the arrangement the panel opened with while it is open, so the
            // panel never moves under the finger: a change of the switch, or of what streams,
            // applies as the panel goes.
            largerPictureHeld = open ? largerPictureNow : nil
        }
        if !open {
            if restoreKeyboard, keyboardBeforeSettings { overlay.setKeyboard(shown: true) }
            keyboardBeforeSettings = false
        }
    }

    /// The Menus pull-down opened: the drawer, a thumbnail's lights and the Settings panel go, one
    /// thing open at a time; the keyboard stays as it is (the plan's §7.5). The panel had taken it
    /// down, so it comes back, but only when the pull-down goes: raised now, the software keyboard
    /// would come up, and key focus move, under the open menu.
    private func menusOpened() {
        keyboardAfterMenus = settingsOpen && keyboardBeforeSettings
        #if DEBUG
        if settingsOpen { print("menus: the pull-down opened over the Settings panel, which closes; the keyboard " + (keyboardAfterMenus ? "comes back when the pull-down goes" : "was down before it")) }
        #endif
        setSettings(false, restoreKeyboard: false)
        windowMenu = nil
        withAnimation(.easeOut(duration: 0.18)) { drawerOpen = false }
        menusOpen = true
    }

    private func menusClosed() {
        #if DEBUG
        if keyboardAfterMenus { print("menus: the pull-down went; the keyboard back up, as before the Settings panel") }
        #endif
        if keyboardAfterMenus { overlay.setKeyboard(shown: true) }
        keyboardAfterMenus = false
        menusOpen = false
    }

    // MARK: The tour

    /// The picture, as the tour counts it: the Mac's first window list, a frame size and a source
    /// that streams. A Mac that refuses this device, or cannot capture, never gets here.
    private var pictureReady: Bool {
        !client.macName.isEmpty && client.videoSize != .zero && client.active != .none
    }

    /// The tour is on screen (not put aside under the pairing overlay).
    private var tourOnScreen: Bool { tour != nil && !overlayShown }

    /// Whether the session a piece of the tour's delayed work began in (`client.connectedAt` then) is
    /// still the one on screen. A stream screen that has gone keeps its last state, and work it left
    /// waiting would act on it (a DEBUG stand-in pressed a card's Next after its session ended), and
    /// now write the next session's `client.tourSession`.
    private func sameSession(_ mark: Date?) -> Bool { client.connected && client.connectedAt == mark }
    /// The card on screen, if any.
    private var tourCard: TourTopic? { tourOnScreen ? tour?.at : nil }

    private var tourVoiceOver: Bool {
        #if DEBUG
        if TourDebug.current.voiceOver { return true }
        #endif
        return voiceOverEnabled
    }

    /// What is open at the decision, if anything (the rule's `busy`), in the console's words.
    private var tourBusy: String? {
        if drawerOpen { return String(localized: "the Apps list was open") }
        if settingsOpen { return String(localized: "Settings was open") }
        if windowMenu != nil { return String(localized: "a window's lights were open") }
        if scaleOpen { return String(localized: "the Aa ruler was open") }
        // The person's own keyboard: a hardware keyboard's hold is not theirs, so a person with a
        // keyboard attached still gets the tour (HardwareKeyboardPolicy).
        if keyboardShown { return String(localized: "the keyboard was up") }
        if overlayShown { return String(localized: "the pairing overlay was open") }
        // UIKit's word, not the scene phase: in a headless simulator the environment's scenePhase
        // stays inactive for an app that is active and on screen.
        if UIApplication.shared.applicationState != .active { return String(localized: "the app was not active") }
        return nil
    }

    /// `keysOnItsSide`: the iPhone Duo open, whose keys and trackpad come with the device on its side.
    /// `thumbnails`: false for a phone with Larger Picture.
    private func tourCopy(_ run: TourRun, _ layout: TourLayout, keysOnItsSide: Bool = false, thumbnails: Bool = true) -> TourCopy {
        TourPolicy.copy(run.at, layout, mac: client.macName, device: StreamClient.deviceWord,
                        voiceOver: tourVoiceOver, firstOfRun: run.firstOfRun, keysOnItsSide: keysOnItsSide,
                        thumbnails: thumbnails)
    }

    private func tourLog(_ line: @autoclosure () -> String) {
        #if DEBUG
        print("tour: " + line())
        #endif
    }

    /// The first picture: once per session. Its decision comes a beat later.
    private func pictureCame() {
        guard pictureAt == nil else { return }
        pictureAt = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        let debug = TourDebug.current
        let mark = client.connectedAt
        if let step = debug.start {
            // A turn later, once the screen has said which layout it is.
            Task { @MainActor in
                guard sameSession(mark) else { return }
                startTour(TourPolicy.replay(tourLayout ?? .landscape, voiceOver: tourVoiceOver, from: step))
            }
        }
        if let s = debug.activityAt, !TourDebug.touchedOnce {
            TourDebug.touchedOnce = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(s))
                guard sameSession(mark) else { return }
                touches.lastTouchAt = ProcessInfo.processInfo.systemUptime
                tourLog(String(localized: "a stand-in touch \(s) s after the picture"))
                considerTour()
            }
        }
        if let s = debug.takeTourAt {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(s))
                guard sameSession(mark) else { return }
                tourLog(String(localized: "a stand-in for Settings, then Take the Tour"))
                setSettings(true)
                try? await Task.sleep(for: .seconds(1))
                guard sameSession(mark) else { return }
                takeTour()
            }
        }
        #endif
        considerTour()
    }

    /// Portrait or landscape changed (a rotation, a resize, the Duo folding), or the screen came.
    /// A turn after the picture's decision gets one of its own; a run on screen follows the layout.
    private func layoutChanged(to layout: TourLayout) {
        let changed = tourLayout != nil && layout != tourLayout
        tourLayout = layout
        if changed {
            layoutAt = ProcessInfo.processInfo.systemUptime
            carryTour(reason: String(localized: "a turn"))
        }
        considerTour()
    }

    /// The run on screen as the layout (or VoiceOver) now has it; it ends, nothing more saved,
    /// when nothing of it is left here.
    private func carryTour(reason: String) {
        guard let run = tour, let layout = tourLayout else { return }
        guard let carried = TourPolicy.carry(run, to: layout, voiceOver: tourVoiceOver, memory: tourStore.memory) else {
            tourLog(String(localized: "ended by \(reason): nothing of it here (\(layout.rawValue))"))
            endTour()
            return
        }
        // Shown in this layout now: a later turn back into it offers nothing again this session.
        client.tourSession.offered.insert(layout)
        guard carried != run else { return }
        tourLog(String(localized: "carried to \(carried.at.rawValue) (\(carried.index + 1) of \(carried.count), \(layout.rawValue))"))
        tour = carried
    }

    /// The automatic tour's rule (TourPolicy.automatic), asked at the picture, at a layout change
    /// and when a wait runs out. One decision per session and layout.
    private func considerTour() {
        tourWait?.cancel()
        tourWait = nil
        guard tour == nil, let layout = tourLayout else { return }
        // The compact controls have no strip or key row for the phone's cards to point at: no tour
        // by itself there (Take the Tour still shows it).
        if layout == .phone, compactControls, DuoLayout.phoneArrangement { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A touch anywhere, input sent to the Mac, or a control used by any means. VoiceOver's
        // swipes that only move its focus are reading, as a look around the screen is, and are not
        // counted; VoiceOver also moves its focus by itself as a screen or a layout comes.
        let activity = [touches.lastTouchAt, client.lastInputAt, client.lastActionAt].compactMap { $0 }.max()
        let session = client.tourSession
        let moment = TourMoment(now: now, pictureAt: pictureAt, layoutAt: layoutAt, decided: session.decided,
                                lastActivityAt: activity, touchesDown: touches.down, busy: tourBusy != nil,
                                offered: session.offered.contains(layout), voiceOver: tourVoiceOver,
                                enabled: tourStore.automatic)
        switch TourPolicy.automatic(moment, layout, tourStore.memory) {
        case .wait(let until):
            guard let until else { return }
            #if DEBUG
            if tourWaitLogged != until {
                tourWaitLogged = until
                let owed = TourPolicy.owed(layout, voiceOver: tourVoiceOver, tourStore.memory)
                tourLog(String(localized: "owed here: \(Self.names(owed.map(\.rawValue))) (\(layout.rawValue); seen: \(Self.names(tourStore.memory.names)))"))
                tourLog(String(localized: "waiting until 1.0 s after the \(session.decided && layoutAt > (pictureAt ?? 0) ? "turn" : "picture")"))
            }
            #endif
            let mark = client.connectedAt
            tourWait = Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0.01, until - ProcessInfo.processInfo.systemUptime)))
                if !Task.isCancelled, sameSession(mark) { considerTour() }
            }
        case .pass(let reason):
            // A pass before the picture (the tour off) or once decided changes nothing.
            guard pictureAt != nil, moment.enabled, !moment.offered else { return }
            let since = session.decided && layoutAt > (pictureAt ?? 0) ? String(localized: "the turn") : String(localized: "the picture")
            client.tourSession.offered.insert(layout)
            client.tourSession.decided = true
            switch reason {
            case .nothingOwed:
                tourLog(String(localized: "nothing owed here (\(layout.rawValue); seen: \(Self.names(tourStore.memory.names))\(tourStore.memory.skipped ? "; skipped" : ""))"))
            case .used:
                tourLog(String(localized: "not this session: used within a second of \(since)"))
            case .busy:
                tourLog(String(localized: "not this session: \(touches.down > 0 ? "a touch was down" : tourBusy ?? "something was open")"))
            }
        case .show(let steps):
            startTour(TourPolicy.run(owed: steps))
        }
    }

    private static func names(_ list: [String]) -> String {
        list.isEmpty ? "none" : list.joined(separator: ", ")
    }

    /// Starts a run: what could be open goes away (as for the pairing overlay), the keyboard goes
    /// down, and so hardware keys stop reaching the Mac. `keyboardAfter` is whether it comes back at
    /// the end (Take the Tour: whether it was up before Settings opened).
    private func startTour(_ run: TourRun?, keyboardAfter: Bool? = nil) {
        guard let run else { return }
        tourWait?.cancel()
        tourWait = nil
        if let layout = tourLayout { client.tourSession.offered.insert(layout) }
        client.tourSession.decided = true
        client.tourSession.running = true
        let keyboard = keyboardAfter ?? keyboardShown
        putAwayForOverlay()
        tourKeyboardAfter = keyboard
        withAnimation(.easeOut(duration: 0.25)) { tour = run }
    }

    /// Next, or Done on the last card: the step is saved as passed.
    private func tourNext() {
        guard let run = tour else { return }
        tourStore.save(TourPolicy.passed(run.at, tourStore.memory))
        tourLog(String(localized: "passed \(run.at.rawValue)"))
        if let next = TourPolicy.next(run) {
            let motion: Animation = reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.1)
            withAnimation(motion) { tour = next }
        } else {
            tourLog(String(localized: "done (saved: \(Self.names(tourStore.memory.names))\(tourStore.writes ? "" : "; this run only"))"))
            endTour()
        }
    }

    /// Skip (Esc, VoiceOver's escape gesture): the automatic tour is off for good on this device;
    /// in Take the Tour it only closes the run (TourPolicy.skip).
    private func tourSkip() {
        guard let run = tour else { return }
        let memory = TourPolicy.skip(run, tourStore.memory)
        if memory != tourStore.memory { tourStore.save(memory) }
        tourLog(run.replay ? String(localized: "closed (Take the Tour; nothing more saved)") : String(localized: "skipped (saved\(tourStore.writes ? "" : "; this run only"))"))
        endTour()
    }

    /// The run ends: Done, Skip, or a turn with nothing of it left. Put aside under the pairing
    /// overlay (an outside link), it ends there too, and the keyboard stays down under that
    /// overlay, as the overlay leaves it at its own close.
    private func endTour() {
        let onScreen = tourOnScreen
        withAnimation(.easeOut(duration: 0.2)) { tour = nil }
        client.tourSession.running = false
        if tourKeyboardAfter && !overlayShown { overlay.setKeyboard(shown: true) }
        tourKeyboardAfter = false
        // VoiceOver reads the stream screen afresh (not from under the pairing overlay).
        if onScreen { AccessibilityNotification.ScreenChanged().post() }
    }

    /// Settings › Take the Tour: the panel closes without putting the keyboard back (the tour does,
    /// at its end, if it was up before the panel opened), then every step of the layout on screen.
    private func takeTour() {
        let keyboard = keyboardBeforeSettings
        setSettings(false, restoreKeyboard: false)
        tourLog(String(localized: "Take the Tour"))
        let mark = client.connectedAt
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.18))      // the panel's close
            guard sameSession(mark) else { return }         // the session ended meanwhile
            startTour(TourPolicy.replay(tourLayout ?? .landscape, voiceOver: tourVoiceOver), keyboardAfter: keyboard)
        }
    }

    /// A card came on screen (the tour's first, the next, or the same one back from under the
    /// pairing overlay), or the tour went or was put aside under that overlay.
    private func tourCardChanged(_ card: TourTopic?) {
        // Nothing reaches the Mac as input while a card shows (StreamClient.inputPaused).
        client.inputPaused = card != nil
        guard let run = tour else { return }
        if card != nil {
            let since = pictureAt.map { String(format: String(localized: ", %.2f s after the picture"), ProcessInfo.processInfo.systemUptime - $0) } ?? ""
            tourLog(String(localized: "showing \(run.at.rawValue) (\(run.index + 1) of \(run.count))\(since)"))
            tourPressLater(run)
        } else {
            tourLog(String(localized: "put aside for the pairing overlay, at \(run.at.rawValue)"))
        }
    }

    /// DEBUG `-SillTourPress`: presses a card's Next (or Skip, once) a while after it appears.
    private func tourPressLater(_ run: TourRun) {
        #if DEBUG
        guard let press = TourDebug.current.press else { return }
        let seconds: Double
        let skip: Bool
        switch press {
        case .next(let s): seconds = s; skip = false
        case .skip(let s): seconds = s; skip = !tourSkipPressed
        }
        if skip { tourSkipPressed = true }
        let mark = client.connectedAt
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard sameSession(mark), tour?.at == run.at, tourOnScreen else { return }
            tourLog(String(localized: "a stand-in presses \(skip ? "Skip" : run.isLast ? "Done" : "Next")"))
            if skip { tourSkip() } else { tourNext() }
        }
        #endif
    }

    /// Grows from the Settings button's corner, the way a popover would; a plain fade under Reduce
    /// Motion. `anchor` is the panel's top-trailing corner as a point of the view the transition is
    /// attached to. In landscape that view is the content area, whose corner is within a few
    /// points of the panel's; in portrait it is the whole screen, where `.topTrailing` would make
    /// the panel slide down over the window bar (PortraitStreamScreen passes its own).
    private func settingsTransition(anchor: UnitPoint = .topTrailing) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94, anchor: anchor).combined(with: .opacity)
    }

    private func landscape(bar plain: BarMetrics, width: CGFloat, fold: FoldInfo) -> some View {
        // The book pose (docs/iphone-duo-plan.md, (a)): nothing on the fold's band; elsewhere as before.
        let (bar, stripWidth) = plain.clearing(fold, width: width)
        let topBar = TopBar(client: client, metrics: bar, stripWidth: stripWidth, drawerOpen: $drawerOpen,
                   keyboardShown: $keyboardShown,
                   textScale: $textScale, scaleOpen: $scaleOpen, windowMenu: $windowMenu,
                   settingsOpen: settingsOpen,
                   // Apps, Menus, Aa, Keyboard, Desktop, Settings, and the strip.
                   menusFit: MacMenuButton.fits(width: width - 2 * bar.padding, buttons: barButtonCount, buttonWidth: bar.buttonWidth,
                                                gap: bar.gap, thumbWidth: bar.thumbWidth),
                   toggleKeyboard: { overlay.toggleKeyboard() },
                   setSettings: { setSettings($0, restoreKeyboard: $1) },
                   menusOpened: menusOpened, menusClosed: menusClosed)
        let pillTop = TopBar(client: client, metrics: .pill, drawerOpen: $drawerOpen,
                             keyboardShown: $keyboardShown,
                             textScale: $textScale, scaleOpen: $scaleOpen, windowMenu: $windowMenu,
                             settingsOpen: settingsOpen, menusFit: true,
                             toggleKeyboard: { overlay.toggleKeyboard() },
                             setSettings: { setSettings($0, restoreKeyboard: $1) },
                             menusOpened: menusOpened, menusClosed: menusClosed, pill: true, pillSpace: pillSpace,
                             topInset: PillBar.corner(pillCorner).notch ? PillBar.notchInset : 0)
        let corner = PillBar.corner(pillCorner)
        return Group {
            if pillBar {
                // The Pill: the picture keeps the whole screen; the pill widens into the bar in its corner,
                // and the panels hang just under it (or from the top, when it sits at the bottom).
                ZStack(alignment: .top) {
                    contentArea(bar: bar, panelsTop: corner.notch ? 54 + PillBar.notchInset : corner.top ? 68 : 14)
                    PillPlacement(draggable: !barShown) {
                        if barShown {
                            pillTop
                                .onContinuousHover { phase in
                                    if case .ended = phase { hideBarAfterPointerLeft() } else { barLeaveTask?.cancel() }
                                }
                                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                                // The glass grows from the narrow pill's frame (`pillMorph`); the buttons fade in.
                                .transition(.opacity)
                        } else {
                            FloatingPill(client: client, space: pillSpace, expand: revealBar)
                                .transition(.opacity)
                        }
                    }
                    if !barShown, !corner.notch { BarHandle(reveal: revealBar) }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.84), value: barShown)
                // A swipe from the top edge stays the pill's, not iPadOS's, on its first try.
                .defersSystemGestures(on: .top)
                #if DEBUG
                // Harness: `-SillPillOpen 1` widens the pill 1 s in.
                .task {
                    guard UserDefaults.standard.bool(forKey: "SillPillOpen") else { return }
                    try? await Task.sleep(for: .seconds(1))
                    revealBar()
                }
                #endif
            } else if hideBar {
                // The picture takes the whole screen and the bar comes down over it, so showing the
                // bar never changes the picture's size: no new viewport, no Mac window refitted.
                ZStack(alignment: .top) {
                    contentArea(bar: bar, panelsTop: barShown ? bar.height : 0)
                    if barShown {
                        topBar
                            .onContinuousHover { phase in
                                if case .ended = phase { hideBarAfterPointerLeft() } else { barLeaveTask?.cancel() }
                            }
                            .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                                let t = drag.translation
                                if t.height < -24, abs(t.height) > abs(t.width) { hideBarNow() }
                            })
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        BarHandle(reveal: revealBar)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: barShown)
            } else {
                VStack(spacing: 0) {
                    topBar
                    contentArea(bar: bar)
                }
            }
        }
    }

    /// Picture Only: the stream panel across the whole screen and the handle that ends it. The
    /// panel reports its size as any layout's does, so the Mac fits a window to it (Aa set, or the
    /// virtual display) and the Desktop scales to it.
    private var pictureOnlyView: some View {
        ZStack(alignment: .top) {
            contentArea(bar: .regular)
            BarHandle(reveal: leavePictureOnly, onHover: false)
        }
    }

    private func enterPictureOnly() {
        setSettings(false, restoreKeyboard: false)
        drawerOpen = false
        withAnimation(.easeOut(duration: 0.2)) { pictureOnly = true }
    }

    private func leavePictureOnly() {
        withAnimation(.easeOut(duration: 0.2)) { pictureOnly = false }
    }

    /// The bar shows sideways: always, unless Hide the Bar is on; then while pulled down, and while
    /// something that hangs from it or points at it is open (the drawer, Settings, the Aa ruler, a
    /// thumbnail's lights, Menus, the tour).
    private var barShown: Bool {
        !(hideBar || pillBar) || barRevealed || drawerOpen || settingsOpen || scaleOpen || windowMenu != nil || menusOpen || client.filesSheetOpen || tour != nil
    }

    private func revealBar() {
        barRevealed = true
        hideBarLater()
    }

    /// Only once the pointer is back over the Mac's picture (InputOverlayView.pictureHoverAt) for a
    /// moment: a pointer that left the bar for a menu, a sheet or a context menu hanging from it is
    /// over those, and the bar stays (the 4 s rule still takes it up later).
    private func hideBarAfterPointerLeft() {
        barLeaveTask?.cancel()
        let left = ProcessInfo.processInfo.systemUptime
        barLeaveTask = Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, barRevealed else { return }
                let busy = drawerOpen || settingsOpen || scaleOpen || windowMenu != nil || menusOpen || client.filesSheetOpen || tour != nil
                guard !busy else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if InputOverlayView.pictureHoverAt > left, now - left >= 0.5 {
                    barHideTask?.cancel()
                    withAnimation(.easeOut(duration: 0.2)) { barRevealed = false }
                    return
                }
            }
        }
    }

    private func hideBarNow() {
        barHideTask?.cancel()
        if drawerOpen { drawerOpen = false }
        if settingsOpen { setSettings(false) }
        barRevealed = false
    }

    /// The pulled-down bar goes back up once nothing hangs from it and no finger, pointer click or
    /// Pencil has touched the screen for 4 s (TouchWatch), so it never leaves mid-scroll of the strip.
    private func hideBarLater() {
        barHideTask?.cancel()
        // The pointer's hover and the harness bring it down with no touch: the 4 s count from then.
        let revealedAt = ProcessInfo.processInfo.systemUptime
        barHideTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard barRevealed else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let idle = touches.down == 0 && now - max(revealedAt, touches.lastTouchAt ?? 0) >= 4
                let busy = drawerOpen || settingsOpen || scaleOpen || windowMenu != nil || menusOpen || client.filesSheetOpen || tour != nil
                if idle, !busy {
                    #if DEBUG
                    print("bar: back up, nothing open and no touch for 4 s")
                    #endif
                    withAnimation(.easeOut(duration: 0.2)) { barRevealed = false }
                    return
                }
            }
        }
    }

    /// `largerKeyboard`: Larger Picture's keyboard on a phone (see `body`), nil otherwise.
    private func portrait(metrics: PortraitMetrics, largerKeyboard: CGFloat? = nil, dock: Bool = false) -> some View {
        PortraitStreamScreen(client: client, metrics: metrics, drawerOpen: $drawerOpen,
                             keyboardShown: $keyboardShown,
                             textScale: $textScale, scaleOpen: $scaleOpen, windowMenu: $windowMenu,
                             latched: $latched, overlay: overlay,
                             settingsOpen: settingsOpen,
                             setSettings: { setSettings($0, restoreKeyboard: $1) },
                             menusOpened: menusOpened, menusClosed: menusClosed,
                             settingsTransition: { settingsTransition(anchor: $0) },
                             onPanelSize: { panelSize = $0 },
                             pairThisDevice: openPairingOverlay,
                             linkLine: shownLinkLine,
                             takeTour: takeTour,
                             pictureOnly: enterPictureOnly,
                             largerKeyboard: largerKeyboard,
                             dock: dock)
    }

    private var streamShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    /// `panelsTop`: with Hide the Bar, the height of the bar over the picture, which the drawer and
    /// the Settings panel hang below.
    private func contentArea(bar: BarMetrics, panelsTop: CGFloat = 0) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black

            ZStack {
                ZoomedStreamView(client: client, zoom: client.pictureZoom)
                // Same frame as the video, so a touch maps straight onto the streamed frame.
                InputOverlay(videoSize: client.videoSize,
                             send: { client.sendInput($0) },
                             setOwnPointer: { client.setOwnPointer($0, from: $1) },
                             proxy: overlay,
                             isKeyboardShown: $keyboardShown,
                             latchedModifiers: latched,
                             onModifiersConsumed: { latched = [] },
                             sendGesture: { client.sendGesture($0, fingers: $1) },
                         dropFiles: { client.dropFiles($0, at: $1) },
                         sendMotion: { client.sendMotion($0) },
                         followPointer: magnifier,
                         magnifierLevel: CGFloat(magnifierLevel),
                         onMagnifierLevel: { magnifierLevel = Double(($0 * 4).rounded() / 4) })
            }
            .background(Palette.panel)
            .overlay(alignment: .top) { LinkLineView(text: shownLinkLine) }
            .clipShape(streamShape)
            .overlay(streamShape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            // The panel itself, inside the padding: the size the host fits the Mac window to.
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { panelSize = $0 })
            .tourTarget(.stream)
            .padding(8)

            // The dim comes after the overlay on purpose: with the drawer open a tap on the dim
            // closes the drawer instead of clicking the Mac.
            if drawerOpen {
                Color.black.opacity(0.58)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { drawerOpen = false } }
                    .closesOnPointerRest { withAnimation(.easeOut(duration: 0.18)) { drawerOpen = false } }
                    .accessibilityHidden(true)
                    .transition(.opacity)

                AppDrawer(client: client, drawerOpen: $drawerOpen)
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 22)
                    .padding(.top, 8 + panelsTop)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }

            // The drawer's mirror on the trailing edge, its right side lined up with the Settings
            // button's. No dim: the stream stays as it is, so a change can be watched taking effect.
            // A tap on it closes the panel and never clicks the Mac; the bar above stays live.
            if settingsOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { setSettings(false) }
                    .accessibilityHidden(true)

                HostSettingsPanel(client: client, close: { setSettings(false) }, pairThisDevice: openPairingOverlay,
                                  takeTour: takeTour, pictureOnly: enterPictureOnly)
                    .frame(width: bar.settingsWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8 + panelsTop)
                    .padding(.bottom, 14)
                    .padding(.trailing, bar.padding)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(settingsTransition())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The link's line

/// The line over the stream while the link cannot carry the quality (docs/remote-bundle-plan.md §6.7):
/// a capsule at the top centre of the stream panel, 8 pt inside its top edge and at most the panel's
/// width less 32 pt, footnote text on the bar's colour; two lines at most, the text no larger than
/// xxLarge. It never takes a touch meant for the Mac, and comes and goes with a fade (with Reduce
/// Motion too). VoiceOver hears it once a spell (StreamScreen.updateLinkLine) and can read it here.
/// In the iPhone Duo's book pose it is centred on the leading page instead, off the fold
/// (docs/iphone-duo-plan.md).
struct LinkLineView: View {
    let text: String?
    /// The Duo's hinge (iOS 27.1): with the fold, where the line goes.
    @Environment(\.duoEnvironment) private var duoEnvironment
    var body: some View {
        GeometryReader { geo in
            let page = DuoPosture.leadingPage(DuoPosture.read(geo, duoEnvironment).info(in: geo.size))
            line
                .frame(width: page ?? geo.size.width)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private var line: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.geist(.footnote))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .rclGlass(in: Capsule(style: .continuous), tint: 0.7)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: text)
    }
}

// MARK: - Top bar

/// The landscape top bar's numbers. The inner display gets the Main board's roomy bar; the outer
/// display gets the Laptop board's compact one, which is 8 pt shorter and tighter all round — on a
/// 500 pt tall screen the bar is a sixth of everything there is, so every point it gives back is a
/// point of Mac. Every bar carries the Aa control (Noah, 2026-09-22: both orientations); it takes
/// one button's width and unfolds over its neighbours only while touched.
/// Hide the Bar's handle: a short pill at the top centre of the picture. A tap, a pull down or the
/// pointer resting on it brings the bar down. Only that pill takes touches, so the Mac's menu bar and
/// window title on either side of it stay clickable.
private struct BarHandle: View {
    let reveal: () -> Void
    /// The pointer resting on it acts too: the bar's handle, never Picture Only's, which a pointer
    /// passing on its way to the Mac's menu bar would end.
    var onHover = true

    var body: some View {
        pill
            .contentShape(Rectangle())
            .onTapGesture { reveal() }
            .gesture(pull)
            .onContinuousHover { phase in hovered(phase) }
            .accessibilityElement()
            .accessibilityLabel("Show the bar")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { reveal() }
    }

    private var pill: some View {
        let backing = Capsule(style: .continuous).fill(Color.black.opacity(0.35))
        return Capsule(style: .continuous)
            .fill(Color.white.opacity(0.45))
            .frame(width: 48, height: 5)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .background(backing.padding(.horizontal, 8).padding(.bottom, 6))
    }

    private var pull: some Gesture {
        DragGesture(minimumDistance: 6).onEnded { drag in
            if drag.translation.height > 8 { reveal() }
        }
    }

    private func hovered(_ phase: HoverPhase) {
        if onHover, case .active = phase { reveal() }
    }
}

struct BarMetrics {
    let height: CGFloat
    let padding: CGFloat
    let gap: CGFloat
    let buttonWidth: CGFloat
    let buttonHeight: CGFloat
    let buttonSpacing: CGFloat      // between a button's icon and its label
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat
    let thumbRadius: CGFloat
    let thumbSpacing: CGFloat
    let thumbPad: CGFloat
    let thumbFade: Double
    let showsTextSize: Bool
    /// The Settings panel hanging under this bar.
    let settingsWidth: CGFloat
    /// Labels under the buttons' symbols; the slim bar has symbols alone.
    var labels = true
    var iconSize: CGFloat = 22
    /// The app badge on each thumbnail.
    var badge: CGFloat = 24

    static let regular = BarMetrics(height: 86, padding: 22, gap: 12,
                                    buttonWidth: 66, buttonHeight: 66, buttonSpacing: 4,
                                    thumbWidth: 104, thumbHeight: 66, thumbRadius: 10,
                                    thumbSpacing: 16, thumbPad: 10, thumbFade: 0.86,
                                    showsTextSize: true, settingsWidth: 360)

    /// Slim Bar (RCL, an iPad's Settings): for a bar left showing all the time, half the height,
    /// symbols alone, smaller thumbnails; the picture gets the room.
    static let slim = BarMetrics(height: 36, padding: 10, gap: 6,
                                 buttonWidth: 38, buttonHeight: 28, buttonSpacing: 0,
                                 thumbWidth: 46, thumbHeight: 28, thumbRadius: 6,
                                 thumbSpacing: 8, thumbPad: 4, thumbFade: 0.9,
                                 showsTextSize: false, settingsWidth: 360, labels: false, iconSize: 15, badge: 15)

    /// The Pill widened (FloatingPill.swift): the bar as a capsule in its corner, symbols alone.
    static let pill = BarMetrics(height: 46, padding: 6, gap: 2,
                                 buttonWidth: 40, buttonHeight: 36, buttonSpacing: 0,
                                 thumbWidth: 46, thumbHeight: 28, thumbRadius: 6,
                                 thumbSpacing: 8, thumbPad: 4, thumbFade: 0.9,
                                 showsTextSize: false, settingsWidth: 360, labels: false, iconSize: 17, badge: 15)

    static let compact = BarMetrics(height: 78, padding: 14, gap: 12,
                                    buttonWidth: 64, buttonHeight: 58, buttonSpacing: 3,
                                    thumbWidth: 92, thumbHeight: 58, thumbRadius: 9,
                                    thumbSpacing: 14, thumbPad: 10, thumbFade: 0.88,
                                    showsTextSize: true, settingsWidth: 340)
}

private struct TopBar: View {
    @ObservedObject var client: StreamClient
    let metrics: BarMetrics
    /// The book pose: the strip's width, so that it ends short of the fold (BarMetrics.clearing);
    /// nil: it takes the room there is, as before.
    var stripWidth: CGFloat? = nil
    @Binding var drawerOpen: Bool
    @Binding var keyboardShown: Bool
    @Binding var textScale: Double?
    @Binding var scaleOpen: Bool
    @Binding var windowMenu: UInt32?
    let settingsOpen: Bool
    /// Whether the bar holds the Menus button and still a whole thumbnail (`MacMenuButton.fits`).
    let menusFit: Bool
    let toggleKeyboard: () -> Void
    /// Opens or closes the Settings panel; the second argument says whether closing puts the
    /// keyboard back (see `StreamScreen.setSettings`).
    let setSettings: (_ open: Bool, _ restoreKeyboard: Bool) -> Void
    /// The Menus pull-down opened and went (see `StreamScreen.menusOpened`).
    let menusOpened: () -> Void
    let menusClosed: () -> Void
    /// The Pill widened: a capsule, what streams in place of the strip with the windows as a menu.
    var pill = false
    /// The narrow pill's frame, which the wide one grows from (FloatingPill's `pillMorph`).
    var pillSpace: Namespace.ID? = nil
    /// As a notch: the glass reaches the screen's top, the buttons sit this far below it, clear of
    /// iPadOS's own menu bar, which drops over the top edge as the pointer reaches it and takes the
    /// clicks there.
    var topInset: CGFloat = 0
    @AppStorage(PillBar.cornerKey) private var pillCorner = PillBar.Corner.topTrailing.rawValue

    @AppStorage(StreamClient.magnifierKey) private var magnifier = false
    @State private var windowsOpen = false
    /// The pointer resting on what streams opens the windows' menu (a short pause, so passing over doesn't).
    @State private var hoverOpen: Task<Void, Never>?
    @AppStorage(BarItems.hiddenKey) private var hiddenRaw = ""
    @State private var moreOpen = false
    @State private var filesFromMore = false
    @State private var editingShortcuts = false

    var body: some View {
        HStack(spacing: metrics.gap) {
            button(open: drawerOpen, symbol: "magnifyingglass", label: String(localized: "Apps"),
                   accessibilityLabel: drawerOpen ? String(localized: "Close the app list") : String(localized: "Open the app list"),
                   action: {
                       setSettings(false, false)
                       withAnimation(.easeOut(duration: 0.18)) { drawerOpen.toggle() }
                   })

            if pill {
                currentWindowButton
                pillWindows
            } else {
                WindowStrip(client: client, width: metrics.thumbWidth, height: metrics.thumbHeight,
                            radius: metrics.thumbRadius, spacing: metrics.thumbSpacing,
                            pad: metrics.thumbPad, fade: metrics.thumbFade, badge: metrics.badge, menuFor: $windowMenu,
                            menusOpened: menusOpened, menusClosed: menusClosed)
                    .opacity(scaleOpen ? 0.2 : 1)      // the ruler is centred on Aa and reaches over the strip's end
                    .allowsHitTesting(!scaleOpen)
                    .frame(width: stripWidth)
                    .tourTarget(.strip, inset: WindowStrip.tourBand(pad: metrics.thumbPad))
            }
            // The book pose: the fold's band, and nothing on it, between the strip and the buttons.
            if stripWidth != nil { Spacer(minLength: 0) }

            // How the link is doing, the way in, Automatic Quality and Private Mode (StatusPill).
            StatusPill(client: client, compact: !metrics.labels) { setSettings(!settingsOpen, true) }
                .opacity(scaleOpen ? 0 : 1)

            // The Mac's menus of the streamed app, next to the thumbnails because they are the picked
            // window's app's. Only while the Mac sent some, and where the bar holds it: with none the
            // strip takes its room back.
            if client.menus.hasMenus, menusFit {
                MacMenuButton(client: client, width: metrics.buttonWidth, height: metrics.buttonHeight,
                              radius: metrics.labels ? 16 : 9, iconSize: metrics.iconSize,
                              spacing: metrics.buttonSpacing, labelled: metrics.labels, onOpen: menusOpened, onClose: menusClosed)
                    .opacity(scaleOpen ? 0 : 1)    // under the Aa ruler, as the buttons after Aa
                    .allowsHitTesting(!scaleOpen)
                    .transition(.opacity)
            }

            // The person's own buttons (BarItems), the hidden ones under More.
            ForEach(BarItems.Item.allCases.filter { !hidden.contains($0) && available($0) }) { item in
                itemButton(item)
                    .opacity(scaleOpen ? 0 : 1)
                    .allowsHitTesting(!scaleOpen)
            }
            if !hiddenAvailable.isEmpty {
                button(open: moreOpen, symbol: "ellipsis.circle", label: String(localized: "More"), accessibilityLabel: String(localized: "More buttons"),
                       action: { moreOpen = true })
                    .popover(isPresented: $moreOpen) { morePanel.presentationCompactAdaptation(.popover) }
            }

            // Leave's old slot: Disconnect is the Settings panel's pinned last row now.
            button(open: settingsOpen, symbol: "gearshape", label: String(localized: "Settings"),
                   accessibilityLabel: settingsOpen ? String(localized: "Close settings") : String(localized: "Settings for \(client.macName.isEmpty ? "the Mac" : client.macName)"),
                   action: { setSettings(!settingsOpen, true) })
                .opacity(scaleOpen ? 0 : 1)
                .allowsHitTesting(!scaleOpen)
                .tourTarget(.settings)
        }
        .animation(.easeOut(duration: 0.16), value: scaleOpen)
        .animation(.easeOut(duration: 0.18), value: client.menus.hasMenus)
        .sheet(isPresented: $filesFromMore) { GetFromMacView(client: client) }
        .sheet(isPresented: $editingShortcuts) { ShortcutEditor() }
        .onChange(of: moreOpen) { _, now in client.filesSheetOpen = now || filesFromMore || editingShortcuts || windowsOpen }
        .onChange(of: filesFromMore) { _, now in client.filesSheetOpen = now || moreOpen || windowsOpen }
        .onChange(of: editingShortcuts) { _, now in client.filesSheetOpen = now || moreOpen || windowsOpen }
        // The windows' menu holds the wide pill open as a sheet from the bar does.
        .onChange(of: windowsOpen) { _, now in client.filesSheetOpen = now || moreOpen || filesFromMore || editingShortcuts }
        .frame(height: metrics.height)
        .padding(.horizontal, metrics.padding)
        .padding(.top, topInset)
        // The bar's glass (its colour before iPadOS 26) runs to the screen edge; its contents stay
        // inside the safe area. Over the picture (Hide the Bar) the glass shows the picture through.
        // The pill's is its capsule.
        .background {
            if pill {
                Color.clear.rclGlass(in: PillBar.shape(PillBar.corner(pillCorner)), tint: 0.5).pillMorph(pillSpace)
            } else {
                Color.clear.rclGlass(in: Rectangle(), tint: 0.85).ignoresSafeArea(edges: .top)
            }
        }
    }

    /// The wide pill's what-streams button: its app and name, and the windows' menu under it.
    private var currentWindowButton: some View {
        let now = PillBar.current(client)
        return Button { windowsOpen.toggle() } label: {
            HStack(spacing: 7) {
                PillBar.icon(now)
                Text(now.name.count > 22 ? String(now.name.prefix(21)) + "…" : now.name)
                    .font(.geist(13, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.geist(11, .semibold)).foregroundStyle(Palette.barLabel)
                    .rotationEffect(.degrees(windowsOpen ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: metrics.buttonHeight)
            .background(Capsule(style: .continuous).fill(windowsOpen ? Palette.controlOpen : Palette.control.opacity(0.6)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .onHover { inside in
            hoverOpen?.cancel()
            guard inside, !windowsOpen else { return }
            hoverOpen = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { windowsOpen = true }
            }
        }
        .accessibilityLabel(String(localized: "\(now.name). Windows"))
        #if DEBUG
        // Harness: `-SillWindowsMenu 1` opens the windows' menu once the pill has widened.
        .task {
            guard UserDefaults.standard.bool(forKey: "SillWindowsMenu") else { return }
            try? await Task.sleep(for: .seconds(0.8))
            windowsOpen = true
        }
        #endif
        .popover(isPresented: $windowsOpen) {
            WindowListMenu(client: client, close: { windowsOpen = false },
                           openApps: {
                               windowsOpen = false
                               withAnimation(.easeOut(duration: 0.18)) { drawerOpen = true }
                           })
                .presentationCompactAdaptation(.popover)
        }
    }

    private func button(open: Bool, symbol: String, label: String, accessibilityLabel: String,
                        action: @escaping () -> Void) -> some View {
        BarButton(open: open, width: metrics.buttonWidth, height: metrics.buttonHeight,
                  radius: metrics.labels ? 16 : 9, accessibilityLabel: accessibilityLabel, action: action) {
            VStack(spacing: metrics.buttonSpacing) {
                Image(systemName: symbol)
                    .font(.geist(metrics.iconSize))
                    .foregroundStyle(open ? Palette.accent : Palette.text)
                if metrics.labels {
                    Text(label)
                        .font(.geist(11, .medium))
                        .foregroundStyle(open ? Palette.accent : Palette.barLabel)
                }
            }
        }
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }

    /// The wide pill's open windows as a row of their apps' icons, a tap each: what the strip did, one
    /// click away. Six at most, the strip's order; the rest are in the windows' menu.
    static let pillWindowCount = 6

    @ViewBuilder private var pillWindows: some View {
        let windows = Array(client.orderedWindows.prefix(Self.pillWindowCount))
        if !windows.isEmpty {
            HStack(spacing: 2) {
                ForEach(windows) { w in
                    let active = client.active == .window(w.id)
                    Button { client.select(.window(w.id)) } label: {
                        AppIcon(image: client.icons[w.bundleID], name: w.appName, size: 26, radius: 6, fontSize: 10)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(active ? Palette.controlOpen : .clear))
                            .overlay(alignment: .bottom) {
                                // The streamed window's app, as the Dock marks a running one.
                                Circle().fill(active ? Palette.accent : .clear).frame(width: 4, height: 4).offset(y: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.lift)
                    .help(w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)")
                    .accessibilityLabel(w.title.isEmpty ? w.appName : "\(w.appName), \(w.title)")
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .contextMenu {
                        Button(String(localized: "Close Window"), systemImage: "xmark") { client.command(.close, window: w.id) }
                        Button(String(localized: "Minimize"), systemImage: "minus") { client.command(.minimize, window: w.id) }
                        Button(String(localized: "Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right") {
                            client.command(.fullScreen, window: w.id)
                        }
                        Divider()
                        Button(String(localized: "Hide \(w.appName)"), systemImage: "eye.slash") { client.appCommand("hide", bundleID: w.bundleID) }
                        Button(String(localized: "Quit \(w.appName)"), systemImage: "xmark.circle", role: .destructive) {
                            client.appCommand("quit", bundleID: w.bundleID)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Palette.barLabel.opacity(0.25)).frame(width: 0.5, height: 22).offset(x: 3)
            }
        }
    }

    // MARK: The person's buttons (BarItems)

    private var hidden: Set<BarItems.Item> { BarItems.hidden(hiddenRaw) }
    private var hiddenAvailable: [BarItems.Item] { BarItems.Item.allCases.filter { hidden.contains($0) && available($0) } }

    /// Shortcuts and the magnifier are an iPad's (a phone has them elsewhere).
    private func available(_ item: BarItems.Item) -> Bool {
        switch item {
        case .shortcuts, .magnifier: return UIDevice.current.userInterfaceIdiom == .pad
        default: return true
        }
    }

    @ViewBuilder private func itemButton(_ item: BarItems.Item) -> some View {
        switch item {
        case .files:
            FilesBarButton(client: client, width: metrics.buttonWidth, height: metrics.buttonHeight,
                           radius: metrics.labels ? 16 : 9, iconSize: metrics.iconSize, labelled: metrics.labels)
        case .shortcuts:
            ShortcutsBarButton(client: client, width: metrics.buttonWidth, height: metrics.buttonHeight,
                               radius: metrics.labels ? 16 : 9, iconSize: metrics.iconSize, labelled: metrics.labels)
        case .magnifier:
            button(open: magnifier, symbol: "plus.magnifyingglass", label: String(localized: "Magnifier"),
                   accessibilityLabel: magnifier ? String(localized: "Magnifier on") : String(localized: "Magnifier off"),
                   action: { magnifier.toggle() })
        case .keyboard:
            button(open: keyboardShown, symbol: "keyboard", label: String(localized: "Keyboard"),
                   accessibilityLabel: keyboardShown ? String(localized: "Hide the keyboard") : String(localized: "Show the keyboard"),
                   action: { setSettings(false, false); toggleKeyboard() })
                .tourTarget(.keyboard)
        case .desktop:
            button(open: client.active == .desktop, symbol: "desktopcomputer", label: client.desktopLabel,
                   accessibilityLabel: client.active == .desktop && client.displays.count > 1 ? String(localized: "Show the Mac’s next display") : String(localized: "Show the full Mac desktop"),
                   action: { client.desktopTapped() })
                .displaysMenu(client)
                .overlay(alignment: .topTrailing) {
                    // Which display the Desktop streams, where the label that says it isn't shown.
                    if !metrics.labels, let n = client.desktopNumber {
                        Text("\(n)").font(.geist(9, .bold)).foregroundStyle(.black)
                            .frame(width: 14, height: 14).background(Circle().fill(Palette.accent))
                            .offset(x: 3, y: -3).accessibilityHidden(true)
                    }
                }
        }
    }

    /// More: what the person tucked away, a tap each; Shortcuts as their grid.
    private var morePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(hiddenAvailable.filter { $0 != .shortcuts }) { item in
                Button {
                    moreOpen = false
                    switch item {
                    case .files: DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { filesFromMore = true }
                    case .magnifier: magnifier.toggle()
                    case .keyboard: setSettings(false, false); toggleKeyboard()
                    case .desktop: client.desktopTapped()
                    case .shortcuts: break
                    }
                } label: {
                    Label(item == .desktop ? client.desktopLabel : item.title, systemImage: item.symbol)
                        .font(.geist(.body))
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if hiddenAvailable.contains(.shortcuts) {
                if hiddenAvailable.count > 1 { Divider().padding(.vertical, 4) }
                ShortcutGrid(client: client, columns: 3) { moreOpen = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { editingShortcuts = true } }
            }
        }
        .padding(16)
        .frame(width: hiddenAvailable.contains(.shortcuts) ? 380 : 240)
    }
}

// MARK: - Spotlight

/// Spotlight on the Mac: exactly ⌘Space, down then up. Whatever modifiers are latched never join
/// it — the button means Spotlight, not "space with whatever happens to be held".
enum Spotlight {
    /// The sparkle magnifier where the system has it. The Apps button already uses the plain
    /// magnifier, so the fallback must still look different from it.
    static let symbol: String = UIImage(systemName: "sparkle.magnifyingglass") != nil
        ? "sparkle.magnifyingglass" : "magnifyingglass.circle"

    static func press(send: (InputEvent) -> Void) {
        KeyChord.spotlight.forEach(send)
    }
}

/// A bar button: 66×66 in the roomy top bar, 64×58 in the compact one and the portrait window bar,
/// 56×50 with a 14 pt radius in the outer display's portrait bar, and 50 pt tall with its share of
/// the row's width in a phone's row 1.
struct BarButton<Content: View>: View {
    let open: Bool
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    let accessibilityLabel: String
    let action: () -> Void
    let content: () -> Content

    init(open: Bool, width: CGFloat = 66, height: CGFloat = 66, radius: CGFloat = 16,
         accessibilityLabel: String,
         action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.open = open
        self.width = width
        self.height = height
        self.radius = radius
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: width, height: height)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(open ? Palette.controlOpen : Palette.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Text size control

/// The Aa control: a bar button that opens into a ruler while the finger is down, the way the
/// camera's zoom button opens into its dial and the Dynamic Island timer scrubs. The thumb stays
/// put at the button's centre and the ruler slides under it: five detents, 0.5× to 1.5× in 0.25
/// steps, a tick of haptic at each. The bar fades the buttons next to it while `open` and brings
/// them back on release, when the chosen value is applied once (every change restarts the stream,
/// so nothing is sent mid-drag). A nil scale means the Mac window has never been asked to fit; it
/// shows 1×.
struct TextScaleControl: View {
    @Binding var scale: Double?
    @Binding var open: Bool
    var width: CGFloat = 66
    var height: CGFloat = 66
    var radius: CGFloat = 16
    /// Finger travel (and ruler spacing) per detent; smaller in the tighter bars so the ruler,
    /// centred on the button, stays inside the screen.
    var pointsPerStep: CGFloat = 44
    /// A fixed height for "Aa", and the space under it, so its value lines up with the labels of
    /// bar buttons whose symbols sit in a box of that height (a phone's row 1); nil: as tall as the
    /// text, 2 pt over the value (every bar that has always had it).
    var iconBox: CGFloat? = nil
    var iconSpacing: CGFloat = 2

    static let steps: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5]
    /// Padding either side of the visible ruler; two detents show each side of the thumb.
    static let sliderInset: CGFloat = 30
    var sliderWidth: CGFloat { pointsPerStep * CGFloat(Self.steps.count - 1) + Self.sliderInset * 2 }

    @State private var live: Double = 1.0
    @State private var startValue: Double = 1.0
    @State private var startX: CGFloat = 0

    var body: some View {
        VStack(spacing: iconBox == nil ? 2 : iconSpacing) {
            if let iconBox {
                Text("Aa")
                    .font(.geist(height >= 60 ? 19 : 17, .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(height: iconBox)
            } else {
                Text("Aa")
                    .font(.geist(height >= 60 ? 19 : 17, .semibold))
                    .foregroundStyle(Palette.text)
            }
            Text(Self.label(scale ?? 1.0) + "×")
                .font(.geist(11, .medium))
                .foregroundStyle(Palette.barLabel)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.control))
        .opacity(open ? 0 : 1)
        .overlay {
            // Centred on the button: the thumb is where the finger came down.
            slider
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.6)
                .allowsHitTesting(false)
        }
        .zIndex(open ? 1 : 0)
        .onChange(of: open, initial: true) { _, isOpen in if isOpen { live = scale ?? 1.0 } }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { g in
                    if !open {
                        startValue = scale ?? 1.0
                        live = startValue
                        startX = g.location.x
                        withAnimation(.spring(duration: 0.22, bounce: 0.15)) { open = true }
                    }
                    // The ruler follows the finger: dragging right raises the value, and the ticks
                    // slide left under the fixed thumb.
                    let dx = g.location.x - startX
                    let snapped = Self.snap(startValue + Double(dx / pointsPerStep) * 0.25)
                    if snapped != live {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.easeOut(duration: 0.1)) { live = snapped }
                    }
                }
                .onEnded { _ in
                    if (scale ?? 1.0) != live { scale = live }     // a plain tap on an untouched control changes nothing
                    withAnimation(.easeOut(duration: 0.2)) { open = false }
                }
        )
        .onDisappear { open = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Text size")
        .accessibilityValue(String(localized: "\(Self.label(scale ?? 1.0)) times"))
        .accessibilityAdjustableAction { direction in
            let i = Self.steps.firstIndex(of: scale ?? 1.0) ?? 2
            switch direction {
            case .increment: scale = Self.steps[min(i + 1, Self.steps.count - 1)]
            case .decrement: scale = Self.steps[max(i - 1, 0)]
            @unknown default: break
            }
        }
    }

    /// The ruler: a track with five ticks and labels that slides so the live value sits under the
    /// fixed thumb; the ends fade out where they run past the panel.
    private var slider: some View {
        let w = sliderWidth
        let step = pointsPerStep
        let midX = w / 2
        let midY = height / 2 + 4
        func x(_ value: Double) -> CGFloat { midX + CGFloat((value - live) / 0.25) * step }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.controlOpen)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Palette.barLabel.opacity(0.35))
                    .frame(width: step * CGFloat(Self.steps.count - 1), height: 3)
                    .offset(x: x(Self.steps[0]), y: midY - 1.5)
                ForEach(Self.steps, id: \.self) { value in
                    Rectangle().fill(Palette.barLabel.opacity(0.6))
                        .frame(width: 2, height: 9)
                        .offset(x: x(value) - 1, y: midY - 4.5)
                    Text(Self.label(value))
                        .font(.geist(10, .medium))
                        .foregroundStyle(value == live ? Palette.text : Palette.barLabel)
                        .frame(width: step, alignment: .center)
                        .offset(x: x(value) - step / 2, y: midY + 9)
                }
            }
            .frame(width: w, height: height, alignment: .topLeading)   // the mask below is sized to this
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            Circle().fill(Palette.accent)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .offset(x: midX - 11, y: midY - 11)
            // The live value over the thumb, where the finger does not cover it. In a 50 pt ruler
            // (a phone's row 1, the compact window bar) `midY - 34` put the top of its digits 2 pt
            // outside the clip; it sits where the 58 pt bars put it (1 pt above the frame's top,
            // the digits 2 pt inside), and in the taller bars as it always has.
            Text(Self.label(live) + "×")
                .font(.geist(13, .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 60, alignment: .center)
                .offset(x: midX - 30, y: max(midY - 34, -1))
        }
        .frame(width: w, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Nearest detent, clamped to the ends.
    static func snap(_ value: Double) -> Double {
        let clamped = min(max(value, steps[0]), steps[steps.count - 1])
        return steps.min { abs($0 - clamped) < abs($1 - clamped) } ?? 1.0
    }

    /// 0.5, 0.75, 1, 1.25, 1.5: trailing zeros dropped, and "1" rather than "1.0".
    static func label(_ scale: Double) -> String {
        var text = String(format: "%.2f", scale)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Window thumbnails

/// The live window thumbnails. Defaults are the roomy top bar's numbers; the compact bars are
/// tighter (92×58 gap 14 fade 88%, and 80×50 radius 8 gap 12 with a 22 pt badge on the outer
/// display), so every size travels as a parameter and the thumbnail, its badge and its active halo
/// stay one view in every posture.
struct WindowStrip: View {
    @ObservedObject var client: StreamClient
    var width: CGFloat = 104
    var height: CGFloat = 66
    var radius: CGFloat = 10
    var spacing: CGFloat = 16
    /// Room above and below for the badge (6 pt out) and the active halo (5 pt out), which the
    /// ScrollView would otherwise clip. It is also what makes the strip as tall as its bar.
    var pad: CGFloat = 10
    var fade: Double = 0.86
    var badge: CGFloat = 24
    /// Which thumbnail has its traffic-light submenu open. Owned by the screen root, which draws
    /// the submenu outside this clipped strip.
    @Binding var menuFor: UInt32?
    /// A right click's pull-down of the Mac's menus opened and went (StreamScreen's `menusOpened`), so
    /// the pulled-down bar stays while it shows.
    var menusOpened: () -> Void = {}
    var menusClosed: () -> Void = {}

    /// Press and hold a thumbnail for half a second: it starts to wiggle and its traffic lights (close,
    /// minimize, full screen) appear in a submenu beside it, the way a held Home Screen icon
    /// offers its menu. Keep holding and move: the submenu goes, the thumbnail lifts and drags
    /// into a new slot. The arrangement is the device's own, persisted per Mac. A tap selects.
    /// Half a second, iOS's own context-menu hold (#113): at 1.5 s, inside the strip's scroll view,
    /// people on an iPad Pro M5 timed 3.5–4 s before the lights came and took it for lag.
    static let holdToOpen: TimeInterval = 0.5
    /// What the tour lights of the strip: its thumbnails' band (the strip is as tall as its bar),
    /// with the active halo's 5 pt above and the app badge's 6 pt below.
    static func tourBand(pad: CGFloat) -> EdgeInsets {
        EdgeInsets(top: max(0, pad - 5), leading: 0, bottom: max(0, pad - 6), trailing: 0)
    }
    @State private var lifted: UInt32? = nil
    @State private var liftOffset: CGFloat = 0
    @State private var liftStartIndex = 0

    var body: some View {
        let windows = client.orderedWindows
        let slot = width + spacing
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    WindowThumbnail(window: window,
                                    image: client.thumbnails[window.id],
                                    icon: client.icons[window.bundleID],
                                    isActive: client.active == .window(window.id) || client.beside == window.id,
                                    width: width, height: height, radius: radius, badge: badge,
                                    menuOpen: menuFor == window.id,
                                    lifted: lifted == window.id,
                                    onSelect: { client.select(.window(window.id)) },
                                    onCommand: { client.command($0, window: window.id) },
                                    onMove: { step in
                                        client.moveWindow(window.id, to: index + step)
                                        client.persistWindowOrder()
                                    })
                        .overlay {
                            HoldDragOverlay(minimumHold: Self.holdToOpen,
                                            onTap: { if menuFor != nil { closeMenu() } else { client.select(.window(window.id)) } },
                                            onHold: { openMenu(for: window.id) },
                                            onSecondary: { present in showMacMenus(for: window, present: present) },
                                            onMenuOpen: { $0 ? menusOpened() : menusClosed() },
                                            onMove: { t in holdMoved(window: window, index: index, count: windows.count, slot: slot, translation: t) },
                                            onEnd: { holdEnded(window: window) })
                        }
                        .offset(x: lifted == window.id ? liftOffset : 0)
                        .zIndex(lifted == window.id ? 1 : 0)
                        // The lifted thumbnail follows the finger: its slot change must not animate,
                        // or the layout springs one way while the compensating offset jumps the other.
                        .transaction { if lifted == window.id { $0.animation = nil } }
                }
            }
            .padding(.vertical, pad)
            .padding(.horizontal, 8)
        }
        .coordinateSpace(name: "strip")
        .scrollDisabled(lifted != nil)
        .frame(maxWidth: .infinity)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: fade),
                                     .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .onChange(of: client.windows) { _, now in
            // A window that closed or minimized takes its menu, and any drag, with it.
            if let id = menuFor, !now.contains(where: { $0.id == id }) { closeMenu() }
            if let id = lifted, !now.contains(where: { $0.id == id }) {
                lifted = nil; liftOffset = 0
                client.persistWindowOrder()
            }
        }
        .onDisappear { lifted = nil; liftOffset = 0 }
        #if DEBUG
        // Harness: `-SillWindowMenu 1` opens the first window's submenu at launch.
        .onAppear {
            if UserDefaults.standard.bool(forKey: "SillWindowMenu"), let first = client.orderedWindows.first { menuFor = first.id }
        }
        #endif
    }

    /// The finger moved while the hold is still down. More than 8 pt lifts the thumbnail and
    /// drags it; the drag reorders live: crossing the middle of a neighbour swaps slots, and the
    /// lifted thumbnail's offset is corrected by the slots it has moved so it stays under the finger.
    private func holdMoved(window: WindowInfo, index: Int, count: Int, slot: CGFloat, translation t: CGSize) {
        if lifted == nil {
            guard abs(t.width) > 8 || abs(t.height) > 8 else { return }
            closeMenu()
            lifted = window.id
            liftStartIndex = index
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        guard lifted == window.id else { return }
        let shift = Int((t.width / slot).rounded())
        let target = max(0, min(count - 1, liftStartIndex + shift))
        if let current = client.orderedWindows.firstIndex(where: { $0.id == window.id }), current != target {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { client.moveWindow(window.id, to: target) }
        }
        liftOffset = t.width - CGFloat(target - liftStartIndex) * slot
    }

    /// The finger lifted after a hold: drop the thumbnail (the submenu, if open, stays).
    private func holdEnded(window: WindowInfo) {
        guard lifted == window.id else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { lifted = nil; liftOffset = 0 }
        client.persistWindowOrder()
    }

    /// A right click on a thumbnail (RCL): the Menus button's pull-down, the Mac's menus of that
    /// window's app. Another window is picked first, and the menus show once the Mac has sent that
    /// app's (by its name, or any new top level after the pick), within 3 s.
    private func showMacMenus(for window: WindowInfo, present: @escaping (UIMenu) -> Void) {
        closeMenu()
        let before = client.menus.version
        let picked = client.active != .window(window.id)
        if picked { client.select(.window(window.id)) }
        func attempt(_ left: Int) {
            let menus = client.menus
            let theirs = menus.app == window.appName || (picked && menus.version != before)
            if menus.hasMenus, theirs || !picked {
                present(UIMenu(children: MacMenuElements.topMenus(client, barIdentifiers: false)))
                return
            }
            guard left > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(left - 1) }
        }
        attempt(30)
    }

    private func openMenu(for id: UInt32) {
        guard menuFor != id else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        menuFor = id
    }

    private func closeMenu() { menuFor = nil }
}

/// A thumbnail's touch handling, in UIKit: a tap selects; a hold of `minimumHold` opens the
/// submenu and keeps tracking the finger, so moving it afterwards drags. UIKit rather than SwiftUI
/// gestures because a SwiftUI long press sequenced with a drag swallowed plain taps inside the
/// ScrollView (2026-09-23), and UIKit's long press is exactly the Home Screen mechanic: by the time
/// it recognizes, the scroll view's pan has already given up, so the drag is ours.
struct HoldDragOverlay: UIViewRepresentable {
    var minimumHold: TimeInterval
    var onTap: () -> Void
    var onHold: () -> Void
    /// A right click (RCL): handed a way to show a menu where the pointer clicked.
    var onSecondary: (@escaping (UIMenu) -> Void) -> Void = { _ in }
    /// That menu showed (true) and went (false).
    var onMenuOpen: (Bool) -> Void = { _ in }
    /// Translation since the hold began, in window coordinates (stable while the view moves).
    var onMove: (CGSize) -> Void
    var onEnd: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = minimumHold
        hold.allowableMovement = 12        // more than this before the hold fires is a scroll, not a hold
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
        // A right click (a trackpad's two-finger click, a mouse's right button) opens the app's menus
        // where the pointer is, as the Menus button does (RCL). A point-sized menu button carries
        // them: UIKit presents a UIMenu only from a control's own interaction.
        let menuButton = MacMenuTriggerButton(type: .custom)
        menuButton.onOpenChange = { [weak coordinator = context.coordinator] open in
            DispatchQueue.main.async { coordinator?.parent.onMenuOpen(open) }
        }
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.preferredMenuElementOrder = .fixed
        menuButton.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.addSubview(menuButton)
        context.coordinator.menuButton = menuButton
        let secondary = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.secondaryClicked(_:)))
        secondary.buttonMaskRequired = .secondary
        view.addGestureRecognizer(secondary)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: HoldDragOverlay
        private var start = CGPoint.zero
        init(_ parent: HoldDragOverlay) { self.parent = parent }

        @objc func tapped() { parent.onTap() }
        weak var menuButton: UIButton?

        @objc func secondaryClicked(_ g: UITapGestureRecognizer) {
            let at = g.location(in: g.view)
            parent.onSecondary { [weak self] menu in
                guard let button = self?.menuButton, button.window != nil else { return }
                button.frame = CGRect(x: at.x, y: at.y, width: 1, height: 1)
                button.menu = menu
                if #available(iOS 17.4, *) { button.performPrimaryAction() }
            }
        }

        @objc func held(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: g.view?.window)
            switch g.state {
            case .began: start = p; parent.onHold()
            case .changed: parent.onMove(CGSize(width: p.x - start.x, height: p.y - start.y))
            case .ended, .cancelled, .failed: parent.onEnd()
            default: break
            }
        }
    }
}

/// The frame of the thumbnail whose submenu is open, reported up to the screen root.
struct WindowMenuAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// macOS's three lights in a floating submenu beside the held thumbnail: below it when the bar
/// is at the top of the screen, above it when the bar is at the bottom (portrait's halves), and
/// always below it on a phone upright, where the strip sits under row 1 and the key row below has
/// room on every phone (above, it would cover row 1 on the shortest). A tap anywhere else
/// dismisses it. Drawn by the screen root, over everything.
struct WindowLightsMenu: View {
    let anchor: Anchor<CGRect>
    let window: WindowInfo
    let command: (WindowCommand.Action) -> Void
    /// Side by side (RCL): offered for a window that is not streaming (`.add`), or to end it for the
    /// one beside (`.remove`); nil: no fourth button.
    var beside: BesideOffer? = nil
    var toggleBeside: () -> Void = {}
    /// Quit the window's app (RCL; a Mac that takes kind 49); nil: no Quit button.
    var quit: (() -> Void)? = nil
    let dismiss: () -> Void
    /// Whether a screen of this size always puts the lights below the thumbnail (the phone's
    /// arrangement); otherwise they go on the side of the screen's middle away from it.
    var alwaysBelow: (CGSize) -> Bool = { _ in false }

    private static let size = CGSize(width: 214, height: 62)
    private var size: CGSize {
        CGSize(width: Self.size.width + (beside == nil ? 0 : 66) + (quit == nil ? 0 : 66), height: Self.size.height)
    }
    /// The Duo's hinge (iOS 27.1): the lights keep off its fold.
    @Environment(\.duoEnvironment) private var duoEnvironment

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy[anchor]
            let w = size.width, h = size.height
            // Off the Duo's fold (iOS 27.1): onto a page beside it, below the thumbnail when above it
            // would sit on it; elsewhere as before.
            let at = DuoPosture.lightsMenu(x: min(max(frame.midX, w / 2 + 8), proxy.size.width - w / 2 - 8),
                                           below: alwaysBelow(proxy.size) || frame.midY < proxy.size.height / 2,
                                           thumbnail: frame, size: size, gap: 8, screenWidth: proxy.size.width,
                                           fold: DuoPosture.read(proxy, duoEnvironment).info(in: proxy.size))
            let below = at.below, x = at.x, y = at.y
            ZStack {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: dismiss)
                HStack(spacing: 6) {
                    light(.close, Color(hex: 0xFF5F57), "xmark", "Close")
                    light(.minimize, Color(hex: 0xFEBC2E), "minus", "Minimize")
                    light(.fullScreen, Color(hex: 0x28C840), "arrow.up.left.and.arrow.down.right", String(localized: "Full Screen"))
                    if let beside { besideButton(beside) }
                    if let quit { quitButton(quit) }
                }
                .padding(.horizontal, 10)
                .frame(width: w, height: h)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Palette.control)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                )
                .position(x: x, y: y)
                .transition(.scale(scale: 0.8, anchor: below ? .top : .bottom).combined(with: .opacity))
            }
            .accessibilityLabel("\(window.appName) window actions")
        }
    }

    private func quitButton(_ quit: @escaping () -> Void) -> some View {
        Button(action: quit) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.85)).frame(width: 24, height: 24)
                    Image(systemName: "power")
                        .font(.geist(10, .heavy))
                        .foregroundStyle(.black.opacity(0.7))
                }
                Text("Quit")
                    .font(.geist(10, .medium))
                    .foregroundStyle(Palette.barLabel)
                    .lineLimit(1)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quit \(window.appName)")
    }

    private func besideButton(_ offer: BesideOffer) -> some View {
        Button(action: toggleBeside) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(Palette.accent).frame(width: 24, height: 24)
                    Image(systemName: offer == .add ? "rectangle.split.2x1" : "rectangle")
                        .font(.geist(10, .heavy))
                        .foregroundStyle(.black.opacity(0.7))
                }
                Text(offer == .add ? String(localized: "Side by Side") : String(localized: "One Window"))
                    .font(.geist(10, .medium))
                    .foregroundStyle(Palette.barLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(offer == .add ? String(localized: "Show beside the window streaming now") : String(localized: "Show one window again"))
    }

    private func light(_ action: WindowCommand.Action, _ color: Color, _ symbol: String, _ label: String) -> some View {
        Button { command(action) } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(color).frame(width: 24, height: 24)
                    Image(systemName: symbol)
                        .font(.geist(10, .heavy))
                        .foregroundStyle(.black.opacity(0.65))
                }
                Text(label)
                    .font(.geist(10, .medium))
                    .foregroundStyle(Palette.barLabel)
                    .lineLimit(1)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) window")
    }
}

private struct WindowThumbnail: View {
    let window: WindowInfo
    let image: UIImage?
    let icon: UIImage?
    let isActive: Bool
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    let badge: CGFloat
    let menuOpen: Bool
    let lifted: Bool
    /// VoiceOver's routes to what the finger does with a tap, the hold submenu and the drag.
    let onSelect: () -> Void
    let onCommand: (WindowCommand.Action) -> Void
    let onMove: (Int) -> Void

    var body: some View {
        // Two stages: one long chain of modifiers here is more than the type checker will take.
        card
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.appName) window: \(window.title)" + (isActive ? String(localized: ", showing now") : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { onSelect() }
            .accessibilityAction(named: "Close window") { onCommand(.close) }
            .accessibilityAction(named: "Minimize window") { onCommand(.minimize) }
            .accessibilityAction(named: "Full screen") { onCommand(.fullScreen) }
            .accessibilityAction(named: "Move left") { onMove(-1) }
            .accessibilityAction(named: "Move right") { onMove(1) }
    }

    /// The thumbnail with its badge, halo, wiggle and lift.
    private var card: some View {
        let halo = RoundedRectangle(cornerRadius: radius + 5, style: .continuous)
            .strokeBorder(Palette.accent, lineWidth: 2)
            .padding(-5)
        return preview
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // The active halo sits under the app badge: the badge's bar-coloured ring then reads as
            // cutting through the halo, instead of the halo slicing across the icon. It follows the
            // thumbnail's own radius so both sizes keep the same 3 pt gap.
            .overlay { if isActive { halo } }
            // The badge barely scales with the thumbnail; it is the app's identity, not chrome,
            // so it only shrinks once, to 22 pt, on the outer display's smallest bar.
            .overlay(alignment: .bottomLeading) { appBadge.offset(x: -6, y: 6) }
            // Held: the Home Screen wiggle, until the submenu is dismissed. Lifted: bigger, with a shadow.
            .rotationEffect(.degrees(menuOpen ? 1.8 : 0))
            .offset(y: menuOpen ? -1 : 0)
            .animation(menuOpen ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true) : .easeOut(duration: 0.15),
                       value: menuOpen)
            .scaleEffect(lifted ? 1.08 : (menuOpen ? 1.04 : 1))
            .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: 10, y: 4)
            .anchorPreference(key: WindowMenuAnchorKey.self, value: .bounds) { menuOpen ? $0 : nil }
    }

    @ViewBuilder private var preview: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            VStack(spacing: 0) {
                Palette.thumbTitleBar.frame(height: 9)
                Palette.thumbBody
            }
        }
    }

    /// The app icon, with a 2 pt bar-coloured ring around it so it cuts through the thumbnail's
    /// edge and its halo instead of sitting on top of them.
    private var appBadge: some View {
        let corner = (badge * 0.29).rounded()      // 7 at 24 pt, 6 at 22
        return AppIcon(image: icon, name: window.appName, size: badge, radius: corner,
                       fontSize: (badge * 0.42).rounded())
            .background {
                RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                    .fill(Palette.bar)
                    .frame(width: badge + 4, height: badge + 4)
            }
    }
}

/// An app icon, or its first two letters while the host has not sent one.
struct AppIcon: View {
    let image: UIImage?
    let name: String
    let size: CGFloat
    let radius: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Palette.iconFallback.overlay(
                    Text(String(name.prefix(2)))
                        .font(.geist(fontSize, .semibold))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - App drawer

private struct OpenApp: Identifiable {
    let bundleID: String
    let name: String
    let windows: [WindowInfo]
    var id: String { bundleID }
}

struct AppDrawer: View {
    @ObservedObject var client: StreamClient
    @Binding var drawerOpen: Bool
    @State private var search = ""
    /// The search field has the keyboard. Set only by DEBUG `-SillDrawerSearch` (ContentView's
    /// contract); a tap focuses the field as before.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            searchField
            ScrollView {
                VStack(spacing: 6) {
                    if !openApps.isEmpty {
                        header(String(localized: "Open now"))
                        ForEach(openApps) { app in
                            DrawerRow(height: 50,
                                      highlighted: app.bundleID == activeBundleID,
                                      title: app.name,
                                      trailing: app.windows.count == 1 ? String(localized: "1 window") : String(localized: "\(app.windows.count) windows"),
                                      action: { show(app) }) {
                                AppIcon(image: client.icons[app.bundleID], name: app.name,
                                        size: 32, radius: 9, fontSize: 12)
                            }
                        }
                    }
                    if !closedApps.isEmpty {
                        header(String(localized: "All apps")).padding(.top, 2)
                        ForEach(closedApps) { app in
                            DrawerRow(height: 46, highlighted: false, title: app.name, trailing: nil,
                                      action: { client.launch(bundleID: app.bundleID) }) {
                                AppIcon(image: client.icons[app.bundleID], name: app.name,
                                        size: 32, radius: 9, fontSize: 12)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.bar))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.65), radius: 30, x: 0, y: 24)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.geist(18))
                .foregroundStyle(Palette.muted)
            TextField("", text: $search,
                      prompt: Text("Search apps on \(client.macName)").foregroundColor(Palette.muted))
                .font(.geist(15))
                .foregroundStyle(Palette.text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityLabel("Search apps on this Mac")
                .focused($searchFocused)
        }
        .frame(height: 48)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.control))
        #if DEBUG
        .onAppear(perform: searchFromLaunchArguments)
        #endif
    }

    #if DEBUG
    /// `-SillDrawerSearch <text>` (ContentView's contract): the drawer, once open, searches for that
    /// text with the keyboard up for its field, as a tap and typing would, so a photo shows what the
    /// keyboard leaves in view of the results.
    private func searchFromLaunchArguments() {
        guard let query = UserDefaults.standard.string(forKey: "SillDrawerSearch") else { return }
        search = query
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            searchFocused = true
            print("harness: the drawer's search field has the keyboard, searching for \"\(query)\"")
        }
    }
    #endif

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.geist(13, .medium))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    // MARK: Contents

    /// Running apps, grouped from the window list and kept in its front-to-back order.
    private var openApps: [OpenApp] {
        var order: [String] = []
        var names: [String: String] = [:]
        var grouped: [String: [WindowInfo]] = [:]
        for window in client.windows {
            if grouped[window.bundleID] == nil {
                order.append(window.bundleID)
                names[window.bundleID] = window.appName
            }
            grouped[window.bundleID, default: []].append(window)
        }
        return order.map { OpenApp(bundleID: $0, name: names[$0] ?? $0, windows: grouped[$0] ?? []) }
            .filter { matches($0.name) }
    }

    private var closedApps: [AppInfo] {
        let running = Set(client.windows.map(\.bundleID))
        return client.apps
            .filter { !running.contains($0.bundleID) && matches($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var activeBundleID: String? {
        guard case .window(let id) = client.active else { return nil }
        return client.windows.first { $0.id == id }?.bundleID
    }

    private func matches(_ name: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || name.range(of: query, options: .caseInsensitive) != nil
    }

    /// First window of the app, or the next one if this app is already showing.
    private func show(_ app: OpenApp) {
        guard !app.windows.isEmpty else { return }
        var target = app.windows[0]
        if case .window(let id) = client.active,
           let index = app.windows.firstIndex(where: { $0.id == id }) {
            target = app.windows[(index + 1) % app.windows.count]
        }
        client.select(.window(target.id))
        withAnimation(.easeOut(duration: 0.18)) { drawerOpen = false }
    }
}

/// One app row: icon, name, optional trailing count.
struct DrawerRow<Leading: View>: View {
    let height: CGFloat
    let highlighted: Bool
    let title: String
    let trailing: String?
    let action: () -> Void
    let leading: () -> Leading

    init(height: CGFloat, highlighted: Bool, title: String, trailing: String?,
         action: @escaping () -> Void, @ViewBuilder leading: @escaping () -> Leading) {
        self.height = height
        self.highlighted = highlighted
        self.title = title
        self.trailing = trailing
        self.action = action
        self.leading = leading
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                Text(title)
                    .font(.geist(15))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing {
                    // Whole, on one line, whatever the title's length: the title truncates instead
                    // ("Not paired", "Update RCL" and "3 windows" hold a space).
                    Text(trailing)
                        .font(.geist(13))
                        .foregroundStyle(Palette.muted)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? Palette.control : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Larger Picture's view of what streams

extension PhonePortraitLayout.Streaming {
    /// What the Mac's window list says streams (`StreamClient.active`), as Larger Picture's rule
    /// (`PhonePortraitLayout.largerPicture(switchOn:streaming:)`) reads it.
    init(_ source: StreamSource) {
        switch source {
        case .none: self = .nothing
        case .desktop: self = .desktop
        case .window: self = .window
        }
    }
}

/// The lights menu's fourth button (RCL's side by side).
enum BesideOffer { case add, remove }

/// The Desktop button held (RCL): the Mac's displays by name, to stream one straight away.
private struct DisplaysMenu: ViewModifier {
    @ObservedObject var client: StreamClient
    func body(content: Content) -> some View {
        if client.displays.count > 1 {
            content.contextMenu {
                ForEach(client.displays) { d in
                    Button { client.chooseDisplay(d.id) } label: {
                        Label(d.name, systemImage: client.active == .desktop && d.id == client.desktopDisplay ? "checkmark" : "display")
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func displaysMenu(_ client: StreamClient) -> some View { modifier(DisplaysMenu(client: client)) }
}

/// RCL: an iPad's trackpad or mouse pointer resting a moment on what lies outside an open drawer or
/// Settings panel (back over the Mac's picture) closes it, as a Mac's menu goes when left. A short
/// wait, so the pointer crossing a gap on its way into the panel closes nothing. UIKit's hover, laid
/// over the area: SwiftUI's `onHover` there never heard the pointer (Alfonso's iPad, 2026-10-24).
private struct PointerRestCatcher: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered(_:))))
        // It lies over the tap catcher, so it takes the tap too: the same closing.
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        private var wait: DispatchWorkItem?
        init(action: @escaping () -> Void) { self.action = action }

        @objc func tapped() { action() }

        @objc func hovered(_ g: UIHoverGestureRecognizer) {
            switch g.state {
            case .began:
                wait?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.action() }
                wait = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            case .changed:
                break
            default:
                wait?.cancel()
                wait = nil
            }
        }
    }
}

extension View {
    /// A tap closes as before; the pointer resting here closes too (PointerRestCatcher).
    func closesOnPointerRest(_ action: @escaping () -> Void) -> some View {
        overlay(PointerRestCatcher(action: action).allowsHitTesting(true))
    }
}
