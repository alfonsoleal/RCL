import SwiftUI
import StreamProtocol

/// The Pill (RCL), in place of the bar held sideways: the Mac's picture keeps the whole screen, and a
/// small Liquid Glass capsule floats over one corner with what streams and how the link is doing. A
/// tap, or the pointer resting on it, widens it in place into the whole bar as a capsule (StreamScreen's
/// TopBar with `pill`): Apps, the windows as a vertical menu, Menus, the person's buttons, the status
/// and Settings; it narrows again as the bar hides. It goes where the person drags it, to the nearest
/// corner, and stays there. This device's alone, never sent.
enum PillBar {
    static let key = "RCL.pillBar"
    static let cornerKey = "RCL.pillCorner"
    /// The notch's buttons below the screen's top edge (TopBar's `topInset`).
    static let notchInset: CGFloat = 22

    /// Where the pill sits: a corner, or the middle of the top edge (as a notch, flush with the edge)
    /// or of the bottom.
    enum Corner: String {
        case topLeading, top, topTrailing, bottomLeading, bottom, bottomTrailing
        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .top: .top
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottom: .bottom
            case .bottomTrailing: .bottomTrailing
            }
        }
        var top: Bool { self == .topLeading || self == .top || self == .topTrailing }
        var unitPoint: UnitPoint {
            switch self {
            case .topLeading: .topLeading
            case .top: .top
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottom: .bottom
            case .bottomTrailing: .bottomTrailing
            }
        }
        /// Where along the edge a point at `x` of a width `w` lands: a third each.
        var x: CGFloat {
            switch self {
            case .topLeading, .bottomLeading: 0
            case .top, .bottom: 0.5
            case .topTrailing, .bottomTrailing: 1
            }
        }
        static func at(x: CGFloat, top: Bool) -> Corner {
            if x < 1 / 3 { return top ? .topLeading : .bottomLeading }
            if x > 2 / 3 { return top ? .topTrailing : .bottomTrailing }
            return top ? .top : .bottom
        }
        /// The notch: the top's middle, flush with the screen's edge.
        var notch: Bool { self == .top }
    }

    static func corner(_ raw: String) -> Corner { Corner(rawValue: raw) ?? .topTrailing }

    /// The pill's outline: a capsule, or as a notch square at the top and round below.
    static func shape(_ corner: Corner) -> AnyShape {
        corner.notch
            ? AnyShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0),
                                              style: .continuous))
            : AnyShape(Capsule(style: .continuous))
    }
}

/// The narrow pill and the wide one share one frame (`morph`), so one grows into the other.
extension View {
    @ViewBuilder func pillMorph(_ space: Namespace.ID?) -> some View {
        if let space { matchedGeometryEffect(id: "pill", in: space) } else { self }
    }
}

struct FloatingPill: View {
    @ObservedObject var client: StreamClient
    var space: Namespace.ID? = nil
    let expand: () -> Void
    @AppStorage(PillBar.cornerKey) private var cornerRaw = PillBar.Corner.topTrailing.rawValue

    var body: some View {
        let now = PillBar.current(client)
        Button(action: expand) {
            HStack(spacing: 8) {
                PillBar.icon(now)
                // At most 22 characters, so the pill stays as small as its name.
                Text(now.name.count > 22 ? String(now.name.prefix(21)) + "…" : now.name)
                    .font(.geist(13, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Circle().fill(StatusPill.color(StatusPill.health(client))).frame(width: 7, height: 7)
            }
            .padding(.leading, 9).padding(.trailing, 14)
            .frame(height: 40)
            .padding(.top, PillBar.corner(cornerRaw).notch ? 4 : 0)
            .contentShape(PillBar.shape(PillBar.corner(cornerRaw)))
        }
        .buttonStyle(.plain)
        .background(Color.clear.rclGlass(in: PillBar.shape(PillBar.corner(cornerRaw)), tint: 0.45).pillMorph(space))
        .onContinuousHover { phase in if case .active = phase { expand() } }
        .accessibilityLabel(String(localized: "\(now.name). Show the bar"))
    }
}

extension PillBar {
    /// What streams: the window's app, the Desktop, or the Mac's name.
    static func current(_ client: StreamClient) -> (icon: UIImage?, name: String, symbol: String?) {
        switch client.active {
        case .window(let id):
            if let w = client.windows.first(where: { $0.id == id }) { return (client.icons[w.bundleID], w.appName, nil) }
        case .desktop:
            return (nil, String(localized: "Desktop"), "desktopcomputer")
        default: break
        }
        return (nil, client.macName, "macbook")
    }

    @ViewBuilder static func icon(_ now: (icon: UIImage?, name: String, symbol: String?)) -> some View {
        if let symbol = now.symbol {
            Image(systemName: symbol).font(.geist(14, .medium)).foregroundStyle(Palette.text).frame(width: 22, height: 22)
        } else {
            AppIcon(image: now.icon, name: now.name, size: 22, radius: 5, fontSize: 9)
        }
    }
}

/// The pill, narrow or wide, in its corner; a drag of the narrow one carries it to the nearest corner.
struct PillPlacement<Content: View>: View {
    var draggable: Bool
    @ViewBuilder var content: Content
    @AppStorage(PillBar.cornerKey) private var cornerRaw = PillBar.Corner.topTrailing.rawValue
    @State private var drag: CGSize = .zero

    private var corner: PillBar.Corner { PillBar.corner(cornerRaw) }

    /// The room the pill moves in, for its drag's nearest corner; read off a background, so nothing
    /// but the pill itself takes a touch.
    @State private var room: CGSize = .zero

    var body: some View {
        content
            .offset(drag)
            .gesture(move(in: room), including: draggable ? .all : .subviews)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            // The notch sits flush with the top edge, over the safe area; the rest 14 pt in.
            .padding(corner.notch ? EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14) : EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            .background(GeometryReader { geo in Color.clear.onAppear { room = geo.size }.onChange(of: geo.size) { _, s in room = s } })
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: cornerRaw)
            .ignoresSafeArea(edges: corner.notch ? .top : [])
    }

    private func move(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { drag = $0.translation }
            .onEnded { g in
                let x = corner.x * size.width + g.predictedEndTranslation.width
                let y = (corner.top ? 0 : size.height) + g.predictedEndTranslation.height
                cornerRaw = PillBar.Corner.at(x: x / max(size.width, 1), top: y < size.height / 2).rawValue
                drag = .zero
            }
    }
}

/// The wide pill's windows (RCL), a vertical menu hanging from what streams, in place of the strip:
/// the Desktop, each window with its picture and app, and Open App. A tap streams it; holding one
/// offers what holding a thumbnail does (its window's buttons, its app's Hide and Quit) and moving it
/// up or down the order, which is the strip's own (persisted per Mac).
struct WindowListMenu: View {
    @ObservedObject var client: StreamClient
    let close: () -> Void
    let openApps: () -> Void

    var body: some View {
        let windows = client.orderedWindows
        ScrollView {
            VStack(spacing: 2) {
                row(title: String(localized: "Desktop"), subtitle: nil, image: nil, symbol: "desktopcomputer", app: nil,
                    active: client.active == .desktop) { pick(.desktop) }
                Divider().overlay(Palette.barLabel.opacity(0.2)).padding(.vertical, 4)
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, w in
                    row(title: w.title.isEmpty ? w.appName : w.title, subtitle: w.title.isEmpty ? nil : w.appName,
                        image: client.thumbnails[w.id], symbol: nil, app: w, active: client.active == .window(w.id)) { pick(.window(w.id)) }
                        .contextMenu {
                            Button(String(localized: "Close Window"), systemImage: "xmark") { client.command(.close, window: w.id) }
                            Button(String(localized: "Minimize"), systemImage: "minus") { client.command(.minimize, window: w.id) }
                            Button(String(localized: "Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right") {
                                client.command(.fullScreen, window: w.id)
                            }
                            Divider()
                            if index > 0 {
                                Button(String(localized: "Move Up"), systemImage: "arrow.up") { move(w.id, to: index - 1) }
                            }
                            if index < windows.count - 1 {
                                Button(String(localized: "Move Down"), systemImage: "arrow.down") { move(w.id, to: index + 1) }
                            }
                            Divider()
                            Button(String(localized: "Hide \(w.appName)"), systemImage: "eye.slash") {
                                client.appCommand("hide", bundleID: w.bundleID)
                            }
                            Button(String(localized: "Quit \(w.appName)"), systemImage: "xmark.circle", role: .destructive) {
                                client.appCommand("quit", bundleID: w.bundleID)
                            }
                        }
                }
                Divider().overlay(Palette.barLabel.opacity(0.2)).padding(.vertical, 4)
                row(title: String(localized: "Open App…"), subtitle: nil, image: nil, symbol: "plus", app: nil, active: false, action: openApps)
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 340)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pick(_ source: StreamSource) {
        client.select(source)
        close()
    }

    private func move(_ id: UInt32, to index: Int) {
        client.moveWindow(id, to: index)
        client.persistWindowOrder()
    }

    private func row(title: String, subtitle: String?, image: UIImage?, symbol: String?, app: WindowInfo?, active: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.control)
                        .frame(width: 72, height: 45)
                        .overlay {
                            if let image {
                                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).padding(3)
                            } else if let symbol {
                                Image(systemName: symbol).font(.geist(18)).foregroundStyle(Palette.barLabel)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(active ? Palette.accent : .clear, lineWidth: 2)
                        }
                    if let app {
                        AppIcon(image: client.icons[app.bundleID], name: app.appName, size: 20, radius: 5, fontSize: 8)
                            .offset(x: 6, y: 5)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let subtitle {
                        Text(subtitle).font(.geist(11, .medium)).foregroundStyle(Palette.barLabel).lineLimit(1)
                    }
                    Text(title).font(.geist(14, .medium)).foregroundStyle(active ? Palette.accent : Palette.text).lineLimit(1)
                }
                Spacer(minLength: 0)
                if active { Image(systemName: "checkmark").font(.geist(13, .semibold)).foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
