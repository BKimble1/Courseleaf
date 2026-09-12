import Foundation
import SwiftUI
import UIKit
import DocumentCore

// SwiftUI popovers the toolbar puts one level away from the writing controls:
// text style, and the favourites editor.

// MARK: - Text style

/// Font size, weight, design, alignment and colour for text boxes. Applies to
/// the selected text object (if any) and becomes the default for new boxes.
struct TextStylePopoverView: View {
    @State var style: TextStyleDefaults
    var onChange: (TextStyleDefaults) -> Void

    var body: some View {
        Form {
            Section("Size") {
                Stepper(value: $style.fontSize, in: 8...96, step: 1) {
                    Text("\(Int(style.fontSize)) pt")
                }
                .accessibilityLabel("Font size")
            }
            Section("Weight") {
                Picker("Weight", selection: $style.weight) {
                    ForEach(FontWeight.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Design") {
                Picker("Design", selection: $style.design) {
                    ForEach(FontDesign.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Alignment") {
                Picker("Alignment", selection: $style.alignment) {
                    // `TextAlignment` exists in both SwiftUI and DocumentCore; qualify the document one.
                    Image(systemName: "text.alignleft").tag(DocumentCore.TextAlignment.leading).accessibilityLabel("Leading")
                    Image(systemName: "text.aligncenter").tag(DocumentCore.TextAlignment.center).accessibilityLabel("Center")
                    Image(systemName: "text.alignright").tag(DocumentCore.TextAlignment.trailing).accessibilityLabel("Trailing")
                }
                .pickerStyle(.segmented)
            }
            Section("Color") {
                HStack(spacing: 10) {
                    ForEach(EditorToolState.colorPresets, id: \.hexString) { color in
                        Button {
                            style.color = color
                        } label: {
                            Circle()
                                .fill(Color(UIColor(color)))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(style.color == color ? Color.accentColor : Color.secondary.opacity(0.4),
                                                         lineWidth: style.color == color ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(EditorPalette.name(for: color))
                        .accessibilityAddTraits(style.color == color ? .isSelected : [])
                    }
                }
            }
        }
        .onChange(of: style) { _, newValue in onChange(newValue) }
        .frame(minWidth: 320, minHeight: 420)
    }
}

// MARK: - Favourites editor

/// Add, edit, reorder and remove saved tool configurations. Reordering is what
/// decides which favourites stay on the toolbar at narrower widths, so it is a
/// real drag-to-reorder list rather than a fixed set.
struct FavoritesEditorView: View {
    @State var favorites: [ToolFavorite]
    var onChange: ([ToolFavorite]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($favorites) { $favorite in
                        FavoriteRow(favorite: $favorite)
                    }
                    .onMove { offsets, destination in
                        favorites.move(fromOffsets: offsets, toOffset: destination)
                        onChange(favorites)
                    }
                    .onDelete { offsets in
                        favorites.remove(atOffsets: offsets)
                        onChange(favorites)
                    }
                } header: {
                    Text("On the toolbar, in order")
                } footer: {
                    Text("The first few appear in the writing row; how many depends on the window width. Drag to choose which.")
                }

                Section {
                    Button {
                        guard favorites.count < EditorToolState.maxFavorites else { return }
                        favorites.append(ToolFavorite(kind: .pen, width: 2, color: .black))
                        onChange(favorites)
                    } label: {
                        Label("Add a Favourite", systemImage: "plus.circle")
                    }
                    .disabled(favorites.count >= EditorToolState.maxFavorites)

                    Button(role: .destructive) {
                        favorites = ToolFavorite.shipped
                        onChange(favorites)
                    } label: {
                        Label("Reset to Courseleaf's Set", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Favourites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: favorites) { _, newValue in onChange(newValue) }
        }
        .frame(minWidth: 380, minHeight: 460)
    }
}

private struct FavoriteRow: View {
    @Binding var favorite: ToolFavorite

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: favorite.kind.symbolName)
                    .foregroundStyle(Color(UIColor(favorite.color)))
                    .accessibilityHidden(true)
                TextField("Name", text: $favorite.customName, prompt: Text(favorite.displayName))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Favourite name")
            }
            Picker("Tool", selection: $favorite.kind) {
                ForEach(InkToolKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Tool kind")

            HStack(spacing: 8) {
                ForEach(palette, id: \.hexString) { color in
                    Button {
                        favorite.color = color
                    } label: {
                        Circle()
                            .fill(Color(UIColor(color)))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(favorite.color == color ? Color.accentColor : Color.secondary.opacity(0.35),
                                                     lineWidth: favorite.color == color ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(EditorPalette.name(for: color))
                    .accessibilityAddTraits(favorite.color == color ? .isSelected : [])
                }
            }

            HStack {
                Text("Width")
                    .foregroundStyle(.secondary)
                Slider(value: $favorite.width,
                       in: favorite.kind.widthBounds.lowerBound...favorite.kind.widthBounds.upperBound,
                       step: 0.5)
                    .accessibilityLabel("Width")
                    .accessibilityValue(EditorToolbar.widthTitle(favorite.width))
                Text(EditorToolbar.widthTitle(favorite.width))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var palette: [RGBAColor] {
        favorite.kind == .highlighter ? EditorToolState.highlighterPresets : EditorToolState.colorPresets
    }
}
