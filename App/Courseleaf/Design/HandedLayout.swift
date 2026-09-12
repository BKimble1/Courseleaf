import SwiftUI

// Left-handed layout support (docs/PRODUCT_SPEC.md §3.7 and §7): primary
// controls sit on the trailing edge for right-handed students and on the
// leading edge for left-handed ones, so the writing hand never covers them.

enum HandedLayout {
    /// Where the primary controls of a screen go.
    static func primaryPlacement(leftHanded: Bool) -> ToolbarItemPlacement {
        leftHanded ? .topBarLeading : .topBarTrailing
    }

    /// Where the secondary controls go (the opposite edge).
    static func secondaryPlacement(leftHanded: Bool) -> ToolbarItemPlacement {
        leftHanded ? .topBarTrailing : .topBarLeading
    }

    static func alignment(leftHanded: Bool) -> HorizontalAlignment {
        leftHanded ? .leading : .trailing
    }

    static func frameAlignment(leftHanded: Bool) -> Alignment {
        leftHanded ? .leading : .trailing
    }

    static func edge(leftHanded: Bool) -> Edge.Set {
        leftHanded ? .leading : .trailing
    }
}

/// A row that keeps `primary` on the student's preferred side and `secondary`
/// on the other one, with a flexible gap between them.
struct HandedControlRow<Primary: View, Secondary: View>: View {
    var leftHanded: Bool
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        HStack(spacing: 12) {
            if leftHanded {
                primary()
                Spacer(minLength: 8)
                secondary()
            } else {
                secondary()
                Spacer(minLength: 8)
                primary()
            }
        }
    }
}

extension View {
    /// Aligns a floating control cluster to the student's preferred side.
    func handedAligned(leftHanded: Bool) -> some View {
        frame(maxWidth: .infinity, alignment: HandedLayout.frameAlignment(leftHanded: leftHanded))
    }
}
