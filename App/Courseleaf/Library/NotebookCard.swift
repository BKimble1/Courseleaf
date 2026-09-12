import SwiftUI
import DocumentCore
import Workspace

/// Actions a notebook offers in the library. The view model performs them;
/// the card only reports which one the student picked.
enum NotebookAction: Hashable {
    case open
    case rename
    case move
    case duplicate
    case toggleFavorite
    case changeCover
    case delete
    case fileNote
}

/// A notebook in the grid: cover, title, modified date and badges.
struct NotebookCard: View {
    let document: DocumentSummary
    var onAction: (NotebookAction) -> Void

    var body: some View {
        Button {
            onAction(.open)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CoverView(style: document.cover, title: document.title)
                    .aspectRatio(0.77, contentMode: .fit)
                    .overlay(alignment: .topTrailing) { badges }
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .cardTitleStyle()
                    Text(DateText.modified(document.modifiedAt))
                        .detailTextStyle()
                    Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.tertiaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu { NotebookMenu(document: document, onAction: onAction) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to open")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions { NotebookAccessibilityActions(document: document, onAction: onAction) }
    }

    @ViewBuilder
    private var badges: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if document.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .padding(6)
                    .background(.thinMaterial, in: Circle())
            }
            if document.pendingReviewCount > 0 {
                Text("\(document.pendingReviewCount)")
                    .badgeStyle(Palette.accent)
                    .background(.thinMaterial, in: Capsule())
            }
            if document.needsNewerApp {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Palette.warning)
                    .padding(6)
                    .background(.thinMaterial, in: Circle())
            }
        }
        .padding(6)
    }

    private var accessibilityLabel: String {
        var parts = [document.title]
        parts.append("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
        parts.append("modified \(DateText.modified(document.modifiedAt))")
        if document.isFavorite { parts.append("favorite") }
        if document.pendingReviewCount > 0 { parts.append("\(document.pendingReviewCount) pending review items") }
        if document.needsNewerApp { parts.append("needs a newer version of the app, read only") }
        return parts.joined(separator: ", ")
    }
}

/// A notebook as a list row.
struct NotebookRow: View {
    let document: DocumentSummary
    var onAction: (NotebookAction) -> Void

    var body: some View {
        Button {
            onAction(.open)
        } label: {
            HStack(spacing: 12) {
                CoverView(style: document.cover, title: nil, cornerRadius: 4)
                    .frame(width: 34, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title).cardTitleStyle()
                    Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s") · \(DateText.modified(document.modifiedAt))")
                        .detailTextStyle()
                }
                Spacer(minLength: 8)
                if document.pendingReviewCount > 0 {
                    Text("\(document.pendingReviewCount) to review").badgeStyle()
                }
                if document.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { NotebookMenu(document: document, onAction: onAction) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(document.title), \(document.pageCount) pages, modified \(DateText.modified(document.modifiedAt))")
        .accessibilityHint("Double tap to open")
        .accessibilityActions { NotebookAccessibilityActions(document: document, onAction: onAction) }
    }
}

/// The shared context menu.
struct NotebookMenu: View {
    let document: DocumentSummary
    var onAction: (NotebookAction) -> Void

    var body: some View {
        Button { onAction(.open) } label: { Label("Open", systemImage: "book") }
        Button { onAction(.rename) } label: { Label("Rename…", systemImage: "pencil") }
        Button { onAction(.move) } label: { Label("Move to Folder…", systemImage: "folder") }
        if document.kind == .quickNote {
            Button { onAction(.fileNote) } label: { Label("File This Note…", systemImage: "tray.and.arrow.down") }
        }
        Button { onAction(.duplicate) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { onAction(.toggleFavorite) } label: {
            Label(document.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: document.isFavorite ? "star.slash" : "star")
        }
        Button { onAction(.changeCover) } label: { Label("Change Cover…", systemImage: "paintpalette") }
        Divider()
        Button(role: .destructive) { onAction(.delete) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// VoiceOver rotor actions, so every context-menu action is reachable without
/// a long press.
struct NotebookAccessibilityActions: View {
    let document: DocumentSummary
    var onAction: (NotebookAction) -> Void

    var body: some View {
        Button("Open") { onAction(.open) }
        Button("Rename") { onAction(.rename) }
        Button("Move to folder") { onAction(.move) }
        Button("Duplicate") { onAction(.duplicate) }
        Button(document.isFavorite ? "Remove from favorites" : "Add to favorites") { onAction(.toggleFavorite) }
        Button("Change cover") { onAction(.changeCover) }
        Button("Delete") { onAction(.delete) }
    }
}
