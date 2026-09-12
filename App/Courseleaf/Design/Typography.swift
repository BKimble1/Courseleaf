import SwiftUI

// Type helpers. Everything is a Dynamic Type text style so the whole app
// scales with the student's text-size setting (no fixed point sizes).

enum Typography {
    static let screenTitle = Font.largeTitle.weight(.semibold)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let cardTitle = Font.headline
    static let body = Font.body
    static let detail = Font.subheadline
    static let caption = Font.caption
    static let badge = Font.caption2.weight(.semibold)
}

extension View {
    /// A card title: one line at normal sizes, wrapping at accessibility sizes.
    func cardTitleStyle() -> some View {
        font(Typography.cardTitle)
            .foregroundStyle(Palette.primaryText)
            .lineLimit(2)
    }

    func detailTextStyle() -> some View {
        font(Typography.detail).foregroundStyle(Palette.secondaryText)
    }

    /// A small pill used for kinds, states and counts.
    func badgeStyle(_ tint: Color = Palette.accent) -> some View {
        font(Typography.badge)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }

    /// A plain empty state with a title and an explanation.
    func emptyStateStyle() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
    }
}

/// Dates as shown in lists and cards: short and unambiguous.
enum DateText {
    static func modified(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(max(0, count)))
    }
}
