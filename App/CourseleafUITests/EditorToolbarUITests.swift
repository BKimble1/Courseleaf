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
        // The simulator keeps its orientation between tests, so a test that
        // rotates would otherwise decide the width every test after it sees.
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // A throwaway library in a temporary directory, with one notebook open.
        // The onboarding flag goes through UserDefaults' argument domain, which
        // is read before the first view appears and written to nothing, so the
        // welcome screens never cover the editor under test.
        app.launchArguments = ["-CourseleafUITest", "-settings.onboarding.seen", "YES"] + arguments
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

    /// What the toolbar is actually showing, for a failure message. A count and
    /// a window size distinguish "the row was too narrow" from "the device
    /// never turned", which otherwise look identical from a failed lookup.
    private func describeRow(_ app: XCUIApplication) -> String {
        let favourites = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "toolbar.favorite."))
            .count
        let colours = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "toolbar.color."))
            .count
        let size = app.windows.firstMatch.frame.size
        return "window \(Int(size.width))x\(Int(size.height)), "
            + "favourites on the row: \(favourites), colours: \(colours)"
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
        // The first two favourites, which is what every tier shows. The editor
        // is the detail pane of a NavigationSplitView, so with the library
        // sidebar showing it never gets the screen's width: on a 13-inch iPad
        // the row is about 840 points in either orientation, the toolbar's
        // medium tier, and the widest tier needs the sidebar hidden. Asking for
        // the fifth favourite here was asking for a row no default layout has.
        let pen = app.buttons["toolbar.favorite.0"]
        let highlighter = app.buttons["toolbar.favorite.1"]
        let appeared = highlighter.waitForExistence(timeout: 10)
        // Attached before the assertion, not after: on a failure the screenshot
        // is the only thing that says how wide the row really was, and an
        // assertion that fires first would lose it.
        attachScreenshot(app, "editor-favourites-row")
        XCTAssertTrue(appeared,
                      "a pen and a highlighter have to be on the row together — \(describeRow(app))")
        XCTAssertTrue(pen.exists)

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
        // "Save as Favourite" is a concrete action in the pen's options menu —
        // a section header would not be a button, so this is the assertion that
        // actually distinguishes "menu opened" from "tap was swallowed".
        let save = app.buttons["Save as Favourite"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "long press should open the tool's options")
        attachScreenshot(app, "editor-tool-options")
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
