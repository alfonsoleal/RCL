import Foundation
import Security
#if canImport(WidgetKit)
import WidgetKit
#endif
import StreamProtocol

/// What RCL shares with its Files extension (MacFiles), which reaches the Mac on its own while RCL
/// isn't running: the paired Macs (the saved list, mirrored into the app group's defaults), where
/// each Mac's home door last answered (an address and port: the extension has no Bonjour browser,
/// and a Mac's own row is only an app's), and a copy of this device's key in a keychain group both
/// can read. The app writes; the extension only reads. Any thread.
///
/// The key is copied, never moved: the app keeps reading the one it always had, so a copy that
/// failed (an entitlement missing from a build) costs the extension its access and nothing else.
enum RCLShared {
    static let appGroup = "group.me.alfonso.rcl"
    /// "TEAMID.me.alfonso.rcl.shared", from Info.plist (`RCLSharedKeychainGroup`, filled in from
    /// $(AppIdentifierPrefix) at build time): the team prefix isn't known to the code otherwise.
    static var keychainGroup: String? { Bundle.main.object(forInfoDictionaryKey: "RCLSharedKeychainGroup") as? String }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static let savedMacsKey = "savedMacs"
    private static let homeKey = "homeDoors"

    // MARK: The paired Macs

    /// The app: the saved list as SavedMacs.encode writes it.
    static func publish(savedMacs json: String) {
        defaults?.set(json, forKey: savedMacsKey)
        reloadWidgets()
    }

    /// The widgets show the paired Macs and the last one: they read again whenever either changes.
    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// The extension: the Macs it may reach (paired, not revoked, a key to pin).
    static func savedMacs() -> [SavedMac] {
        SavedMacs.decode(defaults?.string(forKey: savedMacsKey)).filter { $0.revoked != true && $0.fingerprintData != nil }
    }

    /// The app, at a session at home over TLS: the home door's address and port as that connection
    /// reached it. The newest first, three at most per Mac (Wi-Fi's, the cable's…).
    static func recordHome(macID: String, host: String, port: Int) {
        guard let defaults else { return }
        var all = defaults.dictionary(forKey: homeKey) as? [String: [String]] ?? [:]
        let entry = "\(host)|\(port)"
        all[macID] = Array(([entry] + (all[macID] ?? []).filter { $0 != entry }).prefix(3))
        defaults.set(all, forKey: homeKey)
    }

    /// The extension: where a Mac's home door last answered, newest first, as dial candidates.
    static func homeDoors(macID: String) -> [RemoteDialPolicy.Candidate] {
        let all = defaults?.dictionary(forKey: homeKey) as? [String: [String]] ?? [:]
        return (all[macID] ?? []).compactMap { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let port = Int(parts[1]) else { return nil }
            return RemoteDialPolicy.Candidate(host: parts[0], port: port, kind: MacAddress.lan, via: "Home")
        }
    }

    // MARK: The last Mac (Siri, the widgets)

    private static let lastKey = "lastMac"

    /// The app, as a session with a saved Mac starts: which one, and when, for the widgets.
    static func recordLast(macID: String, name: String) {
        let changed = lastMacID() != macID
        defaults?.set(["id": macID, "name": name, "at": Date().timeIntervalSince1970], forKey: lastKey)
        if changed { reloadWidgets() }
    }

    static func lastMacID() -> String? { (defaults?.dictionary(forKey: lastKey))?["id"] as? String }

    /// The last Mac's name and when it was used.
    static func lastMac() -> (id: String, name: String, at: Date)? {
        guard let d = defaults?.dictionary(forKey: lastKey), let id = d["id"] as? String, let name = d["name"] as? String,
              let at = d["at"] as? Double else { return nil }
        return (id, name, Date(timeIntervalSince1970: at))
    }

    // MARK: The device key

    /// The app: puts a copy of this device's key in the shared keychain group, once. The extension
    /// then finds it with DeviceIdentity as the app does (its only group is the shared one).
    static func shareDeviceKey() {
        guard let group = keychainGroup, !group.contains("$(") else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: DeviceIdentity.tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var shared = base
        shared[kSecAttrAccessGroup as String] = group
        guard SecItemCopyMatching(shared as CFDictionary, nil) == errSecItemNotFound else { return }
        var find = base
        find[kSecReturnRef as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(find as CFDictionary, &item) == errSecSuccess, let item,
              CFGetTypeID(item) == SecKeyGetTypeID(),
              let data = SecKeyCopyExternalRepresentation(item as! SecKey, nil) as Data? else { return }   // type checked
        var add = shared
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrIsPermanent as String] = true
        let status = SecItemAdd(add as CFDictionary, nil)
        print("files: this device's key " + (status == errSecSuccess ? "shared with the Files extension" : "not shared (\(status))"))
    }
}
