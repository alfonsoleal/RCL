import SwiftUI

/// RCL's type: Geist, Agencia 85's typeface, in place of the system font. The six weights ship in the
/// app (Packaging/Fonts, listed under UIAppFonts; SIL Open Font License, OFL.txt beside them).
///
/// Each weight is named by its PostScript name rather than asked for with `.weight(_:)`: a custom
/// font's weight only resolves when the family registers as one, and Geist's static files register
/// some weights as families of their own ("Geist SemiBold"), which `.weight` would miss.
extension Font {
    /// A fixed size, as `.system(size:weight:)` was: it does not follow Dynamic Type.
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(GeistFace.name(weight), fixedSize: size)
    }

    /// A text style's size that follows Dynamic Type, as `.footnote` or `.headline` were.
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

    /// The system's sizes at the default Dynamic Type size, so a style keeps its place.
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    /// The headline is the one style the system sets heavier.
    static func weight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }
}
