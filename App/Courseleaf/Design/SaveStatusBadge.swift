import SwiftUI
import DocumentCore

/// The durable save state of an open document (docs/ARCHITECTURE.md §7).
/// "Saved" is only shown once the package reported a durable commit.
struct SaveStatusBadge: View {
    var status: SaveStatus
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(SaveStatusText.title(status))
                .font(Typography.caption)
                .foregroundStyle(tint)
            if case .failed(_, let retryable) = status, retryable, let onRetry {
                Button("Retry", action: onRetry)
                    .font(Typography.caption)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Tries to save the notebook again")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Save status")
        .accessibilityValue(SaveStatusText.spoken(status))
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .saving:
            ProgressView().controlSize(.mini)
        case .saved:
            Image(systemName: "checkmark.circle").foregroundStyle(tint)
        case .unsaved:
            Image(systemName: "pencil.circle").foregroundStyle(tint)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch status {
        case .failed: return Palette.danger
        case .saved: return Palette.secondaryText
        default: return Palette.secondaryText
        }
    }
}

enum SaveStatusText {
    static func title(_ status: SaveStatus) -> String {
        switch status {
        case .unsaved(let pending): return pending > 0 ? "Unsaved changes" : "Edited"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .failed(let message, _): return "Save failed: \(message)"
        }
    }

    static func spoken(_ status: SaveStatus) -> String {
        switch status {
        case .unsaved(let pending):
            return pending > 0 ? "\(pending) unsaved change\(pending == 1 ? "" : "s")" : "Edited, not saved yet"
        case .saving: return "Saving"
        case .saved(let date, _): return "Saved at \(DateText.modified(date))"
        case .failed(let message, let retryable):
            return retryable ? "Save failed, \(message). You can retry." : "Save failed, \(message)"
        }
    }
}
