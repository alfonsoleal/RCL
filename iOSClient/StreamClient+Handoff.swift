import Foundation
import StreamProtocol

// Handoff (RCL): a session on the iPhone shows up in the iPad's Dock (and the other way round), and
// taking it there connects to the same Mac and carries on with what streams. The Mac then ends the
// other device's session (goodbye "handoff"), so the device in the person's hand drives it. Same
// Apple Account, Bluetooth and Handoff on, as for any app; the activity carries only which Mac.
extension StreamClient {
    static let handoffActivity = "me.alfonso.rcl.session"
    static let handoffKey = "RCL.handoff"
    /// How long a continued session waits for its Mac's row before dialing it through the remote door.
    private static let handoffRowWait: TimeInterval = 3
    private static let handoffGiveUp: TimeInterval = 20

    var handoffOn: Bool { UserDefaults.standard.object(forKey: Self.handoffKey) as? Bool ?? true }

    /// What the activity carries while a session runs; nil when there is none to offer.
    var handoffInfo: [String: String]? {
        guard connected, handoffOn, let s = session else { return nil }
        var info = ["mac": macName]
        if let id = s.macID { info["macID"] = id }
        if let name = s.bonjourName { info["bonjour"] = name }
        return info.count > 1 ? info : nil
    }

    /// The other device's session, taken here: its Mac's row as soon as the browser lists it, else
    /// (a saved Mac) its remote door after a few seconds.
    func continueSession(_ info: [AnyHashable: Any]?) {
        guard handoffOn, let info else { return }
        connectSaved(macID: info["macID"] as? String, bonjour: info["bonjour"] as? String, takeOver: true)
    }

    /// A saved Mac by its ID (or its Bonjour name), as Handoff, Siri and the widgets ask for it: its
    /// row as soon as the browser lists it, else its remote door after a few seconds. `takeOver`:
    /// the Mac hands this device the session another one had. Already connected to it: nothing.
    func connectSaved(macID: String?, bonjour: String? = nil, takeOver: Bool = false) {
        guard macID != nil || bonjour != nil else { return }
        if connected, (macID != nil && session?.macID == macID) || (bonjour != nil && session?.bonjourName == bonjour) { return }
        if connected { disconnect() }
        handoffTakeOver.withLock { $0 = takeOver }
        handoffWanted = HandoffWanted(macID: macID, bonjour: bonjour, since: Date())
        status = takeOver ? String(localized: "Continuing on this \(Self.deviceWord)…")
                          : String(localized: "Connecting to \(macID.map(displayName) ?? bonjour ?? "the Mac")…")
        tryHandoff()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffRowWait + 0.1) { [weak self] in self?.tryHandoff() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffGiveUp) { [weak self] in
            guard let self, self.handoffWanted != nil else { return }
            self.endHandoff()
            if !self.connected { self.status = String(localized: "Couldn’t continue the session. Tap your Mac to connect.") }
        }
    }

    /// Called as the rows change too (`macs`).
    func tryHandoff() {
        guard let want = handoffWanted, !connected, connection == nil else { return }
        if let row = macs.first(where: { $0.route != .remote && (($0.macID != nil && $0.macID == want.macID)
                                                                  || (want.bonjour != nil && $0.name == want.bonjour)) }) {
            connect(to: row)
            return
        }
        if let id = want.macID, Date().timeIntervalSince(want.since) >= Self.handoffRowWait, savedMac(id) != nil {
            dialSaved(id, why: .tap)
        }
    }

    /// The session is here (its first window list), or it never came: later hellos are plain again.
    func endHandoff() {
        handoffWanted = nil
        handoffTakeOver.withLock { $0 = false }
    }
}

struct HandoffWanted {
    var macID: String?
    var bonjour: String?
    var since: Date
}
