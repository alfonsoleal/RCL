import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import StreamProtocol

/// The Settings panel: the Mac's streaming settings, changed from here the way the Sill menu on
/// the Mac changes them (one change, one apply, at most one short restart; Sill.app saves them).
///
/// A panel in the view hierarchy, mirroring the Apps drawer on the trailing edge; not a sheet,
/// popover or Menu. The client has no system presentation anywhere; sheets and popovers adapt by
/// size class, which is unknown for the Duo; the layout harness draws a fake Duo screen inside an
/// iPad window, which a system presentation would escape; and a tall sheet or a flipped popover
/// could cross the half-folded crease. Its height follows its content; only the middle scrolls,
/// where the room under the bar is short (259 pt in the compact halves at 500×710, an iPad window
/// that narrow; 279 on an iPhone SE upright with Larger Picture; 275 on an SE on its side), so the
/// header and Disconnect are always in reach.
///
/// Every control shows `client.settings.displayed` (the Mac's value with this device's unanswered
/// pick over it) and sends through `client.changeSettings`, one field per control, from its action
/// only. Errors show inline, never in alerts. After the Mac's settings come the device's own groups:
/// This iPad (or iPhone), whose switches are preferences here and send nothing to the Mac (Larger
/// Picture, `StreamClient.largerPictureKey`, on an iPhone without a hinge whose picture it makes
/// larger, `largerPictureOffered`; Share Clipboard, `StreamClient.clipboardKey`, while the Mac shares
/// its clipboard, with the system's Paste for this device's text; Three-Finger Gestures,
/// `StreamClient.gesturesKey`), and whose gesture rows, as accessibility actions, do their gestures
/// (`client.sendGesture`), since VoiceOver keeps three fingers for itself; then Take the Tour.
struct HostSettingsPanel: View {
    @ObservedObject var client: StreamClient
    /// Done, Esc or ⌘., and the VoiceOver escape gesture.
    let close: () -> Void
    /// Pair This iPad…: the stream screen puts the panel away and covers the stream with the
    /// pairing overlay.
    var pairThisDevice: () -> Void = {}
    /// Take the Tour: the stream screen puts the panel away and shows the tour of its layout.
    var takeTour: () -> Void = {}
    /// Picture Only (#145): the stream screen puts the panel away and shows the picture alone.
    var pictureOnly: () -> Void = {}

    @AccessibilityFocusState private var headerFocused: Bool
    /// Two seconds on this connection and still no state: the Mac runs a Sill without settings.
    @State private var olderMac = false
    /// Bumped when Low Power Mode toggles, so the frame rate note is read again.
    @State private var powerState = 0
    /// This device's switch for three-finger gestures (docs/trackpad-gestures-plan.md §8): on unless
    /// turned off, read by `StreamClient.sendGesture` at each gesture, never sent.
    @AppStorage(StreamClient.gesturesKey) private var gesturesOn = true
    /// This device's switch for Larger Picture (docs/larger-picture-plan.md): off unless turned on,
    /// read by the stream screen, never sent.
    @AppStorage(StreamClient.largerPictureKey) private var largerPicture = false
    @AppStorage(StreamClient.hideBarKey) private var hideBar = false
    @AppStorage(StreamClient.autoQualityKey) private var autoQuality = true
    @AppStorage(StreamClient.matchScreenKey) private var matchScreen = false
    @AppStorage(StreamClient.quicKey) private var quic = false
    @AppStorage(StreamClient.handoffKey) private var handoff = true
    @AppStorage(PillBar.key) private var pillBar = false
    @AppStorage(StreamClient.wideColorKey) private var wideColor = false
    @AppStorage(StreamClient.privateModeKey) private var privateMode = StreamClient.PrivateMode.off.rawValue
    @State private var savingPassword = false
    @State private var appLanguage: String = {
        guard let list = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              UserDefaults.standard.object(forKey: "RCL.appLanguage") != nil, let first = list.first else { return "" }
        return String(first.prefix(2))
    }()
    @State private var languageChanged = false

    /// "" follows the device; "es" or "en" sets RCL's own (AppleLanguages, read at launch).
    private func setAppLanguage(_ code: String) {
        appLanguage = code
        languageChanged = true
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            UserDefaults.standard.removeObject(forKey: "RCL.appLanguage")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
            UserDefaults.standard.set(code, forKey: "RCL.appLanguage")
        }
    }
    @AppStorage(BarItems.slimKey) private var slimBar = false
    @AppStorage(BarItems.hiddenKey) private var barHiddenRaw = ""
    /// Which of the panel's tabs shows; kept, so the panel opens where it was left.
    @AppStorage("RCL.settingsTab") private var tab = SettingsTab.picture.rawValue
    enum SettingsTab: String, CaseIterable, Identifiable {
        case picture, device, files, privacy
        var id: String { rawValue }
        func title(device: String) -> String {
            switch self { case .picture: String(localized: "Picture"); case .device: device; case .files: String(localized: "Files"); case .privacy: String(localized: "Privacy") }
        }
    }
    @State private var passwordSaved = false
    @AppStorage(StreamClient.compactControlsKey) private var compactControls = true
    @AppStorage(StreamClient.magnifierLevelKey) private var magnifierLevel = 0.0
    @AppStorage(StreamClient.magnifierKey) private var magnifierOn = false
    @AppStorage(StreamClient.macSoundKey) private var macSound = true
    /// Send Files… and Send Photos… (StreamClient+Files).
    @State private var importingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    /// Get Files from ‹Mac›… (GetFromMacView).
    @State private var gettingFiles = false
    /// Whether the switch is offered here, the stream screen's say (`largerPictureOffered`): only on an
    /// iPhone without a hinge whose picture it makes larger.
    @Environment(\.largerPictureOffered) private var offersLargerPicture
    /// This device's switch for the clipboard (docs/clipboard-plan.md): on unless turned off, read by
    /// StreamClient+Clipboard at each decision; a change subscribes or stops at once.
    @AppStorage(StreamClient.clipboardKey) private var clipboardOn = true
    /// VoiceOver is on: it keeps three-finger swipes and taps for itself, so the This iPad group says
    /// its rows do the gestures instead.
    @State private var voiceOver = HostSettingsPanel.voiceOverRunning

    private var mac: String { client.macName.isEmpty ? String(localized: "the Mac") : client.macName }
    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    /// DEBUG `-SillSettingsEnd 1`: the rows start scrolled to their end, so a photo of a short
    /// screen shows the last groups (Direct Wireless, Away from home, This iPad, Take the Tour).
    private static var startsAtEnd: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "SillSettingsEnd")
        #else
        return false
        #endif
    }
    /// DEBUG `-SillSettingsScroll gestures`: the rows start scrolled to the This iPad group, so a
    /// photo of a short screen shows its switch and rows, which the footnote under them pushes out
    /// of `-SillSettingsEnd`'s view.
    private static var startsAtGestures: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "SillSettingsScroll") == "gestures"
        #else
        return false
        #endif
    }
    private static let gesturesGroupID = "thisDevice"
    /// `UIAccessibility.isVoiceOverRunning`; DEBUG `-SillVoiceOver 1` says it is, for the harness's
    /// photos of the group's VoiceOver footnote.
    static var voiceOverRunning: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SillVoiceOver") { return true }
        #endif
        return UIAccessibility.isVoiceOverRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            // The rows at their own height when they fit, a scroll view in the room left when not.
            ViewThatFits(in: .vertical) {
                middle
                ScrollViewReader { reader in
                    ScrollView { middle }
                        .scrollIndicatorsFlash(onAppear: true)
                        .scrollBounceBehavior(.basedOnSize)
                        .defaultScrollAnchor(Self.startsAtEnd ? .bottom : .top)
                        .onAppear { if Self.startsAtGestures { reader.scrollTo(Self.gesturesGroupID, anchor: .top) } }
                }
            }
            foot
        }
        .padding(14)
        .rclGlass(in: Self.shape, tint: 0.8)
        .overlay(Self.shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.65), radius: 30, x: 0, y: 24)
        .tint(Palette.accent)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        // VoiceOver stays inside while it is open, the escape gesture closes it, and focus starts
        // on the Mac's name.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        // Esc on a hardware keyboard closes it, with priority over the text and focus systems, as the
        // tour's and the pairing overlay's do: SwiftUI's `.cancelAction` shortcut on Done (kept for
        // ⌘.) does not ask for priority (docs/hardware-keyboard-plan.md §1).
        .background(EscapeKey(action: close))
        .onAppear { headerFocused = true }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            client.sendFiles(urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                return (url, scoped ? { url.stopAccessingSecurityScopedResource() } : nil)
            })
        }
        .sheet(isPresented: $gettingFiles) { GetFromMacView(client: client) }
        .sheet(isPresented: $savingPassword) {
            if let key = client.passwordKey {
                MacPasswordSheet(mac: client.macName.isEmpty ? String(localized: "the Mac") : client.macName, key: key) { passwordSaved = true }
            }
        }
        .onAppear {
            #if DEBUG
            // Harness: `-SillGetFromMac 1` opens Get from Mac with the panel (`-SillSettings 1`).
            if UserDefaults.standard.bool(forKey: "SillGetFromMac") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { gettingFiles = true } }
            #endif
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items {
                Task {
                    guard let picked = try? await item.loadTransferable(type: PickedFile.self) else { return }
                    client.sendFiles([(picked.url, { try? FileManager.default.removeItem(at: picked.url.deletingLastPathComponent()) })])
                }
            }
        }
        // A refused change: the control has already gone back to the Mac's value, and the reason
        // is in the footer or the note. The haptic is a no-op on an iPad.
        .sensoryFeedback(.warning, trigger: client.settingsRefusals)
        .onChange(of: client.settingsRefusals) { _, _ in
            AccessibilityNotification.Announcement(String(localized: "\(mac) kept its setting")).post()
        }
        .onChange(of: client.settingsProblem) { _, problem in
            if let problem { AccessibilityNotification.Announcement(problem).post() }
        }
        .task(id: client.connectedAt) {
            olderMac = false
            let elapsed = client.connectedAt.map { Date().timeIntervalSince($0) } ?? 0
            if elapsed < 2 { try? await Task.sleep(for: .seconds(2 - elapsed)) }
            if !Task.isCancelled { olderMac = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            powerState += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification).receive(on: RunLoop.main)) { _ in
            voiceOver = Self.voiceOverRunning
        }
    }

    // MARK: Header and foot (pinned)

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.macName.isEmpty ? String(localized: "Mac") : client.macName)
                    .font(.geist(.headline))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headerFocused)
                if let state = client.settings.host {
                    VStack(alignment: .leading, spacing: 1) {
                        // Wraps rather than cutting the bitrate off at larger text sizes; each
                        // value keeps its unit (no-break spaces), and a wrap falls after a "·".
                        // It ends in how this device's connection reaches the Mac, the connect
                        // screen's word; "Direct" is the old "Connected directly" line.
                        Text(Self.readout(state.stream, route: client.route))
                            .fixedSize(horizontal: false, vertical: true)
                        // Its own line: beside the numbers it never fit the panel's width, and it
                        // is what confirms the Virtual Display switch took effect.
                        if state.stream?.onVirtualDisplay == true {
                            Text("On the virtual display")
                        }
                        // From afar, how, with the round trip (it needs no clock agreement between
                        // the two devices, unlike frame age); the readout above then ends in the
                        // bitrate. Wraps like the readout (larger text on the outer display cut it
                        // off), after a "·" as the readout does, and never inside the route: its
                        // spaces are no-break ones, as on the Mac's card (at xxLarge on the outer
                        // display it read "Connected through" / "Tailscale · 48 ms").
                        if let r = remoteRoute {
                            Text("Connected \(r.phrase.replacingOccurrences(of: " ", with: "\u{00A0}"))\u{00A0}· \(Self.rttText(client.linkStats))")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Away from home (docs/remote-bundle-plan.md §5.8): which quality this
                        // connection's Mac runs for it, from the Mac's word. Its own line, wrapping
                        // like the readout; the quality kept whole.
                        if let line = AwayCopy.headerLine(state.away) {
                            Text(line.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.geist(.footnote).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spokenReadout(state.stream, route: client.route, remote: remoteRoute,
                                                           rttMs: client.linkStats?.rtt?.median)
                                        + (AwayCopy.headerLine(state.away)?.spoken ?? ""))
                }
            }
            Spacer(minLength: 8)
            // A 44 pt tall tap area (the word alone is about 42×22) without moving the header: the
            // padding and the shape sit inside the label, which is what the button hit-tests, and
            // the layout takes them back outside.
            Button(action: close) {
                Text("Done")
                    .padding(.vertical, 11)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .padding(.vertical, -11)
            .padding(.horizontal, -4)
            .font(.geist(.body, .semibold))
            // ⌘. (and Esc where SwiftUI gets it first); Esc itself is the panel's EscapeKey.
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    /// Disconnect, in Leave's old place of honour: the bar's last slot is Settings now.
    private var foot: some View {
        Button(action: { client.disconnect() }) {
            // The header already names the Mac: when a long name leaves no room, "Disconnect"
            // alone says enough (a truncated "Disconnect from…ah's MacBook Pro" read badly).
            ViewThatFits(in: .horizontal) {
                Label("Disconnect from \(mac)", systemImage: "xmark.circle").lineLimit(1)
                Label("Disconnect", systemImage: "xmark.circle").lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.control))
        .accessibilityLabel("Disconnect from \(mac)")
        .padding(.top, 10)
    }

    // MARK: Middle (scrolls when short)

    /// The tabs over the rows: the Mac's picture, this device, files and privacy.
    private var tabPicker: some View {
        Picker("Section", selection: $tab) {
            ForEach(SettingsTab.allCases) { Text($0.title(device: device)).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var middle: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch SettingsTab(rawValue: tab) ?? .picture {
            case .picture: pictureTab
            case .device:
                thisDevice
                tour
            case .files: filesTab
            case .privacy: privacyTab
            }
        }
    }

    @ViewBuilder private var pictureTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let state = client.settings.host, let shown = client.settings.displayed {
                if state.softwareEncoder {
                    // Neither a restart nor a return is promised: hosts before 2026-09-25 keep the
                    // software encoder until they relaunch, newer ones go back by themselves.
                    Callout(text: String(localized: "\(mac)’s hardware encoder is busy or not responding, so for now streams run at up to 60 fps at Standard."))
                }
                if let relay = state.relay {
                    // Tailscale relays carry far less than a direct path: say why it's slow and what helps.
                    Callout(text: String(localized: "Tailscale is carrying this connection through its relay (\(relay.uppercased())), not directly, so it's slower. A direct path usually comes back on its own; if not, try another network (a phone's hotspot), or on the router let UDP through or turn on UPnP."))
                }
                if let problem = client.settingsProblem {
                    Callout(text: problem)
                }
                // The link cannot carry the quality (the Mac's own judgement, docs/remote-bundle-plan.md
                // §6.7): what it recommends, with a button that picks it. From an older Mac, which
                // judges nothing, the round-trip test away from home as before.
                if let callout = AwayCopy.callout(link: state.link, away: state.away, mac: mac) {
                    Callout(text: callout.text, button: callout.button.map { b in
                        Callout.Action(title: b.title, spoken: b.spoken) { client.changeSettings(b.change) }
                    })
                } else if AwayCopy.showsRttCallout(away: state.away, remote: remoteRoute != nil, slowLink: client.slowLink) {
                    Callout(text: String(localized: "The picture is arriving slowly from \(mac). Choose Low quality or Standard resolution."))
                }
                streamRows(shown)
                Footnote(text: streamFooter)
                // Which quality these rows set, away from home or at home.
                if let note = AwayCopy.footnote(state.away, mac: mac, remoteAccessOn: client.macInfo?.remoteAccess == true) {
                    Footnote(text: note, top: 0)
                }
                // As in the Mac's Settings › Streaming: its own group, the Mac's name for it, and
                // what it trades away.
                Rows {
                    Toggle(isOn: binding(shown.prioritizeSpeed) { HostSettingsChange(prioritizeSpeed: $0) }) {
                        RowTitle(title: String(localized: "Prioritize Encoding Speed"), since: client.settings.pendingSince(.prioritizeSpeed))
                    }
                    .rowFrame()
                }
                Footnote(text: String(localized: "Lower latency when \(mac) is busy, at a softer picture."))
                Rows {
                    let unavailable = !state.virtualDisplayAvailable && !shown.virtualDisplay
                    Toggle(isOn: binding(shown.virtualDisplay) { HostSettingsChange(virtualDisplay: $0) }) {
                        RowTitle(title: String(localized: "Virtual Display"), since: client.settings.pendingSince(.virtualDisplay))
                    }
                    // Off and impossible on this host: disabled, the reason under it. On, it can
                    // always be turned off, as from the Mac's own menu.
                    .disabled(unavailable)
                    .accessibilityHint(state.virtualDisplayNote ?? "")
                    .rowFrame()
                }
                if let note = state.virtualDisplayNote {
                    Footnote(text: note, warning: true)
                } else {
                    Footnote(text: String(localized: "The window you pick moves onto an invisible display on \(mac) while it streams, so it keeps updating when covered."))
                }
                Footnote(text: String(localized: "Applies to every device streaming from \(mac). The stream restarts for a moment."))
                // Direct Wireless Connection: how devices reach the Mac, not how it streams; after the
                // closing footer, whose "the stream restarts" is not true of it, and last, the least
                // changed row with the longest footer (the compact halves' 259 pt shows the rest
                // first). Disabled only away from home (the Mac refuses it from a remote connection):
                // off from a directly connected device is allowed, as on the Mac, and its consequence
                // is written beside it. No row for a host without it.
                if let direct = shown.directWireless {
                    Rows {
                        Toggle(isOn: binding(direct) { HostSettingsChange(directWireless: $0) }) {
                            RowTitle(title: String(localized: "Direct Wireless Connection"), since: client.settings.pendingSince(.directWireless))
                        }
                        // A warning about turning it off, so only while the switch shows on.
                        .accessibilityHint(client.connectedDirectly && direct ? String(localized: "Turning this off disconnects this \(device).") : "")
                        // From afar the Mac refuses it anyway: how devices near the Mac reach it is
                        // theirs and the Mac's to change.
                        .disabled(remoteRoute != nil)
                        .rowFrame()
                    }
                    Footnote(text: remoteRoute != nil ? String(localized: "Change this on \(mac), or from a device near it.") : directFooter(on: direct))
                }
                if !state.persistent {
                    Footnote(text: "SillHost keeps these until it quits.")
                }
                awayFromHome
            } else if olderMac {
                Label("Update RCL on \(mac) to change these from here.", systemImage: "arrow.down.circle")
                    .font(.geist(.body))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Palette.muted)
                    Text("Loading settings…")
                }
                .font(.geist(.footnote))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
    }

    /// The last group: this device's, not the Mac's, so after everything about the Mac, and there
    /// whatever the Mac is (while settings load, and for a Mac without them). It sends nothing. It
    /// comes after This iPad's gestures, under their footnote, so it needs no space of its own above
    /// it even while the Mac's settings load.
    @ViewBuilder private var tour: some View {
        Rows {
            Button(action: pictureOnly) {
                Text("Picture Only")
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the picture alone, filling the screen.")
            .rowFrame()
        }
        Footnote(text: Self.pictureOnlyFooter)
        Rows {
            Button(action: takeTour) {
                Text(TourPolicy.takeTourTitle)
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(TourPolicy.takeTourHint(device: device))
            .rowFrame()
        }
        Footnote(text: TourPolicy.takeTourFootnote(device: device))
    }

    /// Most-changed first, so the compact halves' 259 pt shows Quality, Resolution and Frame Rate
    /// before anything scrolls.
    private func streamRows(_ shown: StreamSettings) -> some View {
        Rows {
            AdaptiveRow(title: String(localized: "Quality"), since: client.settings.pendingSince(.bitrate)) {
                Picker("Quality", selection: binding(shown.bitrate) { HostSettingsChange(bitrate: $0) }) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if QualityPreset(rawValue: shown.bitrate) == nil {
                        // Set by hand on the Mac: shown, never offered (the Mac's menu does the same).
                        Text(QualityPreset.title(forBitrate: shown.bitrate)).tag(shown.bitrate)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()     // one line; the row stacks instead when it does not fit beside the title
            }
            RowDivider()
            AdaptiveRow(title: String(localized: "Resolution"), since: client.settings.pendingSince(.captureScale)) {
                Picker("Resolution", selection: binding(shown.captureScale) { HostSettingsChange(captureScale: $0) }) {
                    Text("Retina").tag(2.0)
                    Text("Standard").tag(1.0)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            AdaptiveRow(title: String(localized: "Frame Rate"), since: client.settings.pendingSince(.maxFPS)) {
                // A Mac-held value such as 90 selects no segment, as on the Mac.
                Picker("Frame Rate", selection: binding(shown.maxFPS) { HostSettingsChange(maxFPS: $0) }) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    /// Shows the value the panel displays; moving the control sends that one field. Nothing else
    /// ever sends (not `onChange(of:)`, not a state arriving).
    private func binding<V>(_ value: V, _ change: @escaping (V) -> HostSettingsChange) -> Binding<V> {
        Binding(get: { value }, set: { client.changeSettings(change($0)) })
    }

    // MARK: Away from home

    /// This connection's way in from afar, when it is one.
    private var remoteRoute: RemoteRoute? { client.remoteRoute }

    /// The Mac's last group (docs/remote-access-plan.md §7.11, docs/home-pairing-plan.md §7.6):
    /// whether this device is paired with the Mac and can reach it away from home, from the Mac's
    /// kind 18 (DiscoveryPolicy.awayFromHome). "Paired" for a saved Mac, however it paired; Pair This
    /// iPad… only in an unpaired session: at home over TLS on a Mac that lets any device in (it pairs
    /// at this session's own door, Remote Access on or not), or over a plain door with Remote Access
    /// on (through the remote door, as before). None from an older Mac (no kind 18 on this
    /// connection).
    @ViewBuilder private var awayFromHome: some View {
        if let info = client.macInfo {
            Text("Away from home")
                .font(.geist(.footnote, .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            switch DiscoveryPolicy.awayFromHome(saved: client.macInfoSaved, remoteSession: remoteRoute != nil,
                                                remoteAccess: info.remoteAccess, tlsAtHome: client.sessionAtHomeOverTLS) {
            case .paired(let reach):
                Rows {
                    Label("Paired", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.text)
                        .rowFrame()
                }
                switch reach {
                case .connected:
                    if let r = remoteRoute { Footnote(text: String(localized: "Connected \(r.phrase).")) }
                case .reaches:
                    Footnote(text: String(localized: "Away from home, RCL reaches \(mac) \(Self.reach(info))."))
                case .turnOnRemoteAccess:
                    Footnote(text: Self.turnOnRemoteAccess(mac))
                }
            case .pairThisDevice(let atHome):
                Rows {
                    Button(action: pairThisDevice) {
                        Text("Pair This \(device)…")
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowFrame()
                }
                Footnote(text: atHome ? DiscoveryPolicy.HomeCopy.pairThisDeviceAtHome(mac: mac, device: device)
                                      : String(localized: "Pair once to reach \(mac) through your VPN or the internet. \(mac) shows a code; scan it with this \(device)."))
            case .turnOnRemoteAccess:
                Footnote(text: Self.turnOnRemoteAccess(mac))
            }
        }
    }

    /// With Remote Access off on the Mac: how to reach it away from home.
    static func turnOnRemoteAccess(_ mac: String) -> String {
        String(localized: "To reach \(mac) away from home, turn on Remote Access in RCL’s Settings on the Mac.")
    }

    // MARK: This device

    /// This device's own group, after the Mac's: on an iPhone its switch for Larger Picture, then Share
    /// Clipboard while the Mac shares its clipboard, with Paste on ‹Mac› (the system's Paste control)
    /// under it while on, then its switch for three-finger gestures, and what each does when the Mac
    /// takes them (Take the Tour follows it). After the Mac's rows because it is the least changed, and
    /// the compact halves' 259 pt show the Mac's rows first. The switches reach nothing on the Mac but
    /// the clipboard's, which subscribes or stops; a gesture row, activated by VoiceOver, Voice Control
    /// or Switch Control, does its gesture on the Mac as three fingers would (`sendGesture`: the switch,
    /// the Mac's `gestures`, the Desktop first while a window streams).
    @ViewBuilder private var thisDevice: some View {
        Color.clear.frame(height: 0).id(Self.gesturesGroupID)
        // The app's language (RCL), whatever this device's is: AppleLanguages, which iOS reads when the
        // app opens, so a change shows the next time RCL opens.
        Rows {
            HStack {
                Text("Language").foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Picker(selection: Binding(get: { appLanguage }, set: { setAppLanguage($0) })) {
                    Text("Same as This Device").tag("")
                    Text(verbatim: "Español").tag("es")
                    Text(verbatim: String(localized: "English")).tag("en")
                } label: { Text("Language") }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .rowFrame()
        }
        Footnote(text: languageChanged ? String(localized: "RCL changes language the next time it opens: close it from the app switcher and open it again.")
                                       : String(localized: "RCL can use another language than this device."))
        if UIDevice.current.userInterfaceIdiom == .phone {
            Rows {
                Toggle(isOn: $compactControls) {
                    Text("Compact Controls").foregroundStyle(Palette.text)
                }
                .rowFrame()
                if compactControls {
                    RowDivider()
                    HStack {
                        Text("Magnifier").foregroundStyle(Palette.text)
                        Spacer(minLength: 8)
                        Picker(selection: $magnifierLevel) {
                            Text("Fill").tag(0.0)
                            ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { level in
                                Text(level.formatted(.number.precision(.fractionLength(0...1))) + "×").tag(level)
                            }
                            if magnifierLevel != 0, ![1.5, 2.0, 2.5, 3.0, 4.0].contains(magnifierLevel) {
                                Text(magnifierLevel.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(magnifierLevel)
                            }
                        } label: { Text("Magnifier") }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .rowFrame()
                }
            }
            Footnote(text: String(localized: "Held upright: one row of buttons at the bottom, a taller picture with the magnifier, and the keys just above the keyboard. Your windows are in Apps. The magnifier’s level: Fill makes the picture as tall as its pane; a pinch on the picture sets a level too. Off: the thumbnails and the key row as before."))
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            Rows {
                Toggle(isOn: $magnifierOn) {
                    Text("Magnifier").foregroundStyle(Palette.text)
                }
                .rowFrame()
                if magnifierOn {
                    RowDivider()
                    HStack {
                        Text("Level").foregroundStyle(Palette.text)
                        Spacer(minLength: 8)
                        Picker(selection: $magnifierLevel) {
                            Text("Fill").tag(0.0)
                            ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { level in
                                Text(level.formatted(.number.precision(.fractionLength(0...1))) + "×").tag(level)
                            }
                            if magnifierLevel != 0, ![1.5, 2.0, 2.5, 3.0, 4.0].contains(magnifierLevel) {
                                Text(magnifierLevel.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(magnifierLevel)
                            }
                        } label: { Text("Magnifier") }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .rowFrame()
                }
            }
            Footnote(text: String(localized: "The picture magnified around the pointer, following it as it moves; the bar’s magnifier button turns it on and off. A pinch on the picture sets the level too."))
        }
        if offersLargerPicture, !(compactControls && UIDevice.current.userInterfaceIdiom == .phone) {
            Rows {
                Toggle(isOn: $largerPicture) {
                    Text("Larger Picture").foregroundStyle(Palette.text)
                }
                .rowFrame()
            }
            Footnote(text: Self.largerPictureFooter)
        }
        Rows {
            Toggle(isOn: $autoQuality) {
                Text("Automatic Quality").foregroundStyle(Palette.text)
            }
            .rowFrame()
        }
        Footnote(text: String(localized: "When the connection can’t keep up, this \(device) lowers \(mac)’s quality by itself, and brings it back to what you picked once the picture runs smoothly again."))
        Rows {
            Toggle(isOn: $matchScreen) {
                Text("Match This Screen").foregroundStyle(Palette.text)
            }
            .rowFrame()
        }
        Footnote(text: String(localized: "\(mac) sends no more pixels than this \(device) shows: less data and less work for the Mac, the same sharpness here. Off: the Mac’s Retina or Standard, as set above."))
        Rows {
            Toggle(isOn: $wideColor) {
                Text("Wide Color (P3, 10-bit)").foregroundStyle(Palette.text)
            }
            .rowFrame()
        }
        Footnote(text: String(localized: "Colors as the Mac shows them, with smooth gradients, for checking a design’s color. Uses a little more of the connection; the Mac’s software encoder ignores it."))
        Rows {
            Toggle(isOn: $quic) {
                Text("QUIC Away from Home (Test)").foregroundStyle(Palette.text)
            }
            .rowFrame()
        }
        Footnote(text: String(localized: "Away from home, connects over QUIC first, which copes better with a weak signal, and over the usual connection if QUIC doesn’t answer. Applies to the next connection."))
        Rows {
            Toggle(isOn: $handoff) {
                Text("Handoff").foregroundStyle(Palette.text)
            }
            .rowFrame()
        }
        Footnote(text: String(localized: "This session shows up in the Dock of your other iPhone or iPad. Take it there and it carries on with the same window, and this \(device) lets go."))
        Rows {
            Toggle(isOn: $pillBar) {
                Text("Floating Pill").foregroundStyle(Palette.text)
            }
            .rowFrame()
        }
        Footnote(text: String(localized: "Held sideways, the picture fills the screen and a small pill floats in a corner. Tap it, or rest the pointer on it, and it widens into the whole bar; its app’s name lists the windows. Drag the pill to any corner."))
        if !pillBar {
            Rows {
                Toggle(isOn: $hideBar) {
                    Text("Hide the Bar").foregroundStyle(Palette.text)
                }
                .rowFrame()
            }
            Footnote(text: Self.hideBarFooter)
        }
        // The landscape bar's buttons and the Slim Bar (BarItems), an iPad's.
        if UIDevice.current.userInterfaceIdiom == .pad {
            Rows {
                Toggle(isOn: $slimBar) {
                    Text("Slim Bar").foregroundStyle(Palette.text)
                }
                .rowFrame()
                ForEach(BarItems.Item.allCases) { item in
                    RowDivider()
                    Toggle(isOn: Binding(
                        get: { !BarItems.hidden(barHiddenRaw).contains(item) },
                        set: { show in
                            var h = BarItems.hidden(barHiddenRaw)
                            if show { h.remove(item) } else { h.insert(item) }
                            barHiddenRaw = BarItems.raw(h)
                        })) {
                        Label(item.title, systemImage: item.symbol).foregroundStyle(Palette.text)
                    }
                    .rowFrame()
                }
            }
            Footnote(text: String(localized: "Slim Bar: half as tall, symbols only, for a bar you leave showing. The buttons you turn off are under More."))
        }
        if (client.hostAudio ?? 0) >= MacAudio.generation {
            Rows {
                Toggle(isOn: $macSound) {
                    Text("Mac Sound").foregroundStyle(Palette.text)
                }
                .rowFrame()
                .onChange(of: macSound) { _, _ in client.updateAudioWanted() }
            }
            Footnote(text: String(localized: "Plays the sound of what streams from \(mac) on this \(device): a window’s app, or everything on the Desktop. \(mac) keeps playing it too."))
        }
        Rows {
            Toggle(isOn: $gesturesOn) {
                Text("Three-Finger Gestures").foregroundStyle(Palette.text)
            }
            .rowFrame()
            if gesturesOn, macTakesGestures {
                ForEach(Self.gestureRows, id: \.gesture) { row in
                    RowDivider()
                    GestureRow(symbol: row.symbol, gesture: row.gesture, action: row.action, does: row.does) {
                        _ = client.sendGesture($0, fingers: 3)
                    }
                }
            }
        }
        Footnote(text: gesturesFooter)
    }

    /// Files: getting and sending them, the screenshot, and the clipboard.
    @ViewBuilder private var filesTab: some View {
        if client.macTakesFiles {
            Rows {
                if client.macListsFiles {
                    Button { gettingFiles = true } label: {
                        Text("Get Files from \(mac)…")
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowFrame()
                    RowDivider()
                }
                Button { importingFiles = true } label: {
                    Text("Send Files to \(mac)…")
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .rowFrame()
                RowDivider()
                PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                    Text("Send Photos and Videos…")
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .rowFrame()
                if client.macTakesScreenshots {
                    RowDivider()
                    Button { client.takeScreenshot() } label: {
                        Text("Screenshot to Photos")
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .rowFrame()
                }
            }
            Footnote(text: String(localized: "They go to \(mac)’s Downloads folder. You can also drop files on the picture, or share them to RCL from any app. What \(mac) sends this \(device) is in Files, On My \(device), RCL."))
        }
        // The clipboard (docs/clipboard-plan.md): only while the Mac says it shares it.
        if ClipboardPolicy.hostTakes(client.hostClipboard) {
            Rows {
                Toggle(isOn: $clipboardOn) {
                    Text(ClipboardPolicy.Copy.switchTitle).foregroundStyle(Palette.text)
                }
                .rowFrame()
                .onChange(of: clipboardOn) { _, _ in client.clipboardSwitchChanged() }
                if clipboardOn {
                    RowDivider()
                    ClipboardPasteRow(client: client, title: ClipboardPolicy.Copy.rowTitle(mac: mac))
                }
            }
            if clipboardOn, let note = client.clipboardNote {
                Footnote(text: note.text, warning: note.warning, top: 6)
                    .padding(.bottom, -6)
                    .accessibilityHidden(true)      // announced as it came
            }
            Footnote(text: ClipboardPolicy.Copy.footnote(on: clipboardOn, mac: mac, device: device))
        }
    }

    /// Privacy: Private Mode and the quick password.
    @ViewBuilder private var privacyTab: some View {
        // Private Mode (kind 50) and the quick password (RCL).
        if client.macTakesPrivacy {
            Rows {
                AdaptiveRow(title: String(localized: "Private Mode"), since: nil) {
                    Picker("Private Mode", selection: $privateMode) {
                        ForEach(StreamClient.PrivateMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .onChange(of: privateMode) { _, _ in client.sendPrivacyIfNeeded() }
            Footnote(text: String(localized: "\(mac)’s own screens go black while this \(device) works on it, so nobody near it sees what you do. ")
                     + (client.macPrivacyOn ? String(localized: "On now.") : String(localized: "Off now.")) + String(localized: " They show again when you disconnect."))
        }
        Rows {
            Button { if client.offersMacPassword { savingPassword = true } } label: {
                Text(client.hasMacPassword || passwordSaved ? String(localized: "Change \(mac)’s Password…") : String(localized: "Save \(mac)’s Password…"))
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rowFrame()
            if client.hasMacPassword || passwordSaved {
                RowDivider()
                Button {
                    if let key = client.passwordKey { MacPassword.forget(for: key) }
                    passwordSaved = false
                } label: {
                    Text("Forget the Password")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .rowFrame()
            }
        }
        Footnote(text: String(localized: "When \(mac) is locked, RCL types it for you after Face ID. It stays on this \(device) only, in the Keychain."))
    }

    /// The Mac's window list said it takes the gestures (`WindowList.gestures`).
    private var macTakesGestures: Bool { (client.hostGestures ?? 0) >= TrackpadGesture.generation }

    /// Under Larger Picture's switch: that it is a window's picture (the Desktop, which Aa never
    /// resizes, keeps the thumbnails: `PhonePortraitLayout.largerPicture(switchOn:streaming:)`), what
    /// it gives up, where windows come from instead, that the Mac fits a window to the taller picture
    /// once Aa sets its text size (or on the virtual display), and that a change applies as the panel
    /// closes (StreamScreen's `largerPictureHeld`).
    /// Under Picture Only: what goes and how to come back (StreamScreen's `pictureOnly`).
    static let pictureOnlyFooter = String(localized: "The picture fills the screen, with no bar, keys or trackpad, for watching a video or reading. Tap the handle at the top to bring them back.")

    /// Under Hide the Bar's switch: where the bar goes and how it comes back (StreamScreen's `barShown`).
    static let hideBarFooter = String(localized: "Held sideways, the picture takes the bar’s place. Tap or pull down the handle at the top to bring the bar over the picture; it goes back up by itself, or swipe it up.")

    static let largerPictureFooter = String(localized: "Held upright, a window’s picture takes the place of the window thumbnails and reaches down to where the keyboard comes up. The Desktop keeps the thumbnails. Switch windows with Apps: tap an open app again for its next window. To fill the taller picture with a window, set its text size with Aa. A change applies when you close Settings.")

    /// What each gesture does on the Mac, and what the row does as an accessibility action: its one
    /// gesture, or, for the Spaces, one action each way (natural direction: a swipe left brings the
    /// Space on the right). The pinch opens Launchpad on macOS 14 and 15, from the same key.
    private static let gestureRows: [(symbol: String, gesture: String, action: String, does: [GestureRow.Action])] = [
        ("arrow.up", String(localized: "Swipe Up"), String(localized: "Mission Control"), [GestureRow.Action(name: String(localized: "Mission Control"), gesture: .swipeUp)]),
        ("arrow.down", String(localized: "Swipe Down"), String(localized: "App Exposé"), [GestureRow.Action(name: String(localized: "App Exposé"), gesture: .swipeDown)]),
        ("arrow.left.and.right", String(localized: "Swipe Left or Right"), "Spaces", [GestureRow.Action(name: String(localized: "Space on the Right"), gesture: .swipeLeft),
                                                                   GestureRow.Action(name: String(localized: "Space on the Left"), gesture: .swipeRight)]),
        ("arrow.down.right.and.arrow.up.left", "Pinch", "Apps", [GestureRow.Action(name: String(localized: "Apps"), gesture: .pinch)]),
        ("arrow.up.left.and.arrow.down.right", "Spread", String(localized: "Show Desktop"), [GestureRow.Action(name: String(localized: "Show Desktop"), gesture: .spread)]),
    ]

    /// Under the switch: where the gestures go and what they do, or why nothing happens.
    private var gesturesFooter: String {
        guard gesturesOn else { return String(localized: "Three-finger strokes do nothing while this is off.") }
        guard macTakesGestures else { return String(localized: "Update RCL on \(mac) to use these.") }
        // VoiceOver keeps three-finger swipes and taps for itself, and no touch of them reaches Sill.
        var text = voiceOver ? String(localized: "VoiceOver keeps three-finger gestures for itself, so the rows above do them on \(mac) instead.")
            : String(localized: "Three fingers on the trackpad or over the stream.")
        text += String(localized: " While a window streams, a gesture shows the Desktop first, and the opposite gesture closes what one opened. \(mac) does these with its own keyboard shortcuts: one turned off in its Keyboard settings does nothing.")
        if device == "iPad" { text += String(localized: " Four-finger swipes and a Magic Keyboard trackpad’s gestures stay with iPadOS.") }
        return text
    }

    /// "through Tailscale (mac-mini.tail1234.ts.net)": the first VPN or internet address the Mac
    /// gave; otherwise "through your VPN or the internet".
    static func reach(_ info: MacInfo) -> String {
        guard let a = info.addresses.first(where: { $0.kind == MacAddress.vpn || $0.kind == MacAddress.internet }) else {
            return String(localized: "through your VPN or the internet")
        }
        if a.kind == MacAddress.internet { return String(localized: "over the internet (\(a.host))") }
        let name = a.via.isEmpty || a.via.hasPrefix("VPN (") ? "your VPN" : a.via
        return String(localized: "through \(name) (\(a.host))")
    }

    // MARK: Copy

    /// Under the Mac's name: what actually runs, which confirms a change took effect and shows
    /// what the software encoder caps, then how this device's connection reaches the Mac
    /// ("… · 15 Mbps · Wi-Fi"; StreamClient.route), when its path says (never on a remote session:
    /// its route line says how instead). Whether it runs on the virtual display is a line of its
    /// own (see `header`). A no-break space before each "·" keeps it with the value before it, so a
    /// wrap at larger text never starts a line with one.
    static func readout(_ stream: RunningStream?, route: DiscoveryPolicy.Method? = nil) -> String {
        let values = stream.map { ["\($0.width)×\($0.height)", "\($0.fps)\u{00A0}fps", "\($0.mbps)\u{00A0}Mbps"] } ?? [String(localized: "Not streaming")]
        return (values + [route?.word].compactMap { $0 }).joined(separator: String(localized: "\u{00A0}· "))
    }

    /// "48 ms", the last second's median round trip; "–" for a second without a pong.
    static func rttText(_ stats: StreamClient.LinkStats?) -> String {
        stats?.rtt.map { "\($0.median)\u{00A0}ms" } ?? "–"
    }

    /// The readout as VoiceOver says it, ending in how this device reaches the Mac: its link, or
    /// from afar the remote route with the round trip, which wins (a remote session has no link
    /// word; see `header`).
    static func spokenReadout(_ stream: RunningStream?, route: DiscoveryPolicy.Method? = nil, remote: RemoteRoute? = nil,
                              rttMs: Int? = nil) -> String {
        var link = route.map { ", " + spoken($0) } ?? ""
        if let remote {
            link = String(localized: ", connected \(remote.phrase)") + (rttMs.map { String(localized: ", \($0) millisecond round trip") } ?? "")
        }
        guard let s = stream else { return String(localized: "Not streaming") + link }
        return String(localized: "Streaming \(s.width) by \(s.height), \(s.fps) frames per second, \(s.mbps) megabits per second")
            + (s.onVirtualDisplay ? String(localized: ", on the virtual display") : "") + link
    }

    /// The route as VoiceOver says it: a sentence's end rather than the bare word.
    private static func spoken(_ route: DiscoveryPolicy.Method) -> String {
        switch route {
        case .wired: return String(localized: "connected by cable")
        case .wifi: return String(localized: "connected over Wi-Fi")
        case .direct: return String(localized: "connected directly")
        }
    }

    /// "iPhone" or "iPad", for copy about this device.
    private var device: String { UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad" }

    /// Under the Direct Wireless Connection row: what it does and costs, and, while the switch shows
    /// on and this device is connected over it, what turning it off does to this device: the Mac
    /// disconnects every device on peer-to-peer Wi-Fi once its listener has changed (1.5 s), and a
    /// device still connected directly shares no network the Mac is listed on (one that does moves
    /// to it by itself), so it cannot come back until it does. Once the switch shows off (turned
    /// off here or on the Mac, with this connection still up for that moment) the warning is moot.
    private func directFooter(on: Bool) -> String {
        var text = String(localized: "Lets devices reach \(mac) without a shared Wi\u{2011}Fi network, the way AirDrop does. While it’s on, streaming over Wi\u{2011}Fi can stutter.")
        if on, client.connectedDirectly { text += String(localized: " This \(device) is connected directly: turning this off disconnects it.") }
        return text
    }

    /// Under the stream rows: what Quality counts and what its top presets need (the Mac's
    /// Settings › Streaming says the same). A frame rate limit above what this screen shows changes
    /// nothing for it, which is worth saying on a 60 Hz device; away from home this device asks
    /// for 60 fps.
    private var streamFooter: String {
        _ = powerState
        var text = String(localized: "Quality is per 60 fps; a 120 fps stream gets twice as much. ") + QualityPreset.fastLinkNote
        let away = client.awayCapsFrameRate
        let wanted = StreamClient.wantedFPS(remote: away)
        guard wanted < 120 else { return text }
        if away, StreamClient.wantedFPS() > wanted {
            text += String(localized: " Away from home, this \(device) asks for \(wanted) fps, which halves the data your Mac sends.")
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled, StreamClient.screenMaximumFPS() >= 120 {
            text += String(localized: " Low Power Mode holds this \(device) to \(wanted) fps.")
        } else {
            text += String(localized: " This \(device) shows up to \(wanted) fps.")
        }
        return text
    }
}

// MARK: - Rows

/// An inset group of rows on the drawer's control colour.
private struct Rows<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.control))
    }
}

/// A row's title with the pending spinner beside it.
private struct RowTitle: View {
    let title: String
    let since: Double?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Palette.text)
            PendingSpinner(since: since)
        }
    }
}

/// A title with its control beside it, or under it when larger text leaves no room beside.
private struct AdaptiveRow<Control: View>: View {
    let title: String
    let since: Double?
    let control: Control
    /// A text size change while the panel is open left the menu picker measured at the old size
    /// (seen going from accessibility sizes back to Large: the row stayed stacked), so the row is
    /// rebuilt, and measured afresh, whenever it changes.
    @Environment(\.dynamicTypeSize) private var typeSize
    init(title: String, since: Double?, @ViewBuilder control: () -> Control) {
        self.title = title; self.since = since; self.control = control()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 8)
                control
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                control
            }
            .padding(.vertical, 8)
        }
        .id(typeSize)
        .rowFrame()
    }
    /// The control carries the same title for VoiceOver, so this one is not read twice.
    private var label: some View { RowTitle(title: title, since: since).accessibilityHidden(true) }
}

/// One gesture and what it does on the Mac: the words side by side when they fit and stacked when
/// larger text leaves no room, never cut off; one VoiceOver element ("Swipe Up, Mission Control").
/// A touch does nothing here; activated by VoiceOver, Voice Control or Switch Control (which cannot
/// make three-finger strokes, or keep them) it does its gesture: a button for one, a named action
/// each way for the Spaces.
private struct GestureRow: View {
    struct Action { let name: String; let gesture: TrackpadGestures.Gesture }
    let symbol: String
    let gesture: String
    let action: String
    let does: [Action]
    let perform: (TrackpadGestures.Gesture) -> Void
    /// Measured afresh when the text size changes, as `AdaptiveRow` is.
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if let only = does.first, does.count == 1 {
            row.accessibilityAddTraits(.isButton).accessibilityAction { perform(only.gesture) }
        } else {
            row.accessibilityActions {
                ForEach(does, id: \.name) { item in Button(item.name) { perform(item.gesture) } }
            }
        }
    }
    private var row: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                icon
                Text(gesture).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text(action).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture).foregroundStyle(Palette.text)
                    Text(action).foregroundStyle(Palette.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        }
        .id(typeSize)
        .rowFrame()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(gesture), \(action)")
    }
    private var icon: some View {
        Image(systemName: symbol)
            .foregroundStyle(Palette.muted)
            .frame(width: 24)
            .accessibilityHidden(true)
    }
}

/// "Paste on ‹Mac›" with the system's Paste button (ClipboardPasteButton): beside it when they fit,
/// under it when larger text leaves no room, as `AdaptiveRow` does. The title is the row's words for
/// VoiceOver; the button reads "Paste" with its hint.
private struct ClipboardPasteRow: View {
    @ObservedObject var client: StreamClient
    let title: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                ClipboardPasteButton(client: client)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                ClipboardPasteButton(client: client)
            }
            .padding(.vertical, 8)
        }
        .id(typeSize)
        .rowFrame()
    }
}

/// A hairline between rows, inset like the system's.
private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 14)
    }
}

/// A small spinner shown only once a pick has waited 300 ms for its answer: a quick Mac never
/// makes it flicker.
private struct PendingSpinner: View {
    let since: Double?
    @State private var shown = false
    var body: some View {
        ZStack {
            if shown { ProgressView().controlSize(.small).tint(Palette.muted) }
        }
        .frame(width: shown ? nil : 0)
        .accessibilityHidden(true)
        .task(id: since) {
            shown = false
            guard let since else { return }
            let wait = 0.3 - (ProcessInfo.processInfo.systemUptime - since)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { shown = true }
        }
    }
}

/// A group's footer: small, muted, from the leading edge; orange with a warning sign for a problem.
/// `top` 0 continues the footer above it.
private struct Footnote: View {
    let text: String
    var warning = false
    var top: CGFloat = 6
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if warning { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
            Text(text)
        }
        .font(.geist(.footnote))
        .foregroundStyle(warning ? Color.orange : Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, top)
        .padding(.bottom, 12)
    }
}

/// Something to know before touching anything: the Mac did not answer, its hardware encoder is
/// down, or the link cannot carry the quality, with a button that picks what the Mac recommends
/// (at least 44 pt tall, like the rows). Above the groups.
private struct Callout: View {
    struct Action {
        let title: String
        let spoken: String
        let perform: () -> Void
    }
    let text: String
    var button: Action? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(text).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let button {
                Button(action: button.perform) {
                    Text(button.title)
                        .font(.geist(.footnote, .semibold))
                        .foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.control))
                .accessibilityLabel(button.spoken)
            }
        }
        .font(.geist(.footnote))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
        .accessibilityElement(children: .contain)
        .padding(.bottom, 10)
    }
}

private extension View {
    /// A row inside a group: at least 44 pt tall, inset 14 pt.
    func rowFrame() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14)
    }
}

/// Whether the Settings panel offers Larger Picture (This iPhone's first switch): the stream screen's
/// say, true on an iPhone without a hinge whose picture Larger Picture makes larger
/// (`PhonePortraitLayout.offersLargerPicture`); false everywhere else, the iPhone Duo and an iPad
/// included, and on an iPhone that Display Zoom makes 320 pt wide.
private struct LargerPictureOfferedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var largerPictureOffered: Bool {
        get { self[LargerPictureOfferedKey.self] }
        set { self[LargerPictureOfferedKey.self] = newValue }
    }
}

/// A photo or video from the Photos picker, as a file: copied out of the picker's (which goes when
/// the import returns) into a folder of its own, removed once sent.
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            guard let copy = StreamClient.temporaryCopy(of: received.file, named: nil) else { throw CocoaError(.fileReadUnknown) }
            return PickedFile(url: copy)
        }
    }
}
