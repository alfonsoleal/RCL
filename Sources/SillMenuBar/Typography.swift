import SwiftUI

/// RCL's type: Geist, Agencia 85's typeface, in place of the system font. The six weights ship in the
/// app's Resources/Fonts (Scripts/make-app.sh copies Packaging/Fonts; Info.plist's
/// ATSApplicationFontsPath registers them; SIL Open Font License, OFL.txt beside them). The same file
/// as iOSClient/Typography.swift: the two apps share no SwiftUI module.
///
/// Each weight is named by its PostScript name rather than asked for with `.weight(_:)`: a custom
/// font's weight only resolves when the family registers as one, and Geist's static files register
/// some weights as families of their own ("Geist SemiBold"), which `.weight` would miss.
extension Font {
    /// A fixed size, as `.system(size:weight:)` was: it does not follow Dynamic Type.
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(GeistFace.name(weight), fixedSize: size)
    }

    /// A text style's size, as `.footnote` or `.headline` were.
    static func geist(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        .custom(GeistFace.name(weight ?? GeistFace.weight(style)), size: GeistFace.size(style), relativeTo: style)
    }
}

enum GeistFace {
    static func name(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: return "Geist-Light"
        case .medium: return "Geist-Medium"
        case .semibold: return "Geist-SemiBold"
        case .bold: return "Geist-Bold"
        case .heavy, .black: return "Geist-Black"
        default: return "Geist-Regular"
        }
    }

    /// macOS's sizes for each style (smaller than iOS's: body is 13 pt), so a style keeps its place.
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
    }

    /// The headline is the one style the system sets heavier.
    static func weight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }
}

extension Color {
    /// Agencia 85's green, RCL's one accent: switches, links and selections in every window.
    static let rclAccent = Color(red: 0x00 / 255, green: 0xD7 / 255, blue: 0x49 / 255)
}
