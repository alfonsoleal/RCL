import SwiftUI
import StreamProtocol

/// Shortcuts (RCL): the Mac's keyboard shortcuts as buttons, the person's own pick of them, for a
/// device without a keyboard at hand (an iPhone, an iPad on the couch). Each goes out as a keyboard
/// sends it (KeyChord.press). The pick and its order are this device's, never sent.
struct MacShortcut: Codable, Hashable, Identifiable {
    var title: String
    /// The key's HID usage (keyboard page).
    var usage: UInt16
    /// KeyModifiers' raw value.
    var modifiers: UInt64

    var id: String { "\(modifiers)-\(usage)" }

    /// "⇧⌘4": the modifiers in the Mac's order, then the key.
    var glyphs: String {
        let m = KeyModifiers(rawValue: modifiers)
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + MacShortcuts.keyName(usage)
    }
}

enum MacShortcuts {
    static let storeKey = "RCL.shortcuts"

    private static func letter(_ c: Character) -> UInt16 { UInt16(c.asciiValue! - 97) + 0x04 }   // a…z, checked at the call
    private static let cmd = KeyModifiers.command.rawValue
    private static let shiftCmd = (KeyModifiers.command.union(.shift)).rawValue
    private static let ctrlCmd = (KeyModifiers.command.union(.control)).rawValue
    private static let optCmd = (KeyModifiers.command.union(.option)).rawValue

    /// What can be picked, in the order the editor lists it.
    static let catalog: [MacShortcut] = [
        MacShortcut(title: String(localized: "Undo"), usage: letter("z"), modifiers: cmd),
        MacShortcut(title: String(localized: "Redo"), usage: letter("z"), modifiers: shiftCmd),
        MacShortcut(title: String(localized: "Copy"), usage: letter("c"), modifiers: cmd),
        MacShortcut(title: String(localized: "Paste"), usage: letter("v"), modifiers: cmd),
        MacShortcut(title: String(localized: "Cut"), usage: letter("x"), modifiers: cmd),
        MacShortcut(title: String(localized: "Select All"), usage: letter("a"), modifiers: cmd),
        MacShortcut(title: String(localized: "Save"), usage: letter("s"), modifiers: cmd),
        MacShortcut(title: String(localized: "Find"), usage: letter("f"), modifiers: cmd),
        MacShortcut(title: String(localized: "New"), usage: letter("n"), modifiers: cmd),
        MacShortcut(title: String(localized: "New Tab"), usage: letter("t"), modifiers: cmd),
        MacShortcut(title: String(localized: "Close Window"), usage: letter("w"), modifiers: cmd),
        MacShortcut(title: String(localized: "Quit App"), usage: letter("q"), modifiers: cmd),
        MacShortcut(title: String(localized: "Print"), usage: letter("p"), modifiers: cmd),
        MacShortcut(title: String(localized: "Bold"), usage: letter("b"), modifiers: cmd),
        MacShortcut(title: String(localized: "Italic"), usage: letter("i"), modifiers: cmd),
        MacShortcut(title: String(localized: "Duplicate"), usage: letter("d"), modifiers: cmd),
        MacShortcut(title: String(localized: "Settings"), usage: 0x36, modifiers: cmd),
        MacShortcut(title: String(localized: "Hide App"), usage: letter("h"), modifiers: cmd),
        MacShortcut(title: String(localized: "Minimize"), usage: letter("m"), modifiers: cmd),
        MacShortcut(title: String(localized: "Full Screen"), usage: letter("f"), modifiers: ctrlCmd),
        MacShortcut(title: String(localized: "Spotlight"), usage: 0x2C, modifiers: cmd),
        // macOS's "Turn Dock hiding on/off": a hidden Dock stays shown until the next tap. ⌃F3 ("Move
        // focus to the Dock") did nothing from an iPad (Alfonso, 2026-10-24): macOS keeps an F key's
        // shortcut with fn, which a device's keys never carry.
        MacShortcut(title: String(localized: "Dock On/Off"), usage: letter("d"), modifiers: optCmd),
        MacShortcut(title: String(localized: "Emoji"), usage: 0x2C, modifiers: ctrlCmd),
        MacShortcut(title: String(localized: "Screenshot"), usage: 0x20, modifiers: shiftCmd),
        MacShortcut(title: String(localized: "Screenshot Area"), usage: 0x21, modifiers: shiftCmd),
        MacShortcut(title: String(localized: "Screenshot Tools"), usage: 0x22, modifiers: shiftCmd),
        MacShortcut(title: String(localized: "Force Quit"), usage: 0x29, modifiers: optCmd),
        MacShortcut(title: String(localized: "Lock Screen"), usage: letter("q"), modifiers: ctrlCmd),
        MacShortcut(title: String(localized: "Reload"), usage: letter("r"), modifiers: cmd),
        MacShortcut(title: String(localized: "Zoom In"), usage: 0x2E, modifiers: cmd),
        MacShortcut(title: String(localized: "Zoom Out"), usage: 0x2D, modifiers: cmd),
    ]

    /// What a fresh install shows.
    static let defaults: [MacShortcut] = Array(catalog.prefix(8))

    /// The person's pick, in its order.
    static func load() -> [MacShortcut] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([MacShortcut].self, from: data) else { return defaults }
        // The first Show Dock (⌃F3), which never worked, becomes Dock On/Off.
        let dock = catalog.first { $0.usage == letter("d") && $0.modifiers == optCmd }!
        return list.map { $0.usage == 0x3C && $0.modifiers == KeyModifiers.control.rawValue ? dock : $0 }
    }

    static func save(_ list: [MacShortcut]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: storeKey)
    }

    /// The key a custom shortcut is made of: a letter or a digit as typed.
    static func usage(for character: Character) -> UInt16? {
        let c = Character(character.lowercased())
        if let a = c.asciiValue, (97...122).contains(a) { return UInt16(a - 97) + 0x04 }
        if let d = c.wholeNumberValue, c.isASCII { return d == 0 ? 0x27 : UInt16(0x1E + d - 1) }
        return nil
    }

    static func keyName(_ usage: UInt16) -> String {
        switch usage {
        case 0x04...0x1D: return String(UnicodeScalar(UInt8(usage - 0x04) + 65))
        case 0x1E...0x26: return String(usage - 0x1E + 1)
        case 0x27: return "0"
        case 0x2C: return String(localized: "Space")
        case 0x29: return String(localized: "Esc")
        case 0x36: return ","
        case 0x2E: return "+"
        case 0x2D: return "−"
        case 0x3A...0x45: return String(localized: "F\(usage - 0x3A + 1)")
        default: return "?"
        }
    }

    static func send(_ s: MacShortcut, to client: StreamClient) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        KeyChord.press(s.usage, with: KeyModifiers(rawValue: s.modifiers)).forEach(client.sendInput)
    }
}

/// The person's shortcuts as a grid of buttons; each sends at a tap. `onEdit` opens the editor.
struct ShortcutGrid: View {
    @ObservedObject var client: StreamClient
    var columns = 2
    var onEdit: () -> Void
    @State private var list = MacShortcuts.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(list) { s in
                    Button { MacShortcuts.send(s, to: client) } label: {
                        VStack(spacing: 2) {
                            Text(s.title).font(.geist(13, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(s.glyphs).font(.geist(12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.control))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.text)
                    .accessibilityLabel("\(s.title), \(s.glyphs)")
                }
            }
            Button("Edit Shortcuts…", action: onEdit)
                .font(.geist(.footnote, .medium))
                .foregroundStyle(Palette.accent)
        }
        .onAppear { list = MacShortcuts.load() }
    }
}

/// Which shortcuts show and in what order: the catalog with switches, the picked ones to drag into
/// order, and a custom one from a letter or digit and its modifiers.
struct ShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var list = MacShortcuts.load()
    @State private var customTitle = ""
    @State private var customKey = ""
    @State private var cmd = true
    @State private var shift = false
    @State private var opt = false
    @State private var ctrl = false

    var body: some View {
        NavigationStack {
            List {
                Section("Shown") {
                    ForEach(list) { s in
                        HStack { Text(s.title); Spacer(); Text(s.glyphs).foregroundStyle(.secondary) }
                    }
                    .onMove { list.move(fromOffsets: $0, toOffset: $1); MacShortcuts.save(list) }
                    .onDelete { list.remove(atOffsets: $0); MacShortcuts.save(list) }
                }
                Section("Add") {
                    ForEach(MacShortcuts.catalog.filter { c in !list.contains(c) }) { s in
                        Button {
                            list.append(s); MacShortcuts.save(list)
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Palette.accent)
                                Text(s.title).foregroundStyle(Palette.text)
                                Spacer()
                                Text(s.glyphs).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    TextField("Name", text: $customTitle)
                    TextField("Key (a letter or a digit)", text: $customKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("⌘ Command", isOn: $cmd)
                    Toggle("⇧ Shift", isOn: $shift)
                    Toggle("⌥ Option", isOn: $opt)
                    Toggle("⌃ Control", isOn: $ctrl)
                    Button("Add Custom Shortcut") { addCustom() }
                        .disabled(customKey.first.flatMap(MacShortcuts.usage(for:)) == nil)
                } header: {
                    Text("Your Own")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Palette.accent)
    }

    private func addCustom() {
        guard let c = customKey.first, let usage = MacShortcuts.usage(for: c) else { return }
        var m: KeyModifiers = []
        if cmd { m.insert(.command) }
        if shift { m.insert(.shift) }
        if opt { m.insert(.option) }
        if ctrl { m.insert(.control) }
        var s = MacShortcut(title: "", usage: usage, modifiers: m.rawValue)
        s.title = customTitle.isEmpty ? s.glyphs : customTitle
        guard !list.contains(where: { $0.id == s.id }) else { return }
        list.append(s)
        MacShortcuts.save(list)
        customTitle = ""; customKey = ""
    }
}

/// The bars' Shortcuts button (an iPad's): the grid in a popover under it.
struct ShortcutsBarButton: View {
    @ObservedObject var client: StreamClient
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 16
    var iconSize: CGFloat = 22
    var labelled = true
    @State private var showing = false
    @State private var editing = false

    var body: some View {
        BarButton(open: showing, width: width, height: height, radius: radius, accessibilityLabel: String(localized: "Shortcuts"),
                  action: { showing = true }) {
            VStack(spacing: 2) {
                Image(systemName: "command")
                    .font(.geist(iconSize))
                    .foregroundStyle(showing ? Palette.accent : Palette.text)
                if labelled {
                    Text("Shortcuts")
                        .font(.geist(11, .medium))
                        .foregroundStyle(showing ? Palette.accent : Palette.barLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .popover(isPresented: $showing) {
            ShortcutGrid(client: client, columns: 3) { showing = false; editing = true }
                .padding(16)
                .frame(width: 380)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showing) { _, now in client.filesSheetOpen = now || editing }
        .sheet(isPresented: $editing) { ShortcutEditor() }
        .onChange(of: editing) { _, now in client.filesSheetOpen = now || showing }
    }
}
