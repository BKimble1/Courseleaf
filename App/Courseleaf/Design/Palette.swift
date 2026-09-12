import SwiftUI
import UIKit
import DocumentCore

// The app's visual vocabulary: a neutral surface palette with one accent
// (the asset catalog's AccentColor), plus the cover palettes drawn by
// `CoverView`. Every colour is defined for light and dark appearance; nothing
// hardcodes white or black as a background.

extension Color {
    /// A portable `RGBAColor` as a SwiftUI colour (sRGB, straight alpha).
    init(_ rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

enum Palette {
    /// The single accent colour (AccentColor in the asset catalog).
    static let accent = Color.accentColor

    // Surfaces. System colours so light and dark are both correct and follow
    // the increased-contrast accessibility setting.
    static let windowBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let raisedSurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator)

    // Text.
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)

    // Status.
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let success = Color(uiColor: .systemGreen)

    /// Paper colour behind page previews (never pure white in dark mode).
    static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.92, green: 0.92, blue: 0.90, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })

    // MARK: Cover palettes

    /// Base, deep and light tones for a cover palette. Original colours; no
    /// third-party cover art is used anywhere in the app.
    struct CoverTones: Hashable {
        var base: RGBAColor
        var deep: RGBAColor
        var light: RGBAColor
        var label: RGBAColor
    }

    static func tones(for palette: CoverStyle.Palette) -> CoverTones {
        switch palette {
        case .slate:
            return CoverTones(base: hex("#4A5568"), deep: hex("#2D3543"), light: hex("#7C8798"), label: .white)
        case .moss:
            return CoverTones(base: hex("#4B6B4A"), deep: hex("#2E4530"), light: hex("#83A37F"), label: .white)
        case .clay:
            return CoverTones(base: hex("#A75A42"), deep: hex("#733521"), light: hex("#D08D74"), label: .white)
        case .ocean:
            return CoverTones(base: hex("#2E6E8E"), deep: hex("#194A63"), light: hex("#6FA6C1"), label: .white)
        case .plum:
            return CoverTones(base: hex("#6B4A78"), deep: hex("#432C4E"), light: hex("#A183AC"), label: .white)
        case .sand:
            return CoverTones(base: hex("#D8C08F"), deep: hex("#A88F5C"), light: hex("#F0E2BE"), label: hex("#3A3222"))
        case .ink:
            return CoverTones(base: hex("#2B2D33"), deep: hex("#141519"), light: hex("#5A5D66"), label: .white)
        case .mint:
            return CoverTones(base: hex("#5FA08C"), deep: hex("#357061"), light: hex("#9ACFBD"), label: hex("#10241E"))
        }
    }

    static func name(for palette: CoverStyle.Palette) -> String {
        palette.rawValue.prefix(1).uppercased() + palette.rawValue.dropFirst()
    }

    static func name(for pattern: CoverStyle.Pattern) -> String {
        pattern.rawValue.prefix(1).uppercased() + pattern.rawValue.dropFirst()
    }

    private static func hex(_ string: String) -> RGBAColor {
        RGBAColor(hex: string) ?? .black
    }
}

enum PaperKindNames {
    static func title(_ kind: PaperKind) -> String {
        switch kind {
        case .blank: return "Blank"
        case .lined: return "Lined"
        case .grid: return "Grid"
        case .dotted: return "Dotted"
        case .cornell: return "Cornell"
        case .engineering: return "Engineering"
        }
    }

    static func detail(_ kind: PaperKind) -> String {
        switch kind {
        case .blank: return "No rules"
        case .lined: return "Horizontal rules"
        case .grid: return "Square grid"
        case .dotted: return "Dot grid"
        case .cornell: return "Cue column, notes and a summary band"
        case .engineering: return "Fine grid with margin rules"
        }
    }
}

/// The two page sizes offered when creating a notebook.
enum PageSizeChoice: String, CaseIterable, Identifiable, Hashable, Codable {
    case letter, a4

    var id: String { rawValue }

    var title: String { self == .letter ? "Letter" : "A4" }

    var detail: String { self == .letter ? "8.5 × 11 in" : "210 × 297 mm" }

    var pageSize: PageSize { self == .letter ? .letter : .a4 }

    init(pageSize: PageSize) {
        self = abs(pageSize.width - PageSize.a4.width) < 1 ? .a4 : .letter
    }
}
