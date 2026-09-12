import XCTest
import UIKit
import DocumentCore
import Editing
@testable import Courseleaf

/// Proof that a student's saved tool preferences survive the schema change that
/// added favourites.
///
/// The JSON below is not generated from the current type — that would prove
/// nothing. It is the shape the shipped build wrote: no `favorites`, no
/// `activeFavoriteID`, no `schemaVersion`. If decoding ever stops tolerating a
/// missing key, this fails instead of silently resetting a library's pens.
final class EditorToolStateMigrationTests: XCTestCase {

    /// Exactly what version 1 stored, with values a student would recognise as
    /// theirs: a 3.5pt red pen, a wide mint highlighter, a stroke eraser.
    private let shippedVersionOneJSON = """
    {
      "tool" : { "ink" : { "_0" : "pen" } },
      "inkPresets" : {
        "pen" : { "width" : 3.5, "color" : { "red" : 0.81, "green" : 0.19, "blue" : 0.17, "alpha" : 1 } },
        "pencil" : { "width" : 7, "color" : { "red" : 0.22, "green" : 0.22, "blue" : 0.23, "alpha" : 1 } },
        "highlighter" : { "width" : 32, "color" : { "red" : 0.48, "green" : 0.96, "blue" : 0.47, "alpha" : 1 } }
      },
      "eraserMode" : "wholeStroke",
      "eraserWidth" : 40,
      "lassoMode" : "rectangle",
      "selectionFilterRawValue" : 3,
      "lastShapeKind" : "ellipse",
      "shapeStrokeColor" : { "red" : 0, "green" : 0, "blue" : 0, "alpha" : 1 },
      "shapeStrokeWidth" : 4,
      "textStyle" : {
        "fontSize" : 22, "weight" : "semibold", "design" : "serif", "alignment" : "center",
        "color" : { "red" : 0, "green" : 0, "blue" : 0, "alpha" : 1 }
      },
      "tapeColor" : { "red" : 0.95, "green" : 0.79, "blue" : 0.30, "alpha" : 1 },
      "recentColors" : [ { "red" : 0.81, "green" : 0.19, "blue" : 0.17, "alpha" : 1 } ],
      "lastInkTool" : "pen"
    }
    """

    private func decodeShippedVersionOne() throws -> EditorToolState {
        let data = Data(shippedVersionOneJSON.utf8)
        return try DocumentJSON.decoder().decode(EditorToolState.self, from: data)
    }

    // MARK: Migration

    func testEveryVersionOneFieldSurvivesTheNewSchema() throws {
        let state = try decodeShippedVersionOne()

        XCTAssertEqual(state.tool, .ink(.pen))
        XCTAssertEqual(state.preset(for: .pen).width, 3.5, accuracy: 0.001)
        XCTAssertEqual(state.preset(for: .pencil).width, 7, accuracy: 0.001)
        XCTAssertEqual(state.preset(for: .highlighter).width, 32, accuracy: 0.001)
        XCTAssertEqual(state.preset(for: .pen).color.red, 0.81, accuracy: 0.01)
        XCTAssertEqual(state.preset(for: .highlighter).color.green, 0.96, accuracy: 0.01)
        XCTAssertEqual(state.eraserMode, .wholeStroke)
        XCTAssertEqual(state.eraserWidth, 40, accuracy: 0.001)
        XCTAssertEqual(state.lassoMode, .rectangle)
        XCTAssertEqual(state.selectionFilterRawValue, 3)
        XCTAssertEqual(state.lastShapeKind, .ellipse)
        XCTAssertEqual(state.shapeStrokeWidth, 4, accuracy: 0.001)
        XCTAssertEqual(state.textStyle.fontSize, 22, accuracy: 0.001)
        XCTAssertEqual(state.textStyle.weight, .semibold)
        XCTAssertEqual(state.textStyle.design, .serif)
        XCTAssertEqual(state.textStyle.alignment, .center)
        XCTAssertEqual(state.recentColors.count, 1)
        XCTAssertEqual(state.lastInkTool, .pen)
    }

    func testFavoritesAreSeededFromTheStudentsOwnPensNotOverwrittenWithOurs() throws {
        let state = try decodeShippedVersionOne()
        XCTAssertFalse(state.favorites.isEmpty, "a migrated value must not arrive with an empty toolbar")

        // The student's actual three configurations come first, in tool order.
        let pen = try XCTUnwrap(state.favorites.first { $0.kind == .pen })
        XCTAssertEqual(pen.width, 3.5, accuracy: 0.001, "their 3.5pt pen, not our 2pt one")
        XCTAssertEqual(pen.color.red, 0.81, accuracy: 0.01)
        let highlighter = try XCTUnwrap(state.favorites.first { $0.kind == .highlighter })
        XCTAssertEqual(highlighter.width, 32, accuracy: 0.001)
        XCTAssertEqual(highlighter.color.green, 0.96, accuracy: 0.01)
        XCTAssertTrue(state.favorites.contains { $0.kind == .pencil })

        XCTAssertLessThanOrEqual(state.favorites.count, EditorToolState.maxFavorites)
        XCTAssertEqual(state.schemaVersion, EditorToolState.currentSchemaVersion)
    }

    func testAValueWithNoFieldsAtAllDecodesToTheDefaults() throws {
        let state = try DocumentJSON.decoder().decode(EditorToolState.self, from: Data("{}".utf8))
        XCTAssertEqual(state.tool, EditorToolState().tool)
        XCTAssertEqual(state.preset(for: .pen), InkToolKind.pen.defaultPreset)
        XCTAssertEqual(state.favorites, ToolFavorite.shipped)
    }

    func testTheCurrentSchemaRoundTripsThroughTheStore() throws {
        let name = "ToolStateMigration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = EditorToolStateStore(defaults: defaults, key: "test.toolState")

        var state = try decodeShippedVersionOne()
        state.favorites.append(ToolFavorite(kind: .pen, width: 1, color: .black, customName: "Margin notes"))
        let first = state.favorites[0]
        state.applyFavorite(first)
        store.save(state)

        let loaded = store.load()
        XCTAssertEqual(loaded.favorites.map(\.id), state.favorites.map(\.id), "ids and order survive")
        XCTAssertEqual(loaded.favorites.last?.customName, "Margin notes")
        XCTAssertEqual(loaded.activeFavoriteID, state.activeFavoriteID)
        XCTAssertEqual(loaded.preset(for: .pen), state.preset(for: .pen))
    }

    func testAnUnreadableStoredValueFallsBackToDefaultsRatherThanCrashing() throws {
        let name = "ToolStateMigration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: "test.toolState")
        let loaded = EditorToolStateStore(defaults: defaults, key: "test.toolState").load()
        XCTAssertEqual(loaded.favorites, ToolFavorite.shipped)
    }

    // MARK: Favourites behaviour

    func testSelectingAFavoriteAppliesToolColourAndWidthTogether() throws {
        var state = EditorToolState()
        let yellow = try XCTUnwrap(state.favorites.first { $0.kind == .highlighter })
        state.applyFavorite(yellow)

        XCTAssertEqual(state.tool, .ink(.highlighter))
        XCTAssertEqual(state.preset(for: .highlighter).color, yellow.color)
        XCTAssertEqual(state.preset(for: .highlighter).width, yellow.width, accuracy: 0.001)
        XCTAssertEqual(state.matchingFavorite?.id, yellow.id, "the toolbar has to be able to show it as selected")

        let blackPen = try XCTUnwrap(state.favorites.first { $0.kind == .pen && $0.color == .black && $0.width == 2 })
        state.applyFavorite(blackPen)
        XCTAssertEqual(state.tool, .ink(.pen))
        XCTAssertEqual(state.matchingFavorite?.id, blackPen.id)
    }

    func testFavoritesCanBeAddedRemovedAndReordered() {
        var state = EditorToolState()
        let originalOrder = state.favorites.map(\.id)

        state.moveFavorites(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(state.favorites[2].id, originalOrder[0], "the first favourite moved down two places")
        XCTAssertEqual(state.favorites.count, originalOrder.count)

        let removed = state.favorites[0].id
        state.removeFavorite(id: removed)
        XCTAssertFalse(state.favorites.contains { $0.id == removed })

        state.select(.ink(.pencil))
        var pencil = state.preset(for: .pencil)
        pencil.width = 9
        state.setPreset(pencil, for: .pencil)
        let before = state.favorites.count
        state.addFavoriteFromCurrentTool()
        XCTAssertEqual(state.favorites.count, before + 1)
        XCTAssertEqual(state.favorites.last?.width, 9, accuracy: 0.001)
        XCTAssertEqual(state.matchingFavorite?.id, state.favorites.last?.id)

        // Adding the same configuration twice is a no-op, not a duplicate row.
        state.addFavoriteFromCurrentTool()
        XCTAssertEqual(state.favorites.count, before + 1)
    }

    func testAFavoriteDescribesItselfUntilTheStudentNamesIt() {
        let fine = ToolFavorite(kind: .pen, width: 1, color: .black)
        XCTAssertEqual(fine.displayName, "Fine Black Pen")
        let highlighter = ToolFavorite(kind: .highlighter, width: 16, color: RGBAColor(hex: "#FFE600")!)
        XCTAssertEqual(highlighter.displayName, "Yellow Highlighter")
        var named = fine
        named.customName = "Margin notes"
        XCTAssertEqual(named.displayName, "Margin notes")
    }

    func testAFavoritesWidthIsClampedToWhatTheToolAllows() {
        let tooWide = ToolFavorite(kind: .pen, width: 400, color: .black)
        XCTAssertEqual(tooWide.width, InkToolKind.pen.widthBounds.upperBound, accuracy: 0.001)
        let tooThin = ToolFavorite(kind: .highlighter, width: 0.1, color: .black)
        XCTAssertEqual(tooThin.width, InkToolKind.highlighter.widthBounds.lowerBound, accuracy: 0.001)
    }

    // MARK: One tap

    func testOneTapOnAColourOrWidthChangesTheActiveTool() throws {
        var state = EditorToolState()
        state.select(.ink(.pen))
        let red = try XCTUnwrap(EditorToolState.colorPresets.first { EditorPalette.name(for: $0) == "Red" })

        state.applyColor(red)
        XCTAssertEqual(state.preset(for: .pen).color, red, "one tap, no submenu")
        XCTAssertEqual(state.activeColor, red)

        let width = state.widthPresetsForActiveTool[2]
        state.applyWidth(width)
        XCTAssertEqual(state.activeWidth, width, accuracy: 0.001)

        // A highlighter shows highlighter colours, not pen colours.
        state.select(.ink(.highlighter))
        XCTAssertEqual(state.paletteForActiveTool, EditorToolState.highlighterPresets)
        XCTAssertEqual(state.widthPresetsForActiveTool, Array(InkToolKind.highlighter.widthPresets.prefix(3)))
    }
}
