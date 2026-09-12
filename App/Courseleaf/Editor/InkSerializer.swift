import Foundation
import PencilKit

// Turning a `PKDrawing` into the bytes and digest that become an immutable ink
// asset is the one expensive step in saving a stroke, so it never runs on the
// drawing path (docs/ARCHITECTURE.md §7). It is behind a protocol for one
// reason: the ordering bugs it can cause are invisible unless a test can make
// one encode finish after a later one started.

/// A drawing handed to a background task. The value is immutable; the box only
/// states that to the compiler.
struct InkPayload: @unchecked Sendable {
    let drawing: PKDrawing
}

struct EncodedInk: Sendable {
    let data: Data
    let sha256: String
}

protocol InkSerializing: Sendable {
    func encode(_ drawing: PKDrawing) async -> EncodedInk
}

/// The shipping serializer: off the main actor, at user-initiated priority.
struct DetachedInkSerializer: InkSerializing {
    func encode(_ drawing: PKDrawing) async -> EncodedInk {
        let payload = InkPayload(drawing: drawing)
        return await Task.detached(priority: .userInitiated) { () -> EncodedInk in
            let data = payload.drawing.dataRepresentation()
            return EncodedInk(data: data, sha256: EditorAssets.sha256Hex(data))
        }.value
    }
}
