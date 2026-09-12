import Foundation
import UIKit
import UniformTypeIdentifiers
import DocumentCore
import Editing

/// What the editor puts on the pasteboard: objects with their page-space
/// frames, the selected ink as an engine blob, and the bytes of any image
/// assets so a paste into another notebook can re-register them.
struct EditorPasteboardPayload: Codable, Equatable {
    var objects: [CanvasObject]
    var inkData: Data?
    var inkEngine: String
    var sourcePageSize: PageSize
    /// Image asset bytes keyed by the original asset ID string.
    var imageAssets: [String: Data]

    var isEmpty: Bool { objects.isEmpty && inkData == nil }
}

enum EditorPasteboard {
    static let typeIdentifier = "dev.courseleaf.clipboard"

    static func write(_ payload: EditorPasteboardPayload, to pasteboard: UIPasteboard = .general) {
        guard let data = try? DocumentJSON.encoder().encode(payload) else { return }
        var items: [String: Any] = [typeIdentifier: data]
        // Plain text for text objects so other apps get something useful.
        let text = payload.objects.compactMap { object -> String? in
            if case .text(let t) = object.content, !t.text.isEmpty { return t.text } else { return nil }
        }.joined(separator: "\n")
        if !text.isEmpty { items[UTType.utf8PlainText.identifier] = text }
        pasteboard.setItems([items], options: [:])
    }

    static func read(from pasteboard: UIPasteboard = .general) -> EditorPasteboardPayload? {
        guard let data = pasteboard.data(forPasteboardType: typeIdentifier) else { return nil }
        return try? DocumentJSON.decoder().decode(EditorPasteboardPayload.self, from: data)
    }

    static func hasContent(_ pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.contains(pasteboardTypes: [typeIdentifier]) || pasteboard.hasImages || pasteboard.hasStrings
    }
}
