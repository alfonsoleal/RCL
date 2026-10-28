import Foundation

/// Whether a device reaches this Mac through Tailscale directly or through one of its relays (DERP),
/// which carry far less and add delay: asked of Tailscale itself (`tailscale status --json`), whose
/// peer list gives each device's current direct address (`CurAddr`), empty while it is relayed, and
/// its relay region (`Relay`). Read-only; nothing is sent anywhere. A Mac without Tailscale, or one
/// whose CLI doesn't answer in 3 s, says nothing.
enum TailscalePath {
    /// The CLI where Tailscale's app and Homebrew put it.
    private static let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                     "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    /// For each of `addresses` (a device's Tailscale address as its connection shows it) that
    /// Tailscale lists: the relay's region while it is relayed, nil while direct. Addresses it doesn't
    /// list are left out. Blocking: call off the main actor.
    static func relays(for addresses: Set<String>) -> [String: String?] {
        guard !addresses.isEmpty, let json = status() else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let peers = root["Peer"] as? [String: [String: Any]] else { return [:] }
        var out: [String: String?] = [:]
        for peer in peers.values {
            let ips = peer["TailscaleIPs"] as? [String] ?? []
            for ip in ips where addresses.contains(ip) {
                let direct = !((peer["CurAddr"] as? String) ?? "").isEmpty
                let relay = (peer["Relay"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                out[ip] = direct ? .some(nil) : .some(relay ?? "derp")
            }
        }
        return out
    }

    private static func status() -> Data? {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? data : nil
    }
}
