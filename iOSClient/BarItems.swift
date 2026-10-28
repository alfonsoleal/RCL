import Foundation

/// The landscape bar's own buttons (RCL), the person's to show or tuck into More: Apps, the windows
/// and Settings always show; these five may go. And the Slim Bar, for a bar left showing all the time.
/// This device's alone, never sent.
enum BarItems {
    static let slimKey = "RCL.slimBar"
    static let hiddenKey = "RCL.barHidden"

    enum Item: String, CaseIterable, Identifiable {
        case files, shortcuts, magnifier, keyboard, desktop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .files: String(localized: "Files")
            case .shortcuts: String(localized: "Shortcuts")
            case .magnifier: String(localized: "Magnifier")
            case .keyboard: String(localized: "Keyboard")
            case .desktop: String(localized: "Desktop")
            }
        }
        var symbol: String {
            switch self {
            case .files: "arrow.down.doc"
            case .shortcuts: "command"
            case .magnifier: "plus.magnifyingglass"
            case .keyboard: "keyboard"
            case .desktop: "desktopcomputer"
            }
        }
    }

    /// The stored list ("files,magnifier") as a set; unknown words are skipped.
    static func hidden(_ raw: String) -> Set<Item> {
        Set(raw.split(separator: ",").compactMap { Item(rawValue: String($0)) })
    }

    static func raw(_ hidden: Set<Item>) -> String {
        Item.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }
}
