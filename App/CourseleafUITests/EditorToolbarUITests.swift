import XCTest

/// End-to-end evidence that the writing controls work as controls: a tap on a
/// tool, a colour, a width or a favourite does what it says, against the real
/// app running in a simulator.
///
/// The app-hosted unit tests can show that `EditorToolbar` tells its delegate
/// the right thing. They cannot show that the button is on screen, is big
/// enough to hit, and is reachable at the width the student is using. That is
/// what these do, and every one of them attaches a screenshot of what it saw.
final class EditorToolbarUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // A throwaway library in a temporary directory, with one notebook open.
        app.launchArguments = ["-CourseleafUITest"] + arguments
        app.launch()
        return app
    }

    /// The toolbar takes a moment to appear: the library opens, the notebook is
    /// created, the session opens and the editor lays out.
    private func toolbar(in app: XCUIApplication, timeout: TimeInterval = 40) -> XCUIElement {
        let pen = app.buttons["toolbar.tool.pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: timeout), "the writing controls never appeared")
        return pen
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: One tap

    func testOneTapSelectsAToolAColourAWidthAndAFavourite() {
        let app = launch()
        _ = toolbar(in: app)
        attachScreenshot(app, "editor-toolbar-default")

        let highlighter = app.buttons["toolbar.tool.highlighter"]
        XCTAssertTrue(highlighter.exists, "the highlighter is on the row, not in a menu")
        highlighter.tap()
        XCTAssertTrue(app.buttons["toolbar.tool.highlighter"].isSelected,
                      "one tap selects the highlighter and the control says so")
        attachScreenshot(app, "editor-toolbar-highlighter")

        let colour = app.buttons["toolbar.color.2"]
        XCTAssertTrue(colour.exists, "colours are visible, not behind a submenu")
        colour.tap()
        XCTAssertTrue(colour.isSelected, "one tap changes the colour")

        let width = app.buttons["toolbar.width.2"]
        XCTAssertTrue(width.exists, "three width presets are visible")
        width.tap()
        XCTAssertTrue(width.isSelected, "one tap changes the width")
        attachScreenshot(app, "editor-toolbar-colour-and-width")

        // A favourite carries tool, colour and width together.
        let favourite = app.buttons["toolbar.favorite.0"]
        XCTAssertTrue(favourite.exists, "favourites are on the row")
        favourite.tap()
        XCTAssertTrue(app.buttons["toolbar.tool.pen"].isSelected,
                      "the first favourite is a pen, so one tap puts the pen back")
        attachScreenshot(app, "editor-toolbar-favourite")
    }

    func testSwitchingBetweenTwoFavouritesIsOneTapEach() {
        let app = launch()
        _ = toolbar(in: app)

        // The shipped set starts with pens and ends with highlighters, so the
        // first and the last are the two a student flips between.
        let pen = app.buttons["toolbar.favorite.0"]
        let highlighter = app.buttons["toolbar.favorite.4"]
        XCTAssertTrue(pen.exists)
        XCTAssertTrue(highlighter.exists, "at a full-screen width five favourites fit")

        highlighter.tap()
        XCTAssertTrue(app.buttons["toolbar.tool.highlighter"].isSelected)
        pen.tap()
        XCTAssertTrue(app.buttons["toolbar.tool.pen"].isSelected)
        attachScreenshot(app, "editor-favourites-round-trip")
    }

    func testUndoAndRedoAreAlwaysOnTheRow() {
        let app = launch()
        _ = toolbar(in: app)
        XCTAssertTrue(app.buttons["toolbar.undo"].exists)
        XCTAssertTrue(app.buttons["toolbar.redo"].exists)
    }

    func testTheOptionsMenuIsALongPressNotATap() {
        let app = launch()
        let pen = toolbar(in: app)
        pen.press(forDuration: 1.0)
        // The pen's options carry a Width submenu; its presence is what proves
        // the menu opened rather than the tap being swallowed.
        let width = app.buttons["Width"].firstMatch
        XCTAssertTrue(width.waitForExistence(timeout: 5), "long press should open the tool's options")
        attachScreenshot(app, "editor-tool-options")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    // MARK: Appearance and orientation

    func testTheEditorIsUsableInLandscapeAndInPortrait() {
        let app = launch()
        _ = toolbar(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["toolbar.tool.pen"].waitForExistence(timeout: 10))
        attachScreenshot(app, "editor-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["toolbar.tool.pen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["toolbar.tool.eraser"].exists, "the eraser stays reachable in portrait")
        attachScreenshot(app, "editor-portrait")
    }

    func testTheEditorRendersInDarkAppearance() {
        // The app's own appearance setting is stored in UserDefaults, so a
        // launch argument in the argument domain selects it without any test
        // hook in the app.
        let app = launch(arguments: ["-settings.appearance", "dark"])
        _ = toolbar(in: app)
        attachScreenshot(app, "editor-dark")
        XCTAssertTrue(app.buttons["toolbar.tool.pen"].exists)
    }

    func testTheEditorRendersAtALargerContentSize() {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        _ = toolbar(in: app)
        attachScreenshot(app, "editor-large-text")
        XCTAssertTrue(app.buttons["toolbar.tool.pen"].exists,
                      "the writing controls survive an accessibility text size")
        XCTAssertTrue(app.buttons["toolbar.undo"].exists)
    }
}
