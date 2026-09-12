import Foundation
import PencilKit
import UIKit
import DocumentCore
import Editing

// The editor's tool state: which tool is active and every tool's options.
// Persisted between launches through `EditorToolStateStore` (UserDefaults)
// so the pen a student picked yesterday is still selected today.
//
// Pens are PencilKit inks with honest names: Pen (`.pen`), Pencil (`.pencil`)
// and Highlighter (`.marker`). There is no fountain-pen or brush simulation.

enum InkToolKind: String, Codable, CaseIterable, Hashable, Sendable {
    case pen, pencil, highlighter

    var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .highlighter: return "highlighter"
        }
    }

    var pencilKitInkType: PKInkingTool.InkType {
        switch self {
        case .pen: return .pen
        case .pencil: return .pencil
        case .highlighter: return .marker
        }
    }

    /// Width presets in page points.
    var widthPresets: [Double] {
        switch self {
        case .pen: return [1, 2, 3.5, 6]
        case .pencil: return [2, 4, 7, 10]
        case .highlighter: return [10, 16, 24, 32]
        }
    }

    /// Width bounds this app allows for the tool, in page points.
    ///
    /// These are Courseleaf's own limits, not a PencilKit query: the SDK has no
    /// stable public accessor for an ink type's valid width range, and guessing
    /// one broke the build twice. The range brackets `widthPresets` with room to
    /// drag a slider past either end.
    var widthBounds: ClosedRange<Double> {
        switch self {
        case .pen: return 0.5...12
        case .pencil: return 1...20
        case .highlighter: return 6...48
        }
    }

    var defaultPreset: InkToolPreset {
        switch self {
        case .pen: return InkToolPreset(width: 2, color: .black)
        case .pencil: return InkToolPreset(width: 4, color: RGBAColor(hex: "#3A3A3C")!)
        case .highlighter: return InkToolPreset(width: 16, color: RGBAColor(hex: "#FFE600")!)
        }
    }
}

struct InkToolPreset: Codable, Hashable, Sendable {
    var width: Double
    var color: RGBAColor
}

enum EraserMode: String, Codable, CaseIterable, Hashable, Sendable {
    case pixel, wholeStroke

    var displayName: String { self == .pixel ? "Pixel Eraser" : "Stroke Eraser" }
}

enum LassoMode: String, Codable, CaseIterable, Hashable, Sendable {
    case freehand, rectangle

    var displayName: String { self == .freehand ? "Freehand" : "Rectangle" }
}

enum EditorTool: Codable, Hashable, Sendable {
    case ink(InkToolKind)
    case eraser
    case lasso
    case text
    case image
    case shape(ShapeKind)
    case tape

    /// Tools that hand touches to the PencilKit canvas.
    var isInkTool: Bool {
        switch self {
        case .ink, .eraser: return true
        default: return false
        }
    }

    /// Tools that select or create objects through the selection overlay.
    var usesOverlayDrag: Bool {
        switch self {
        case .lasso, .shape, .tape, .text: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .ink(let kind): return kind.displayName
        case .eraser: return "Eraser"
        case .lasso: return "Lasso"
        case .text: return "Text"
        case .image: return "Image"
        case .shape(let kind): return ShapeKindNames.name(kind)
        case .tape: return "Tape"
        }
    }

    var symbolName: String {
        switch self {
        case .ink(let kind): return kind.symbolName
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .image: return "photo"
        case .shape(let kind): return ShapeKindNames.symbol(kind)
        case .tape: return "rectangle.fill"
        }
    }
}

enum ShapeKindNames {
    static func name(_ kind: ShapeKind) -> String {
        switch kind {
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        }
    }
    static func symbol(_ kind: ShapeKind) -> String {
        switch kind {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
}

struct TextStyleDefaults: Codable, Hashable, Sendable {
    var fontSize: Double = 16
    var weight: FontWeight = .regular
    var design: FontDesign = .standard
    var alignment: TextAlignment = .leading
    var color: RGBAColor = .black

    func content(text: String) -> TextContent {
        TextContent(text: text, fontSize: fontSize, weight: weight, design: design, alignment: alignment, color: color)
    }
}

struct EditorToolState: Codable, Hashable, Sendable {
    static let colorPresets: [RGBAColor] = [
        .black,
        RGBAColor(hex: "#1C4FD8")!,   // blue
        RGBAColor(hex: "#D0312D")!,   // red
        RGBAColor(hex: "#1E8E3E")!,   // green
        RGBAColor(hex: "#F28C28")!,   // orange
        RGBAColor(hex: "#7A3E9D")!,   // purple
        RGBAColor(hex: "#6E6E73")!,   // grey
    ]
    static let highlighterPresets: [RGBAColor] = [
        RGBAColor(hex: "#FFE600")!, RGBAColor(hex: "#7CF57A")!, RGBAColor(hex: "#7ED0FF")!,
        RGBAColor(hex: "#FF9BD3")!, RGBAColor(hex: "#FFB05C")!,
    ]
    static let maxRecentColors = 8

    var tool: EditorTool = .ink(.pen)
    var inkPresets: [InkToolKind: InkToolPreset] = [
        .pen: InkToolKind.pen.defaultPreset,
        .pencil: InkToolKind.pencil.defaultPreset,
        .highlighter: InkToolKind.highlighter.defaultPreset,
    ]
    var eraserMode: EraserMode = .pixel
    var eraserWidth: Double = 20
    var lassoMode: LassoMode = .freehand
    /// `SelectionFilter` raw value (the option set itself is not Codable).
    var selectionFilterRawValue: Int = SelectionFilter.all.rawValue
    var lastShapeKind: ShapeKind = .rectangle
    var shapeStrokeColor: RGBAColor = .black
    var shapeStrokeWidth: Double = 2
    var textStyle = TextStyleDefaults()
    var tapeColor: RGBAColor = TapeContent().color
    var recentColors: [RGBAColor] = []
    /// The last ink tool, restored when switching back from eraser/lasso with the shortcut.
    var lastInkTool: InkToolKind = .pen

    init() {}

    var selectionFilter: SelectionFilter {
        get { SelectionFilter(rawValue: selectionFilterRawValue) }
        set { selectionFilterRawValue = newValue.rawValue }
    }

    func preset(for kind: InkToolKind) -> InkToolPreset { inkPresets[kind] ?? kind.defaultPreset }

    mutating func setPreset(_ preset: InkToolPreset, for kind: InkToolKind) {
        var p = preset
        let bounds = kind.widthBounds
        p.width = min(max(p.width, bounds.lowerBound), bounds.upperBound)
        inkPresets[kind] = p
        noteColor(p.color)
    }

    mutating func noteColor(_ color: RGBAColor) {
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > Self.maxRecentColors { recentColors.removeLast(recentColors.count - Self.maxRecentColors) }
    }

    mutating func select(_ tool: EditorTool) {
        self.tool = tool
        if case .ink(let kind) = tool { lastInkTool = kind }
        if case .shape(let kind) = tool { lastShapeKind = kind }
    }

    /// The PencilKit tool for the active ink tool; nil for non-ink tools.
    var pencilKitTool: PKTool? {
        switch tool {
        case .ink(let kind):
            let p = preset(for: kind)
            return PKInkingTool(kind.pencilKitInkType, color: UIColor(p.color), width: CGFloat(p.width))
        case .eraser:
            switch eraserMode {
            case .pixel: return PKEraserTool(.bitmap, width: CGFloat(eraserWidth))
            case .wholeStroke: return PKEraserTool(.vector)
            }
        default:
            return nil
        }
    }

    /// Text content for a new text box.
    func newTextContent(_ text: String = "") -> TextContent { textStyle.content(text: text) }

    func newShapeContent(_ kind: ShapeKind) -> ShapeContent {
        ShapeContent(kind: kind, strokeColor: shapeStrokeColor, strokeWidth: shapeStrokeWidth)
    }

    func newTapeContent() -> TapeContent { TapeContent(color: tapeColor) }
}

/// Persists `EditorToolState` as JSON in a `UserDefaults` suite.
final class EditorToolStateStore {
    static let defaultKey = "dev.courseleaf.editor.toolState"
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = EditorToolStateStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> EditorToolState {
        guard let data = defaults.data(forKey: key) else { return EditorToolState() }
        return (try? DocumentJSON.decoder().decode(EditorToolState.self, from: data)) ?? EditorToolState()
    }

    func save(_ state: EditorToolState) {
        guard let data = try? DocumentJSON.encoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func reset() { defaults.removeObject(forKey: key) }
}

/// Input settings taken from `AppEnvironment.settings`.
struct EditorInputSettings: Hashable {
    var pencilOnly: Bool = true
    var fingerDrawing: Bool = false
    var leftHanded: Bool = false

    var drawingPolicy: PKCanvasViewDrawingPolicy {
        if fingerDrawing { return .anyInput }
        return pencilOnly ? .pencilOnly : .default
    }
}
