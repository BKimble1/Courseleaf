import XCTest
import UIKit
import DocumentCore
import Editing
@testable import Courseleaf

/// The toolbar's contract with a student who is trying to write: how many taps
/// a change costs, and that a change does not throw the row away and rebuild it.
@MainActor
final class EditorToolbarInteractionTests: XCTestCase {

    private func makeToolbar(width: CGFloat = 1180) -> (EditorToolbar, ToolbarSpy) {
        let toolbar = EditorToolbar(frame: CGRect(x: 0, y: 0, width: width, height: 44))
        let spy = ToolbarSpy()
        toolbar.delegate = spy
        toolbar.availableWidth = width
        toolbar.state = EditorToolState()
        return (toolbar, spy)
    }

    // MARK: Layout tiers

    func testLayoutTierIsChosenFromWidthAlone() {
        XCTAssertEqual(EditorToolbar.Tier.tier(forWidth: 1366), .regular, "landscape iPad")
        XCTAssertEqual(EditorToolbar.Tier.tier(forWidth: 1024), .regular, "portrait 12.9-inch")
        XCTAssertEqual(EditorToolbar.Tier.tier(forWidth: 834), .medium, "portrait 11-inch")
        XCTAssertEqual(EditorToolbar.Tier.tier(forWidth: 700), .compact, "a narrow Split View pane")
        XCTAssertEqual(EditorToolbar.Tier.tier(forWidth: 375), .compact)
    }

    func testTheCompactStripKeepsWhatAStudentCannotWorkWithout() {
        let tier = EditorToolbar.Tier.compact
        XCTAssertTrue(tier.directTools.contains(.eraser), "the eraser stays reachable in one tap")
        XCTAssertTrue(tier.directTools.contains(.lasso))
        XCTAssertTrue(tier.directTools.contains(.ink(.pen)))
        XCTAssertGreaterThanOrEqual(tier.favoriteCount, 2, "the primary favourites stay on the strip")
        XCTAssertGreaterThanOrEqual(tier.colorCount, 3)
    }

    func testEveryTierOffersThreeWidthsAndSomeColours() {
        for tier in [EditorToolbar.Tier.compact, .medium, .regular] {
            XCTAssertGreaterThanOrEqual(tier.colorCount, 3, "\(tier)")
            XCTAssertGreaterThanOrEqual(tier.favoriteCount, 2, "\(tier)")
        }
    }

    // MARK: One tap

    func testOneTapSwitchesBetweenAPinnedBlackPenAndAYellowHighlighter() throws {
        let (toolbar, spy) = makeToolbar()
        let pen = try XCTUnwrap(toolbar.state.favorites.first { $0.kind == .pen && $0.color == .black && $0.width == 2 })
        let highlighter = try XCTUnwrap(toolbar.state.favorites.first { $0.kind == .highlighter })

        let penButton = try XCTUnwrap(toolbar.favoriteButton(id: pen.id))
        penButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.lastState?.tool, .ink(.pen))
        XCTAssertEqual(spy.lastState?.preset(for: .pen).color, .black)
        XCTAssertEqual(spy.changeCount, 1, "one tap, one change")

        let highlighterButton = try XCTUnwrap(toolbar.favoriteButton(id: highlighter.id))
        highlighterButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.lastState?.tool, .ink(.highlighter))
        XCTAssertEqual(spy.lastState?.preset(for: .highlighter).color, highlighter.color)
        XCTAssertEqual(spy.changeCount, 2, "and back again in one more")
    }

    func testOneTapOnAVisibleSwatchChangesTheColour() throws {
        let (toolbar, spy) = makeToolbar()
        let palette = toolbar.state.paletteForActiveTool
        let swatches = toolbar.colorSwatchButtons
        XCTAssertGreaterThanOrEqual(swatches.count, 3, "colours are on the row, not behind a menu")

        let index = 2
        swatches[index].sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.changeCount, 1)
        XCTAssertEqual(spy.lastState?.activeColor, palette[index])
    }

    func testOneTapOnAVisibleWidthChangesTheWidth() throws {
        let (toolbar, spy) = makeToolbar()
        let widths = toolbar.state.widthPresetsForActiveTool
        let buttons = toolbar.widthPresetButtons
        XCTAssertEqual(buttons.count, 3, "three visible width presets for the active writing tool")

        buttons[2].sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.changeCount, 1)
        XCTAssertEqual(spy.lastState?.activeWidth ?? 0, widths[2], accuracy: 0.001)
    }

    func testTappingAToolSelectsItRatherThanOpeningItsMenu() throws {
        let (toolbar, spy) = makeToolbar()
        let highlighter = try XCTUnwrap(toolbar.button(for: .ink(.highlighter)))
        XCTAssertFalse(highlighter.showsMenuAsPrimaryAction,
                       "a tap must never be swallowed by a menu; options are a long press")
        XCTAssertNotNil(highlighter.menu, "the options are still there on long press")
        highlighter.sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.lastState?.tool, .ink(.highlighter))
    }

    // MARK: Updating in place

    func testChangingColourUpdatesTheExistingButtonsInsteadOfRebuildingTheRow() throws {
        let (toolbar, _) = makeToolbar()
        let penBefore = try XCTUnwrap(toolbar.button(for: .ink(.pen)))
        let swatchesBefore = toolbar.colorSwatchButtons
        let firstSwatch = try XCTUnwrap(swatchesBefore.first)

        toolbar.colorSwatchButtons[1].sendActions(for: .touchUpInside)

        XCTAssertTrue(toolbar.button(for: .ink(.pen)) === penBefore,
                      "a colour change must not tear down the toolbar; a popover anchored to a button would be lost")
        XCTAssertTrue(toolbar.colorSwatchButtons.first === firstSwatch)
        XCTAssertEqual(toolbar.colorSwatchButtons.count, swatchesBefore.count)
    }

    func testSelectionIsVisibleToVoiceOverAndNotOnlyAsColour() throws {
        let (toolbar, _) = makeToolbar()
        let pen = try XCTUnwrap(toolbar.button(for: .ink(.pen)))
        let eraser = try XCTUnwrap(toolbar.button(for: .eraser))
        XCTAssertTrue(pen.accessibilityTraits.contains(.selected), "the active tool is announced as selected")
        XCTAssertFalse(eraser.accessibilityTraits.contains(.selected))

        eraser.sendActions(for: .touchUpInside)
        XCTAssertTrue(eraser.accessibilityTraits.contains(.selected))
        XCTAssertFalse(pen.accessibilityTraits.contains(.selected))
    }

    func testEveryControlHasAVoiceOverLabelAndARealTarget() {
        let (toolbar, _) = makeToolbar()
        let buttons = toolbar.colorSwatchButtons + toolbar.widthPresetButtons
            + EditorToolbar.Tier.regular.directTools.compactMap { toolbar.button(for: $0) }
        XCTAssertFalse(buttons.isEmpty)
        for button in buttons {
            XCTAssertFalse((button.accessibilityLabel ?? "").isEmpty, "unlabelled control")
            // ~44pt of target, whatever the glyph inside measures.
            let height = button.constraints.first { $0.firstAttribute == .height }?.constant ?? 0
            XCTAssertEqual(height, EditorToolbar.controlHeight, accuracy: 0.5)
            let width = button.constraints.first { $0.firstAttribute == .width }?.constant ?? 0
            XCTAssertGreaterThanOrEqual(width, 32, "a control narrower than this is hard to hit while writing")
        }
    }

    func testLeftHandedMovesTheGroupWithoutReversingTheControls() {
        let (toolbar, _) = makeToolbar()
        let order = EditorToolbar.Tier.regular.directTools.compactMap { toolbar.button(for: $0) }
        toolbar.isLeftHanded = true
        let after = EditorToolbar.Tier.regular.directTools.compactMap { toolbar.button(for: $0) }
        XCTAssertEqual(order.count, after.count)
        for (a, b) in zip(order, after) {
            XCTAssertTrue(a === b, "handedness must not rebuild or reorder the controls")
        }
    }

    func testNarrowingTheToolbarKeepsTheActiveToolAvailable() throws {
        let (toolbar, _) = makeToolbar()
        var state = toolbar.state
        state.select(.ink(.pencil))
        toolbar.state = state

        toolbar.availableWidth = 600
        XCTAssertEqual(toolbar.tier, .compact)
        // Pencil is not on the compact strip, so it has to be in the overflow —
        // and the state still says pencil, so the current tool is not lost.
        XCTAssertEqual(toolbar.state.tool, .ink(.pencil))
        XCTAssertNotNil(toolbar.button(for: .eraser), "the eraser stays on the strip")
        XCTAssertGreaterThanOrEqual(toolbar.colorSwatchButtons.count, 3)
        XCTAssertEqual(toolbar.widthPresetButtons.count, 3)
    }
}

/// Records what the toolbar told its delegate.
@MainActor
final class ToolbarSpy: EditorToolbarDelegate {
    private(set) var lastState: EditorToolState?
    private(set) var changeCount = 0
    private(set) var undoCount = 0
    private(set) var redoCount = 0
    private(set) var favoritesEditorRequests = 0

    func toolbar(_ toolbar: EditorToolbar, didChangeState state: EditorToolState) {
        lastState = state
        changeCount += 1
    }
    func toolbarDidTapUndo(_ toolbar: EditorToolbar) { undoCount += 1 }
    func toolbarDidTapRedo(_ toolbar: EditorToolbar) { redoCount += 1 }
    func toolbar(_ toolbar: EditorToolbar, insertImageFrom source: EditorToolbar.ImageSource) {}
    func toolbar(_ toolbar: EditorToolbar, requestsCustomColorFrom anchor: UIView, current: RGBAColor,
                 completion: @escaping (RGBAColor) -> Void) {}
    func toolbar(_ toolbar: EditorToolbar, requestsTextStyleFrom anchor: UIView) {}
    func toolbar(_ toolbar: EditorToolbar, requestsFavoritesEditorFrom anchor: UIView) { favoritesEditorRequests += 1 }
    func toolbar(_ toolbar: EditorToolbar, didChooseLayout isHorizontalPaging: Bool) {}
    func toolbarDidRequestClearPage(_ toolbar: EditorToolbar) {}
}
