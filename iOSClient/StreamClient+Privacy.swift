import Foundation
import StreamProtocol

// Private Mode and the quick password (RCL), this device's side. Main thread.
extension StreamClient {
    /// When this device asks the Mac to blank its own screens: never, away from home only (a session
    /// through the remote door), or always.
    enum PrivateMode: String, CaseIterable, Identifiable {
        case off, away, always
        var id: String { rawValue }
        var title: String {
            switch self { case .off: String(localized: "Off"); case .away: String(localized: "Away from Home"); case .always: String(localized: "Always") }
        }
    }

    static let privateModeKey = "RCL.privateMode"
    /// Match the Screen (Viewport.pixelWidth): the Mac sends no more pixels than this device shows.
    static let matchScreenKey = "RCL.matchScreen"
    /// Wide Color: the picture in Display P3 at 10 bits (Viewport.wideColor).
    static let wideColorKey = "RCL.wideColor"
    /// QUIC away from home (RemoteConnector): an experiment, off until turned on.
    static let quicKey = "RCL.quic"

    var privateMode: PrivateMode {
        PrivateMode(rawValue: UserDefaults.standard.string(forKey: Self.privateModeKey) ?? "") ?? .off
    }

    /// The Mac takes Private Mode.
    var macTakesPrivacy: Bool { (hostPrivacy ?? 0) >= PrivacyMode.generation }

    /// Tells the Mac this device's wish once per connection and whenever it changes (the setting, a
    /// move home that ends a remote session's "away").
    func sendPrivacyIfNeeded() {
        guard macTakesPrivacy, let c = connection else { return }
        let on: Bool = {
            switch privateMode {
            case .off: return false
            case .always: return true
            case .away: return remoteRoute != nil
            }
        }()
        let id = ObjectIdentifier(c)
        if let sent = privacySent, sent.connection == id, sent.on == on { return }
        // Nothing to undo on a connection that never asked.
        if privacySent?.connection != id, !on { privacySent = (id, false); return }
        privacySent = (id, on)
        send(.privacy, payload: Wire.encode(PrivacyMode(on: on)))
    }

    // MARK: The quick password

    /// Which Mac a saved password belongs to: its Mac ID, and only in a session pinned to that saved
    /// Mac's key (at home, or through the remote door, which pins always). Never a name, nor a Mac
    /// on an open door: a Mac ID is public and a name is the host's to say, so a look-alike could
    /// otherwise claim either, say it is locked and be typed the password (security review, A2).
    var passwordKey: String? {
        guard let s = session, let id = s.macID else { return nil }
        switch s.route {
        case .remote: return id
        default:
            if case .saved? = s.home { return id }
            return nil
        }
    }

    /// The quick password can be offered here: a pinned session with a saved Mac.
    var offersMacPassword: Bool { passwordKey != nil }

    var hasMacPassword: Bool { passwordKey.map { MacPassword.has(for: $0) } ?? false }

    /// Face ID (or the passcode), then the password typed on the Mac's lock screen and Return.
    func unlockMac() {
        let mac = macName.isEmpty ? String(localized: "the Mac") : macName
        guard let key = passwordKey else { return }
        let from = connection
        Task { @MainActor in
            guard let password = await MacPassword.read(for: key, reason: String(localized: "Unlock \(mac)")) else { return }
            // Face ID took a moment: typed only if the same session's Mac still says it is locked, so
            // a Mac unlocked meanwhile never gets the password and Return in whatever is in front.
            guard connection === from, macLocked, passwordKey == key else { return }
            noteAction()
            sendInput(.text(password))
            KeyChord.press(0x28, with: []).forEach(sendInput)
        }
    }
}
