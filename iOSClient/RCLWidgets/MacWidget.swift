import WidgetKit
import SwiftUI

/// What the app shares with its extensions (RCLShared.swift, the app group's defaults): the paired
/// Macs and the last one used. Read only; a widget never reaches a Mac itself.
struct SharedMacs {
    struct Mac: Decodable, Hashable {
        let macID: String
        let name: String
    }

    static let group = "group.me.alfonso.rcl"

    static func load() -> (macs: [Mac], last: Mac?) {
        let d = UserDefaults(suiteName: group)
        let json = d?.string(forKey: "savedMacs") ?? "[]"
        let macs = (try? JSONDecoder().decode([Mac].self, from: Data(json.utf8))) ?? []
        let lastInfo = d?.dictionary(forKey: "lastMac")
        let last = (lastInfo?["id"] as? String).flatMap { id in
            macs.first { $0.macID == id } ?? (lastInfo?["name"] as? String).map { Mac(macID: id, name: $0) }
        }
        return (macs, last ?? macs.first)
    }

    static func connect(_ mac: Mac?) -> URL {
        var c = URLComponents(string: "rcl://connect")!
        if let mac { c.queryItems = [URLQueryItem(name: "mac", value: mac.macID)] }
        return c.url!
    }
}

struct MacEntry: TimelineEntry {
    let date: Date
    let macs: [SharedMacs.Mac]
    let last: SharedMacs.Mac?
}

struct MacProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacEntry {
        MacEntry(date: .now, macs: [.init(macID: "", name: "MacBook Pro")], last: .init(macID: "", name: "MacBook Pro"))
    }

    func getSnapshot(in context: Context, completion: @escaping (MacEntry) -> Void) {
        completion(entry())
    }

    /// The paired Macs change only in the app, which reloads the widgets then; a refresh a day is plenty.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(24 * 3600))))
    }

    private func entry() -> MacEntry {
        let shared = SharedMacs.load()
        return MacEntry(date: .now, macs: shared.macs, last: shared.last)
    }
}

/// Agencia 85's green, RCL's one accent (StreamScreen's Palette).
private let accent = Color(red: 0, green: 0xD7 / 255.0, blue: 0x49 / 255.0)

struct MacWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MacEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "macbook").font(.title3)
            }
            .widgetURL(SharedMacs.connect(entry.last))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("RCL", systemImage: "macbook").font(.headline)
                Text(entry.last?.name ?? String(localized: "Pair a Mac")).font(.caption).lineLimit(1)
            }
            .widgetURL(SharedMacs.connect(entry.last))
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "macbook").font(.system(size: 28, weight: .medium)).foregroundStyle(accent)
            Spacer(minLength: 0)
            Text(entry.last?.name ?? String(localized: "No Mac yet"))
                .font(.system(.headline, design: .rounded)).foregroundStyle(.white).lineLimit(2)
            Text(entry.last == nil ? String(localized: "Pair one in RCL") : String(localized: "Tap to connect"))
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(SharedMacs.connect(entry.last))
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("RCL", systemImage: "macbook").font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(accent)
                if entry.macs.isEmpty {
                    Text("Pair a Mac in RCL to connect from here.").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                ForEach(entry.macs.prefix(3), id: \.self) { mac in
                    Link(destination: SharedMacs.connect(mac)) {
                        HStack(spacing: 6) {
                            Circle().fill(mac == entry.last ? accent : .white.opacity(0.3)).frame(width: 6, height: 6)
                            Text(mac.name).font(.subheadline).foregroundStyle(.white).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                action("Desktop", "desktopcomputer", URL(string: "rcl://desktop")!)
                action("Private", "eye.slash", URL(string: "rcl://private?on=1")!)
            }
            .frame(width: 104)
        }
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, _ url: URL) -> some View {
        Link(destination: url) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1)))
        }
    }
}

struct MacWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RCLMac", provider: MacProvider()) { entry in
            MacWidgetView(entry: entry)
                .containerBackground(Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1A / 255.0), for: .widget)
        }
        .configurationDisplayName("Your Mac")
        .description("Connect to your Mac, show its Desktop or turn on Private Mode.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// Control Center, the Lock Screen and the Action button (iOS 18): RCL connects to the last Mac.
@available(iOSApplicationExtension 18.0, *)
struct ConnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "RCLConnect") {
            ControlWidgetButton(action: OpenRCLIntent()) {
                Label("Connect to Mac", systemImage: "macbook")
            }
        }
        .displayName("Connect to Mac")
        .description("Opens RCL and connects to the last Mac.")
    }
}

import AppIntents

/// The control's action: RCL opens on its link, which connects to the last Mac.
@available(iOSApplicationExtension 18.0, *)
struct OpenRCLIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Mac"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(SharedMacs.connect(nil)))
    }
}
