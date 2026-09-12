import XCTest
import UIKit
import PencilKit
import DocumentCore
import Editing
@testable import Courseleaf

// The tool strip's state is what a student sees when they come back to the
// app tomorrow, so it has to survive its `UserDefaults` round trip exactly,
// and it has to translate into the right PencilKit tool.
final class EditorToolStateTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "dev.courseleaf.tests.toolstate.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> EditorToolStateStore {
        EditorToolStateStore(defaults: defaults, key: "editor.toolState")
    }

    func testAnEmptyStoreLoadsTheDefaults() {
        XCTAssertEqual(makeStore().load(), EditorToolState())
    }

    func testToolStateRoundTripsThroughItsStore() {
        let store = makeStore()
        var state = EditorToolState()
        state.select(.ink(.highlighter))
        state.setPreset(InkToolPreset(width: 18, color: RGBAColor(hex: "#7ED0FF")!), for: .highlighter)
        state.setPreset(InkToolPreset(width: 3.5, color: RGBAColor(hex: "#1C4FD8")!), for: .pen)
        state.eraserMode = .wholeStroke
        state.eraserWidth = 40
        state.lassoMode = .rectangle
        state.selectionFilter = [.ink, .text]
        state.shapeStrokeColor = RGBAColor(hex: "#1E8E3E")!
        state.shapeStrokeWidth = 4
        state.textStyle.fontSize = 22
        state.textStyle.weight = .semibold
        state.textStyle.design = .serif
        state.textStyle.alignment = .center
        state.textStyle.color = RGBAColor(hex: "#7A3E9D")!
        state.tapeColor = RGBAColor(hex: "#FF9BD3")!
        state.select(.shape(.ellipse))

        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.tool, .shape(.ellipse))
        XCTAssertEqual(loaded.lastShapeKind, .ellipse)
        XCTAssertEqual(loaded.lastInkTool, .highlighter)
        XCTAssertEqual(loaded.selectionFilter, [.ink, .text])
        XCTAssertEqual(loaded.preset(for: .pen).color, RGBAColor(hex: "#1C4FD8")!)
        XCTAssertEqual(loaded.textStyle.alignment, .center)
        XCTAssertEqual(loaded.recentColors, state.recentColors)

        // A second store over the same defaults sees the same state.
        XCTAssertEqual(EditorToolStateStore(defaults: defaults, key: "editor.toolState").load(), state)

        store.reset()
        XCTAssertEqual(store.load(), EditorToolState())
    }

    func testCorruptStoredDataFallsBackToTheDefaults() {
        defaults.set(Data("not json".utf8), forKey: "editor.toolState")
        XCTAssertEqual(makeStore().load(), EditorToolState())
    }

    func testSelectingRemembersTheLastInkAndShapeKind() {
        var state = EditorToolState()
        state.select(.ink(.pencil))
        XCTAssertEqual(state.lastInkTool, .pencil)
        state.select(.shape(.arrow))
        XCTAssertEqual(state.lastShapeKind, .arrow)
        XCTAssertEqual(state.lastInkTool, .pencil, "switching to a shape must not forget the pen")
    }

    func testPresetWidthIsClampedToThePencilKitRange() {
        var state = EditorToolState()
        state.setPreset(InkToolPreset(width: 10_000, color: .black), for: .pen)
        let minimum = PKInkingTool.minimumWidth(forInkType: .pen)
        let maximum = PKInkingTool.maximumWidth(forInkType: .pen)
        XCTAssertEqual(state.preset(for: .pen).width, Double(maximum), accuracy: 0.0001)
        state.setPreset(InkToolPreset(width: 0, color: .black), for: .pen)
        XCTAssertEqual(state.preset(for: .pen).width, Double(minimum), accuracy: 0.0001)
    }

    func testRecentColorsAreMostRecentFirstAndBounded() {
        var state = EditorToolState()
        for index in 0..<12 {
            state.noteColor(RGBAColor(red: Double(index) / 12, green: 0, blue: 0))
        }
        XCTAssertEqual(state.recentColors.count, EditorToolState.maxRecentColors)
        XCTAssertEqual(state.recentColors.first, RGBAColor(red: 11.0 / 12, green: 0, blue: 0))
        state.noteColor(RGBAColor(red: 11.0 / 12, green: 0, blue: 0))
        XCTAssertEqual(state.recentColors.count, EditorToolState.maxRecentColors, "re-using a colour must not duplicate it")
    }

    func testPencilKitToolFollowsTheSelectedTool() throws {
        var state = EditorToolState()
        state.select(.ink(.pencil))
        let pencil = try XCTUnwrap(state.pencilKitTool as? PKInkingTool)
        XCTAssertEqual(pencil.inkType, .pencil)

        state.select(.ink(.highlighter))
        let highlighter = try XCTUnwrap(state.pencilKitTool as? PKInkingTool)
        XCTAssertEqual(highlighter.inkType, .marker)

        state.select(.eraser)
        state.eraserMode = .pixel
        XCTAssertTrue(state.pencilKitTool is PKEraserTool)
        state.eraserMode = .wholeStroke
        XCTAssertTrue(state.pencilKitTool is PKEraserTool)

        state.select(.lasso)
        XCTAssertNil(state.pencilKitTool)
        state.select(.text)
        XCTAssertNil(state.pencilKitTool)
    }

    func testToolCategoriesDriveCanvasInteraction() {
        XCTAssertTrue(EditorTool.ink(.pen).isInkTool)
        XCTAssertTrue(EditorTool.eraser.isInkTool)
        XCTAssertFalse(EditorTool.lasso.isInkTool)
        XCTAssertTrue(EditorTool.lasso.usesOverlayDrag)
        XCTAssertTrue(EditorTool.shape(.rectangle).usesOverlayDrag)
        XCTAssertTrue(EditorTool.tape.usesOverlayDrag)
        XCTAssertTrue(EditorTool.text.usesOverlayDrag)
        XCTAssertFalse(EditorTool.ink(.pen).usesOverlayDrag)
    }

    func testDrawingPolicyFollowsTheInputSettings() {
        XCTAssertEqual(EditorInputSettings(pencilOnly: true, fingerDrawing: false, leftHanded: false).drawingPolicy, .pencilOnly)
        XCTAssertEqual(EditorInputSettings(pencilOnly: false, fingerDrawing: false, leftHanded: false).drawingPolicy, .default)
        // Finger drawing always wins: the student asked for it explicitly.
        XCTAssertEqual(EditorInputSettings(pencilOnly: true, fingerDrawing: true, leftHanded: false).drawingPolicy, .anyInput)
    }
}
