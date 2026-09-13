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

/// A saved tool configuration: everything selecting it applies at once.
///
/// Favourites are the answer to "one tap must select a visible tool, colour,
/// width or favourite configuration". One preset per ink type cannot express a
/// fine black pen *and* a red annotation pen, which is what a student actually
/// keeps to hand.
struct ToolFavorite: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var kind: InkToolKind
    var width: Double
    var color: RGBAColor
    /// A name the student typed. Empty means "describe me from my settings".
    var customName: String

    init(id: UUID = UUID(), kind: InkToolKind, width: Double, color: RGBAColor, customName: String = "") {
        self.id = id
        self.kind = kind
        self.width = min(max(width, kind.widthBounds.lowerBound), kind.widthBounds.upperBound)
        self.color = color
        self.customName = customName
    }

    var preset: InkToolPreset { InkToolPreset(width: width, color: color) }

    /// "Fine Black Pen", "Yellow Highlighter" — derived unless the student named it.
    var displayName: String {
        if !customName.isEmpty { return customName }
        let colorName = EditorPalette.name(for: color)
        switch kind {
        case .pen:
            let weight = width <= 1.25 ? "Fine " : (width >= 4 ? "Bold " : "")
            return "\(weight)\(colorName) Pen"
        case .pencil:
            return "\(colorName) Pencil"
        case .highlighter:
            return "\(colorName) Highlighter"
        }
    }

    func matches(kind: InkToolKind, preset: InkToolPreset) -> Bool {
        self.kind == kind && abs(self.width - preset.width) < 0.01 && self.color == preset.color
    }

    /// The original set Courseleaf ships with. Deliberately the configurations a
    /// student reaches for in a lecture, not a demonstration of every colour.
    ///
    /// The order is the point, not a preference. The toolbar shows only the
    /// first few — two at its narrowest, three at the medium width the editor
    /// actually gets on every iPad while the library sidebar is showing, since
    /// it is a `NavigationSplitView` detail pane and not the whole screen. So
    /// the pen and the highlighter come first and second: going between them
    /// in one tap is the thing a favourite is for, and it has to survive the
    /// narrowest row, not just the widest. The highlighter used to be fifth,
    /// behind three more pens, where no default layout ever showed it.
    static let shipped: [ToolFavorite] = [
        ToolFavorite(kind: .pen, width: 1, color: .black),
        ToolFavorite(kind: .highlighter, width: 16, color: RGBAColor(hex: "#FFE600")!),
        ToolFavorite(kind: .pen, width: 2, color: .black),
        ToolFavorite(kind: .pen, width: 2, color: RGBAColor(hex: "#D0312D")!),
        ToolFavorite(kind: .pen, width: 2, color: RGBAColor(hex: "#1C4FD8")!),
        ToolFavorite(kind: .highlighter, width: 16, color: RGBAColor(hex: "#7CF57A")!),
    ]
}

/// Colour names shared by the toolbar, favourites and VoiceOver.
enum EditorPalette {
    static let names: [String: String] = [
        "#000000FF": "Black", "#1C4FD8FF": "Blue", "#D0312DFF": "Red", "#1E8E3EFF": "Green",
        "#F28C28FF": "Orange", "#7A3E9DFF": "Purple", "#6E6E73FF": "Grey", "#3A3A3CFF": "Graphite",
        "#FFE600FF": "Yellow", "#7CF57AFF": "Mint", "#7ED0FFFF": "Sky", "#FF9BD3FF": "Pink",
        "#FFB05CFF": "Peach", "#F2C94CFF": "Tape Yellow",
    ]

    static func name(for color: RGBAColor) -> String {
        names[color.hexString] ?? color.hexString
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
    /// Saved tool configurations, in the order they appear in the toolbar.
    var favorites: [ToolFavorite] = ToolFavorite.shipped
    /// The favourite currently applied, when the active tool still matches it.
    var activeFavoriteID: UUID?
    /// Schema version of this stored value. Bumped when a field's *meaning*
    /// changes; adding a field with a default does not need it.
    var schemaVersion: Int = EditorToolState.currentSchemaVersion

    static let currentSchemaVersion = 2

    init() {}

    // Decoding is written out rather than synthesised because a student's saved
    // preferences predate every field added since. Synthesised `Decodable`
    // gives no guarantee that a missing key falls back to the property's
    // default, and a version that quietly reset a library's pens would be
    // indistinguishable from one that kept them until someone complained.
    // `EditorToolStateMigrationTests` decodes a blob captured from the shipped
    // build and asserts every field survives.
    enum CodingKeys: String, CodingKey {
        case tool, inkPresets, eraserMode, eraserWidth, lassoMode, selectionFilterRawValue
        case lastShapeKind, shapeStrokeColor, shapeStrokeWidth, textStyle, tapeColor
        case recentColors, lastInkTool, favorites, activeFavoriteID, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var value = EditorToolState()
        value.tool = try container.decodeIfPresent(EditorTool.self, forKey: .tool) ?? value.tool
        let storedPresets = try container.decodeIfPresent([InkToolKind: InkToolPreset].self, forKey: .inkPresets)
        value.inkPresets = storedPresets ?? value.inkPresets
        value.eraserMode = try container.decodeIfPresent(EraserMode.self, forKey: .eraserMode) ?? value.eraserMode
        value.eraserWidth = try container.decodeIfPresent(Double.self, forKey: .eraserWidth) ?? value.eraserWidth
        value.lassoMode = try container.decodeIfPresent(LassoMode.self, forKey: .lassoMode) ?? value.lassoMode
        value.selectionFilterRawValue = try container.decodeIfPresent(Int.self, forKey: .selectionFilterRawValue)
            ?? value.selectionFilterRawValue
        value.lastShapeKind = try container.decodeIfPresent(ShapeKind.self, forKey: .lastShapeKind) ?? value.lastShapeKind
        value.shapeStrokeColor = try container.decodeIfPresent(RGBAColor.self, forKey: .shapeStrokeColor) ?? value.shapeStrokeColor
        value.shapeStrokeWidth = try container.decodeIfPresent(Double.self, forKey: .shapeStrokeWidth) ?? value.shapeStrokeWidth
        value.textStyle = try container.decodeIfPresent(TextStyleDefaults.self, forKey: .textStyle) ?? value.textStyle
        value.tapeColor = try container.decodeIfPresent(RGBAColor.self, forKey: .tapeColor) ?? value.tapeColor
        value.recentColors = try container.decodeIfPresent([RGBAColor].self, forKey: .recentColors) ?? value.recentColors
        value.lastInkTool = try container.decodeIfPresent(InkToolKind.self, forKey: .lastInkTool) ?? value.lastInkTool
        value.activeFavoriteID = try container.decodeIfPresent(UUID.self, forKey: .activeFavoriteID)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if let stored = try container.decodeIfPresent([ToolFavorite].self, forKey: .favorites) {
            value.favorites = stored
        } else if let storedPresets {
            // Version 1 had one configuration per ink type and no favourites.
            // Seed the list from what the student had actually set, so their
            // pen, pencil and highlighter are the first three favourites
            // instead of being replaced by ours.
            value.favorites = EditorToolState.seededFavorites(from: storedPresets)
        }
        // Neither key: there is no earlier choice to carry forward, so the
        // shipped set `value` already holds is the answer. Seeding from the
        // defaults here would rebuild the same configurations under new
        // identifiers and push two shipped favourites off the end for nothing.
        value.schemaVersion = max(storedVersion, 1)
        self = value
        self.schemaVersion = EditorToolState.currentSchemaVersion
    }

    /// Favourites built from a version-1 value's per-type presets, followed by
    /// the shipped ones the student does not already have.
    static func seededFavorites(from presets: [InkToolKind: InkToolPreset]) -> [ToolFavorite] {
        var result: [ToolFavorite] = []
        for kind in InkToolKind.allCases {
            let preset = presets[kind] ?? kind.defaultPreset
            result.append(ToolFavorite(kind: kind, width: preset.width, color: preset.color))
        }
        for shipped in ToolFavorite.shipped where !result.contains(where: { $0.matches(kind: shipped.kind, preset: shipped.preset) }) {
            result.append(shipped)
        }
        return Array(result.prefix(maxFavorites))
    }

    static let maxFavorites = 12

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
        if case .ink(let kind) = tool {
            lastInkTool = kind
            activeFavoriteID = favorites.first { $0.matches(kind: kind, preset: preset(for: kind)) }?.id
        } else {
            activeFavoriteID = nil
        }
        if case .shape(let kind) = tool { lastShapeKind = kind }
    }

    // MARK: Favourites

    /// Applies a saved configuration in full: the tool kind, its colour and its
    /// width, in one step and one tap.
    mutating func applyFavorite(_ favorite: ToolFavorite) {
        setPreset(favorite.preset, for: favorite.kind)
        tool = .ink(favorite.kind)
        lastInkTool = favorite.kind
        activeFavoriteID = favorite.id
    }

    /// The favourite the active tool currently is, if any.
    var matchingFavorite: ToolFavorite? {
        guard case .ink(let kind) = tool else { return nil }
        let current = preset(for: kind)
        if let id = activeFavoriteID, let favorite = favorites.first(where: { $0.id == id }),
           favorite.matches(kind: kind, preset: current) {
            return favorite
        }
        return favorites.first { $0.matches(kind: kind, preset: current) }
    }

    mutating func addFavoriteFromCurrentTool() {
        guard favorites.count < Self.maxFavorites else { return }
        let kind: InkToolKind
        if case .ink(let active) = tool { kind = active } else { kind = lastInkTool }
        let current = preset(for: kind)
        guard !favorites.contains(where: { $0.matches(kind: kind, preset: current) }) else { return }
        let favorite = ToolFavorite(kind: kind, width: current.width, color: current.color)
        favorites.append(favorite)
        activeFavoriteID = favorite.id
    }

    mutating func removeFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        if activeFavoriteID == id { activeFavoriteID = nil }
    }

    /// Reordering, written out rather than taken from SwiftUI so the model has
    /// no UI dependency and the behaviour is unit-testable.
    mutating func moveFavorites(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().compactMap { favorites.indices.contains($0) ? favorites[$0] : nil }
        guard !moving.isEmpty else { return }
        let removedBefore = offsets.filter { $0 < destination }.count
        var remaining = favorites
        for index in offsets.sorted(by: >) where remaining.indices.contains(index) { remaining.remove(at: index) }
        let insertAt = min(max(destination - removedBefore, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertAt)
        favorites = remaining
    }

    mutating func updateFavorite(_ favorite: ToolFavorite) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        favorites[index] = favorite
        if activeFavoriteID == favorite.id { setPreset(favorite.preset, for: favorite.kind) }
    }

    /// Colours offered for the tool that is active, so a highlighter shows
    /// highlighter colours rather than pen colours.
    var paletteForActiveTool: [RGBAColor] {
        if case .ink(.highlighter) = tool { return Self.highlighterPresets }
        if case .tape = tool { return [TapeContent().color] + Self.highlighterPresets }
        return Self.colorPresets
    }

    /// The three width presets shown for the active writing tool.
    var widthPresetsForActiveTool: [Double] {
        let kind: InkToolKind
        if case .ink(let active) = tool { kind = active } else { kind = lastInkTool }
        return Array(kind.widthPresets.prefix(3))
    }

    /// Colour of the active tool, for the swatch row's selected state.
    var activeColor: RGBAColor {
        switch tool {
        case .ink(let kind): return preset(for: kind).color
        case .shape: return shapeStrokeColor
        case .tape: return tapeColor
        case .text: return textStyle.color
        default: return preset(for: lastInkTool).color
        }
    }

    /// Width of the active tool.
    var activeWidth: Double {
        switch tool {
        case .ink(let kind): return preset(for: kind).width
        case .eraser: return eraserWidth
        case .shape: return shapeStrokeWidth
        default: return preset(for: lastInkTool).width
        }
    }

    /// One tap on a visible swatch: applies to whatever tool is active.
    mutating func applyColor(_ color: RGBAColor) {
        switch tool {
        case .ink(let kind):
            var p = preset(for: kind); p.color = color; setPreset(p, for: kind)
            activeFavoriteID = favorites.first { $0.matches(kind: kind, preset: preset(for: kind)) }?.id
        case .shape:
            shapeStrokeColor = color; noteColor(color)
        case .tape:
            tapeColor = color
        case .text:
            textStyle.color = color; noteColor(color)
        default:
            var p = preset(for: lastInkTool); p.color = color; setPreset(p, for: lastInkTool)
        }
    }

    /// One tap on a visible width preset.
    mutating func applyWidth(_ width: Double) {
        switch tool {
        case .ink(let kind):
            var p = preset(for: kind); p.width = width; setPreset(p, for: kind)
            activeFavoriteID = favorites.first { $0.matches(kind: kind, preset: preset(for: kind)) }?.id
        case .eraser:
            eraserWidth = width
        case .shape:
            shapeStrokeWidth = width
        default:
            var p = preset(for: lastInkTool); p.width = width; setPreset(p, for: lastInkTool)
        }
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
    static let defaultKey = "com.idlery.courseleaf.editor.toolState"
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
    /// Crossing handwriting out with the pen erases it. Off until a student
    /// turns it on: it changes what a stroke means, and a wrong guess costs
    /// work. See Settings ▸ Writing.
    var scribbleErase: Bool = false
    /// Holding at the end of a freehand shape offers a clean one.
    var shapeCorrection: Bool = true
    /// Snap corrected shapes to the horizontal/vertical and to equal sides when
    /// they are already close. A deliberate diagonal is never straightened.
    var snapsShapesToAxis: Bool = true

    var drawingPolicy: PKCanvasViewDrawingPolicy {
        if fingerDrawing { return .anyInput }
        return pencilOnly ? .pencilOnly : .default
    }
}
