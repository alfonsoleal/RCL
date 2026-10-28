import SwiftUI
import StreamProtocol

/// The bar's status at a glance (RCL): how the link is doing (a dot, green, yellow or red), the way
/// in (Wi‑Fi, Wired, Tailscale…), and what changes the picture on its own: Automatic Quality having
/// lowered it, Private Mode on. A tap opens Settings, where each is explained.
struct StatusPill: View {
    @ObservedObject var client: StreamClient
    var compact = false
    let action: () -> Void

    enum Health { case good, fair, poor }

    /// Red when the Mac says the link can't carry the quality, yellow while a round trip runs over
    /// 80 ms or Automatic Quality is holding the quality down, green otherwise.
    private var health: Health { Self.health(client) }
    private var color: Color { Self.color(health) }

    static func health(_ client: StreamClient) -> Health {
        if client.settings.host?.link?.isBehind == true { return .poor }
        if client.settings.host?.relay != nil { return .fair }
        if let rtt = client.linkStats?.rtt?.median, rtt > 80 { return .fair }
        if client.autoQuality.ceiling != nil { return .fair }
        return .good
    }

    static func color(_ health: Health) -> Color {
        switch health { case .good: Color(hex: 0x30D158); case .fair: Color(hex: 0xFFD60A); case .poor: Color(hex: 0xFF453A) }
    }

    private var way: String {
        if let remote = client.remoteRoute {
            switch remote {
            case .vpn(let name): return name ?? "VPN"
            case .internet: return String(localized: "Internet")
            case .address: return String(localized: "Address")
            }
        }
        return client.route?.word ?? ""
    }

    private var wayShown: String {
        var shown = way
        if client.settings.host?.relay != nil, !shown.isEmpty { shown += " · " + String(localized: "relay") }
        if client.sessionOverQUIC, !shown.isEmpty { shown += " · QUIC" }
        return shown
    }

    private var spoken: String {
        let h: String = { switch health { case .good: "good"; case .fair: "fair"; case .poor: "poor" } }()
        var parts = [String(localized: "Connection \(h)")]
        if !way.isEmpty { parts.append(way) }
        if client.settings.host?.relay != nil { parts.append(String(localized: "through Tailscale's relay, slower")) }
        if client.autoQuality.ceiling != nil { parts.append(String(localized: "quality lowered automatically")) }
        if client.macPrivacyOn { parts.append(String(localized: "Private Mode on")) }
        if let rtt = client.linkStats?.rtt?.median { parts.append(String(localized: "\(rtt) milliseconds")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                if !compact, !way.isEmpty {
                    Text(wayShown).font(.geist(12, .medium)).foregroundStyle(Palette.text).lineLimit(1)
                }
                if client.autoQuality.ceiling != nil {
                    Image(systemName: "arrow.down.circle").font(.geist(12)).foregroundStyle(Color(hex: 0xFFD60A))
                }
                if client.macPrivacyOn {
                    Image(systemName: "eye.slash.fill").font(.geist(12)).foregroundStyle(Palette.text)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: compact ? 22 : 30)
            .background(Capsule().fill(Palette.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens Settings")
        .animation(.easeOut(duration: 0.2), value: health)
    }
}

// MARK: - Glass (RCL)

extension View {
    /// iPadOS and iOS 26's Liquid Glass behind a bar, a panel or a notice, tinted the bar's colour so
    /// text keeps its contrast over a bright picture; before 26, the bar's solid colour as always.
    @ViewBuilder func rclGlass<S: Shape>(in shape: S, tint opacity: Double = 0.55) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(Palette.bar.opacity(opacity)), in: shape)
        } else {
            self.background(shape.fill(Palette.bar))
        }
    }
}
