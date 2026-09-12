# Feature register

Every benchmark record F001–F112 from `docs/research/Goodnotes_Research_and_App_Plan.md`,
mapped to a Courseleaf milestone and an honest status. Updated 2026-09-12 for the
premium-editor release; see `docs/FEATURE_COVERAGE.md` for the same ground grouped
by category with gaps and recommended phases, and `docs/VALIDATION.md` for the runs
each status rests on. The portable core (DocumentCore, PageGeometry, Editing, Persistence,
Archive, Catalog, Workspace, Fixtures) passes 219 Linux tests, and the iPad app
under `App/` is written: it builds for the iOS 26.2 simulator with Xcode 26.3 and
runs 63 `CourseleafTests` with 0 failures in CI job `app-ios-simulator` (run
34694155083, commit `7627793`). Both runs are recorded in `docs/VALIDATION.md`.
**No row is `device-tested` and none may become one here: this project has no
physical iPad and no Apple Pencil, so A02, A03, A06, A16, A17 and A19 stay open.**

## Legend

**Research target** is the roadmap word from the research file (Launch, Launch subset,
Personal, Advanced, Platform, Separate, Retired, …). **Milestone** is where Courseleaf
does the work: launch gates G0–G6, post-launch backlog cards P1–P8 (`docs/BACKLOG.md`),
`Separate` (independent product decision), `Unconfirmed`, or `Retired`.

**Status** uses exactly one of: `planned`, `in progress`, `implemented`, `unit-tested`,
`simulator-tested`, `device-tested`, `blocked`, `deferred`, `retired`.

- `planned` — agreed scope, no code. **A planned item is not implemented.**
- `in progress` — code is being written; nothing verified yet.
- `implemented` — code exists and compiles. **A compiling item is not device-verified.**
- `unit-tested` — Linux/macOS `swift test` evidence for the portable logic.
- `simulator-tested` — CI `app-ios-simulator` (Xcode, iPad simulator) evidence.
- `device-tested` — verified on a physical iPad with Apple Pencil (`docs/VALIDATION.md`).
- `blocked` — cannot progress without an external decision, device or account.
- `deferred` — kept in the backlog with a card; not built at launch.
- `retired` — historical benchmark; not a requirement.

**Owner / evidence** names the module that owns the item (Persistence, Archive, Catalog,
PageGeometry, Editing, Workspace, App/Library, App/Editor, App/Ink, App/Interchange,
App/Search, App/Review, App/Export, App/Settings) and the test that demonstrates it.
Names under `Tests/` are Linux tests from the 219-test run recorded in
`docs/VALIDATION.md` → Portable test runs ("portable: passing"). Names from
`AppShellTests`, `EditorInkEngineTests`, `EditorLayoutTests`, `EditorSearchTests`,
`EditorToolStateTests`, `InterchangeInspectorTests`, `InterchangeExportTests` and
`InterchangeOCRTests` are `App/CourseleafTests` cases from the 63-test iPad
simulator run recorded in the same file. A status moves right only when the
evidence exists and is named here; "not written" in this column means no such code
exists, and it is removed the moment it does.

**Composite rows.** A row's status is that of its least-advanced required part. A
capability whose portable logic passes its Linux tests but whose `App/` screen has
no test is `implemented`, and the evidence column says which part is covered and
which is not. A row is `simulator-tested` only where a named `CourseleafTests` case
exercises the app code the row is about; where such a case covers only a
neighbouring component it is cited as partial evidence and the row stays
`implemented`. A row with a required part that is not written at all stays
`in progress` (F007, F059, F066). Only rows with no app part (C003, C004) carry
`unit-tested`.

## Library and document organization

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F001 | Folders (nested courses/folders) | Launch | G1 | simulator-tested | Persistence `LibraryStore`, Workspace `createFolder`/`folders(in:)`, App/Library `LibrarySidebarView` over `LibraryViewModel`. Simulator: `AppShellTests.testLibraryViewModelCreatesAFolderAndAQuickNote` creates a course through a real `LibraryService` and lists it. Portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`, `testDeletingAFolderTrashesItsSubtreeAndRestoreBringsItBack`; nesting under a parent is exercised on Linux only (`LibraryServiceTests.testReviewQueuePerCourseAndUnfiledWithMarkAndReopen` builds Physics/Week 1) |
| F002 | Folder appearance (colours, icons) | Personal | P1 | deferred | BACKLOG P1. `Folder.color` exists in the model; icon choice and a picker UI are not launch scope |
| F003 | Library views (grid, list) | Launch | G1 | implemented | App/Library `LibraryContentView` draws both layouts from `LibraryViewModel.Presentation`, sorted by modified/created/title/page count. Simulator `AppShellTests.testLibraryViewModelListsANotebookItCreated` covers listing and sorting against a real service; neither layout itself is covered by a test |
| F004 | Item management (rename, move, delete) | Launch | G1 | implemented | Persistence `LibraryStore` and Workspace `rename`/`move`/`duplicate`/`delete` (portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`, `testDuplicateYieldsDistinctIdentifiersAndEqualContent`, `LibraryServiceTests.testMoveRenameFavoriteCoverAndDuplicateWhileOpenAndClosed`); App/Library `LibraryViewModel` actions and `FolderPickerView` are written and compile, and no simulator test names them |
| F005 | Favorites (documents, folders; pages via bookmarks) | Launch | G1 | implemented | DocumentCore `Document.isFavorite`/`Folder.isFavorite`, Workspace `setFavorite` and `LibraryScope.favorites` (portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`, `LibraryServiceTests.testMoveRenameFavoriteCoverAndDuplicateWhileOpenAndClosed`); the sidebar scope mapping is covered by `AppShellTests.testSidebarSelectionMapsToLibraryScopes`, the favourite action in `LibraryViewModel` is not. Page favourites are bookmarks (F011) |
| F006 | Trash (recover documents, folders, pages; empty) | Launch | G1 | implemented | Persistence trash (portable: passing — `LibraryStoreTests.testTrashRestorePurgeAndEmptyTrash`); page trash in Editing (portable: passing — `DocumentEditorTests.testReviewItemsOfDeletedPagesAreHiddenUntilRestore`, `testRestoreUsesMinOfOriginalIndexAndPageCountAndClampsLastViewed`); Workspace `restore`/`purge`/`emptyTrash` (`LibraryServiceTests.testTrashRestoreAndPurgeThroughTheService`); App/Library `TrashView`, the navigator's deleted-pages tab and Settings → Empty Trash are written and untested (`AppShellTests.testSidebarSelectionMapsToLibraryScopes` covers only the trash scope) |
| F007 | Page order (reorder, copy, move, combine) | Launch | G1/G2 | in progress | Within a notebook this is done: Editing `movePage`/`duplicatePage`/`insertPages` (portable: passing — `DocumentEditorTests.testA11PageOperationsKeepOtherPagesAndIDsStable`, `testMakeDuplicateAndCopiesOfPagesUseFreshIDsAndSharedAssets`, `LibraryServiceTests.testInsertPDFPagesAfterChosenPageKeepsExistingPageIDsInOrder`) driven by App/Editor `PageNavigatorViewController` (drag to reorder, insert, duplicate, delete, restore). Moving or copying pages **between** notebooks is not written: Editing `copiesOfPages` has no caller in `App/` |
| F008 | Covers | Launch | G1 | simulator-tested | DocumentCore `CoverStyle` (8 original palettes × 4 patterns); App/Design `CoverArt`/`CoverView` render them and `CoverPickerList`/`CoverPickerSheet` choose them. Simulator: `AppShellTests.testEveryCoverCombinationProducesGeometry` (every combination draws, spine included), `testCoverPalettesAreDistinct`, and `testLibraryViewModelListsANotebookItCreated` (a created notebook keeps its cover). Portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover` |
| F009 | Templates (custom template/cover import) | Launch | G1 built-in; P1 custom import | implemented | Built-in originals only: `PaperTemplate.preset` in App/Library `NewNotebookSheet` and `CoverArt.allStyles` in `CoverPickerList` (see F008, F010). Importing a user template or cover is not written and stays BACKLOG P1 |
| F010 | Paper choices (blank, ruled, grid, Cornell, …) | Launch | G1 | simulator-tested | PageGeometry `TemplateGeometry` (blank, lined, grid, dotted, cornell, engineering in page points; portable: passing — `TemplateGeometryTests`, 6 tests). App/Design `PagePreviewGeometry` and App/Editor `PageBackgroundLayer`/`ThumbnailCache`/`PageCompositor` draw those primitives; simulator `AppShellTests.testTemplatePreviewGeometryMatchesThePageGeometryModule` checks every `PaperKind` against the module and `testTemplatePreviewFitsThePageIntoItsBox` the fit. The editor's background layer has no test of its own. Planner paper not at launch |

## Navigation and the writing environment

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F011 | Page navigation (thumbnails, bookmarks, outlines) | Launch | G2 | implemented | App/Editor `PageNavigatorViewController`: thumbnail grid over `ThumbnailCache`, a bookmarks tab over `Page.isBookmarked` (Editing `setPageBookmark`) and the PDF outline tab (F012); `scrollToPage`/`goToPage` in `NotebookEditorViewController`. No simulator test covers the navigator |
| F012 | Imported outlines (PDF table of contents) | Launch | G3 | implemented | App/Editor navigator flattens PDFKit `outlineRoot` onto page indices. Outline reading is covered on the simulator by `InterchangeInspectorTests.testPDFKitInspectorReadsOutlineTitlesTextPresenceAndImageOnlyPages` and on Linux by `FixtureCatalogTests.testTextAndOutlineFixtureContainsTitles`, `PDFFixtureTests.testInspectorRoundTripsBoxesRotationOutlineAndText` over `Fixtures/text-and-outline.pdf`; the outline tab itself has no test |
| F013 | Custom outlines | Personal | P1 | deferred | BACKLOG P1 |
| F014 | Canvas navigation (zoom, scroll direction) | Launch | G2 | simulator-tested | App/Editor `PageLayout`, `PageScrollView` and `EditorZoom`. Simulator: `EditorLayoutTests.testVerticalLayoutStacksPagesWithGapsAndPadding`, `testContentOffsetShowingPagePutsItAtTheTopOfTheViewport`, `testFitToWidthZoomFillsTheViewport`, `testEditorZoomClampsToTheContract`, `testPageIndexAtPointFallsBackToTheNearestPage` and `testHorizontalPagedLayoutGivesEachPageOneSlot`; scrolling stays bounded — `testPoolNeverExceedsItsLiveLimitScrollingThroughThreeHundredPages` and `testLiveIndicesStayWithinTheLimitAndFollowTheFocusPage` keep at most three live `PKCanvasView`s across 300 pages (the simulator half of A06). Portable: passing — `PageMappingTests.testCanvasMappingAppliesZoomAndOffset`. Horizontal paging now ships (toolbar → layout menu); `docs/BACKLOG.md` P1 still lists it as deferred and is out of date |
| F015 | Reading mode | Launch | G2 | implemented | App/Editor `isReadingMode` disables drawing and object interaction (`PageCanvasView` interaction policy, toolbar collapses) and a tap follows a PDF link annotation's URL or internal destination (`canvas(_:readingModeTapAt:)`). No test covers it |
| F016 | Multiple windows | Personal | P1 | deferred | BACKLOG P1; `UIApplicationSupportsMultipleScenes` is false at launch |
| F017 | Toolbar layout customization | Personal | P1 | deferred | BACKLOG P1 |
| F018 | Keyboard controls (shortcuts) | Launch | G2 | implemented | App/Editor `keyCommands` (undo, redo, zoom in/out/fit width, select all, escape, next/previous page, page up/down) and App-level `CourseleafApp` commands (new notebook ⌘N, quick note ⇧⌘N, find ⌘F, settings ⌘,). No test covers them; A17 also needs a device |
| F019 | Zoom Window | Personal | P1 | deferred | BACKLOG P1 |
| F020 | Quick capture | Launch | G1 | simulator-tested | DocumentCore `DocumentKind.quickNote`; Workspace `createQuickNote`/`LibraryScope.inbox`; App/Library quick note action and Inbox scope. Simulator: `AppShellTests.testLibraryViewModelCreatesAFolderAndAQuickNote` (the note lands in the inbox until it is filed) and `testSidebarSelectionMapsToLibraryScopes` |
| F021 | Home widgets | Personal | P1 | deferred | BACKLOG P1 |

## Pens and input

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F022 | Pen styles (fountain, ball, brush) | Launch subset | G2 | simulator-tested | App/Editor `InkToolKind.pen` → `PKInkingTool(.pen)`, labelled "Pen"; App/Ink `PencilKitInkEngine` draws it. No fountain or brush simulation — that stays BACKLOG P2. Simulator: `EditorToolStateTests.testPresetWidthIsClampedToThePencilKitRange` (every ink kind's presets inside its advertised bounds) and `testToolStateRoundTripsThroughItsStore` (the pen's width and colour survive a relaunch); `testPencilKitToolFollowsTheSelectedTool` asserts the ink-type mapping for pencil and highlighter |
| F023 | Pencil (graphite) | Launch | G2 | simulator-tested | App/Editor `InkToolKind.pencil` → `PKInkingTool(.pencil)` through App/Ink `PencilKitInkEngine`; simulator `EditorToolStateTests.testPencilKitToolFollowsTheSelectedTool` asserts the `.pencil` ink type |
| F024 | Stroke patterns (dashed, dotted) | Personal | P2 | deferred | BACKLOG P2 |
| F025 | Thickness presets | Launch | G2 | simulator-tested | App/Editor `InkToolKind.widthPresets`/`widthBounds` per tool, stored by `EditorToolStateStore`. **Three presets for the active writing tool are now on the toolbar itself**, so a width change is one tap (`EditorToolbar.makeWidthButton`, glyph drawn at the preset's own thickness). Simulator: `EditorToolbarInteractionTests.testOneTapOnAVisibleWidthChangesTheWidth`, `EditorToolStateMigrationTests.testOneTapOnAColourOrWidthChangesTheActiveTool`; UI: `EditorToolbarUITests.testOneTapSelectsAToolAColourAWidthAndAFavourite`; plus the existing `EditorToolStateTests` clamping and round-trip cases |
| F026 | Color controls | Launch subset | G2 | simulator-tested | App/Editor `EditorToolState` presets, recent colours and a `UIColorPickerViewController` custom colour. **A row of colour swatches is on the toolbar**, showing the active tool's palette (highlighter colours for a highlighter), so an ordinary colour change never opens a submenu. Simulator: `EditorToolbarInteractionTests.testOneTapOnAVisibleSwatchChangesTheColour`, `EditorToolStateMigrationTests.testOneTapOnAColourOrWidthChangesTheActiveTool`, `EditorToolStateTests.testRecentColorsAreMostRecentFirstAndBounded`; UI: `EditorToolbarUITests`. An eyedropper stays BACKLOG P1 |
| F027 | Ink response (pressure, tip, stabilization) | Personal | P2 | deferred | BACKLOG P2; PencilKit pressure response is inherent, no extra controls |
| F028 | Highlighter | Launch | G2 | simulator-tested | App/Editor `InkToolKind.highlighter` → `PKInkingTool(.marker)`; simulator `EditorToolStateTests.testPencilKitToolFollowsTheSelectedTool` asserts the `.marker` ink type and `testPresetWidthIsClampedToThePencilKitRange` its wider band. Band order portable (`PageMappingTests.testTapePolicyAndCompositingBands`). Marker blending in an export is not separately asserted by `InterchangeExportTests` (A05/A12) |
| F029 | Stylus and touch (finger drawing, palm rejection) | Launch | G2 | simulator-tested | App/Editor `EditorInputSettings` → `PKCanvasView.drawingPolicy` (pencilOnly default, anyInput opt-in). Simulator: `EditorToolStateTests.testDrawingPolicyFollowsTheInputSettings`, `AppShellTests.testSettingsDefaults` and `testSettingsPersistAcrossStores` (the Settings toggle reaches the canvas policy). Palm rejection is PencilKit's own and remains a device gate (A03/A16) with no device here |
| F030 | Hover preview | Personal | P2 | deferred | BACKLOG P2 |
| F031 | Pencil Pro (squeeze, barrel roll) | Personal | P2 | deferred | BACKLOG P2 |

## Erasing and selection

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F032 | Eraser variants | Launch subset | G2 | simulator-tested | App/Editor pixel (`PKEraserTool(.bitmap)`) and whole-stroke (`.vector`) modes — simulator `EditorToolStateTests.testPencilKitToolFollowsTheSelectedTool`. Erase masks survive transform and recolour and erased ink stays unselectable — simulator `EditorInkEngineTests.testTransformingAStrokeConcatenatesTheTransformAndKeepsTheEraseMask`, `testRecoloringKeepsPathTransformAndMaskAndOnlyChangesTheInkColour`, `testStrokeIndicesIntersectingSelectsOnlyStrokesWithVisibleInkInTheRect`; portable `ReferenceInkTests.testPartialEraseThenMoveAndRecolorKeepsMask`, `InkFixtureTests.testPartiallyErasedSampleKeepsMasksThroughTransformAndRoundTrip` (A10). Segment eraser stays BACKLOG P2 |
| F033 | Erase filters | Personal | P2 | deferred | BACKLOG P2 |
| F034 | Tool return after erasing | Personal | P2 | implemented | Applies to scribble erase only, which is where it matters: crossing writing out never changes the tool, because the gesture is made *with* the writing tool (App/Editor `applyScribbleErase` does not touch `toolState`). Returning from the *eraser tool* to the last pen automatically stays BACKLOG P2 |
| F035 | Clear page | Launch | G2 | implemented | Editing `clearPage` (portable: passing — `DocumentEditorTests.testClearPageRemovesObjectsAndEmptiesInkButKeepsMetadata`); App/Editor `toolbarDidRequestClearPage` clears the canvas behind a confirmation alert and leaves the page metadata. No test covers the menu item |
| F036 | Scribble to erase | Personal | P2 | unit-tested | Editing `ScribbleEraseRecognizer` + `StrokeGeometry`: a geometric heuristic (reversals along the stroke's own principal axis, how often it retraces its span, band-versus-area, overlap with existing ink, speed as a tie-break) — explicitly **not** machine learning. Off by default; Settings ▸ Writing gestures. Pen and pencil only; objects, PDF backgrounds, images, text and tape are never targets. The command scribble goes with the strokes it crossed out, in one undoable operation, so undo restores the page without it. Portable: `ScribbleEraseTests` — a five-pass cross-out erases exactly the word it crossed at every rotation and scale, and a sine wave, repeated letters, shading, engineering hatching, a zigzag drawing, a wide summation sign and a scribble on blank paper all survive. Bounding-box overlap alone never erases (`testOnlyStrokesActuallyCrossedAreErasedNotMerelyOverlappingBounds`). No device evidence |
| F037 | Circle to select | Personal | P2 | deferred | BACKLOG P2 |
| F038 | Lasso filters | Launch | G2 | simulator-tested | Editing `SelectionFilter`/`SelectionRules` (portable: passing — `SelectionTests.testRectHitTestUsesRotatedBoundsSkipsLockedAndAppliesFilters`, `testPolygonHitTestRequiresWholeBoundsInside`); App/Editor `SelectionController` (freehand and rectangle) picks ink through `PencilKitDrawing.strokeIndices(inside:)`/`(intersecting:)` — simulator `EditorInkEngineTests.testStrokeIndicesInsidePolygonRequiresTheWholeStroke` and `testStrokeIndicesIntersectingSelectsOnlyStrokesWithVisibleInkInTheRect`; the chosen filter persists (`EditorToolStateTests.testToolStateRoundTripsThroughItsStore`). The drag gestures themselves have no test |
| F039 | Object editing (transform, recolor, copy, delete, align, capture) | Launch | G2 | implemented | Editing `transformObjects`, `SelectionAction` (portable: passing — `SelectionTests.testAvailableActionsMatrix`, `testClipboardPasteGivesFreshIDsAndOffsets`, `DocumentEditorTests.testTransformRules`); App/Editor `SelectionController` offers copy, cut, paste, duplicate, recolour, lock, stacking and delete with resize/rotate handles. Ink transform and recolour are simulator-covered (`EditorInkEngineTests.testTransformingAStrokeConcatenatesTheTransformAndKeepsTheEraseMask`, `testTransformingOneStrokeLeavesTheOthersAlone`, `testRecoloringKeepsPathTransformAndMaskAndOnlyChangesTheInkColour`); the object handle math (`SelectionController.resizeTransform`) has no test. Align and capture-as-image stay BACKLOG P2 |
| F040 | Handwriting reflow | Advanced | P4 | deferred | BACKLOG P4 |
| F041 | Undo and redo | Launch | G2 | simulator-tested | Editing `DocumentEditor` grouped undo (portable: passing — `DocumentEditorTests.testA09GroupedMoveOfObjectsAndInkUndoesInOneStepAndRedoReapplies`, `testNestedGroupsFormOneRecordAndFailedCommandLeavesSnapshotUntouched`, `testRedoIsClearedByANewCommand`) and through a session (`LibraryServiceTests.testUndoRedoThroughSessionArePersisted`). App/Editor: the undo boundary is the end of a pen gesture, not the save timer; pending ink is committed *before* `canUndo` is consulted; PencilKit's per-stroke registrations go to each canvas's own `UndoManager` (`InkCanvasHostView`) so the editor's belongs to text editing; one bridging action keeps the Edit menu and the three-finger swipe on the document's history. Simulator: `AppFlowTests.testGroupedMoveOfMixedSelectionUndoesInOneStepThroughTheEditorViewController`; `EditorReliabilityTests.testAFirstStrokeCanBeUndoneImmediately`, `testTwoQuickStrokesAreTwoUndoSteps`, `testUndoingClearPageRestoresTheStrokeThatWasStillOnScreen`, `testTheResponderChainManagerStepsTheDocumentsHistory`, `testPencilKitRegistrationsNeverReachTheEditorsUndoManager`. A09 |

## Text and visual objects

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F042 | Text boxes | Launch | G2 | implemented | DocumentCore `TextContent` (size, weight, design, alignment, colour); App/Editor `ObjectViews` edits text in place and `EditorToolState.textStyle` carries the defaults — the style survives a relaunch (`EditorToolStateTests.testToolStateRoundTripsThroughItsStore`) and typed text is findable (`EditorSearchTests.testFindsTypedTextTapeLabelsAndProblemMetadata`). The in-place editor is untested |
| F043 | Full-page typing | Personal | P2 | deferred | BACKLOG P2 |
| F044 | Images and camera | Launch | G2/G3 | implemented | DocumentCore `ImageContent` (crop, opacity); App/Editor `ImageInsertionController` (photo picker, camera, Files, crop) over App/Interchange `ImageImportBuilder`/`ImageIOInspector`. Simulator `InterchangeInspectorTests.testImageIOInspectorReadsMinimalPNGAndJPEGDimensions` covers the inspector only; the camera and limited-photos paths need a device (A16) |
| F045 | Elements (reusable selections) | Personal | P2 | deferred | BACKLOG P2 |
| F046 | Collection exchange | Personal | P2 | deferred | BACKLOG P2 |
| F047 | Animated GIFs | Platform | P8 | deferred | BACKLOG P8 |
| F048 | Object locking | Launch | G2 | implemented | Editing `setObjectsLocked`, locked objects excluded from hit tests and transforms (portable: passing — `DocumentEditorTests.testLockedObjectsRejectTransformRemoveAndUpdateButAcceptUnlock`, `SelectionTests.testRectHitTestUsesRotatedBoundsSkipsLockedAndAppliesFilters`); App/Editor Lock/Unlock menu items are written and untested |
| F049 | Object stacking (front/back, groups) | Launch | G2 | implemented | Editing `bringToFront`/`sendToBack`/`reorderObject` within a band (portable: passing — `DocumentEditorTests.testAddRemoveUpdateReorderObjectsOnTheSingleArray`, `SelectionTests.testPointHitTestIsExactForRotationAndFollowsCompositingOrder`); App/Editor Bring to Front/Send to Back menu items are written and untested; grouping stays BACKLOG P2. Limitation: ink band is fixed (PRODUCT_SPEC §6) |
| F050 | Sticky notes | Personal | P2 | deferred | BACKLOG P2 |

## Geometry and layer controls

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F051 | Handwriting shape recognition | Launch subset | G2 | unit-tested | Two separate things, kept separate. **Manual insertion** (what shipped before, and what this row used to overstate): the shape tool draws a `ShapeContent` line, arrow, rectangle or ellipse from an overlay drag (App/Editor `SelectionController.creationShape`). **Recognition**: Editing `ShapeRecognizer` fits a freehand stroke to a straight line, an ellipse (circle when the radii agree) or a rectangle (square when the sides agree) and refuses everything else; the corrected shape is committed as ordinary ink in the same tool, so it erases, lassos, exports and prints like handwriting and adds no new persisted type. Triangles and arrows are deliberately absent until their geometry, selection and export are tested too. Portable: `ShapeRecognitionTests` — a 30° diagonal keeps its angle, a 2° line snaps flat and a 10° line does not, a hand-drawn circle becomes a circle, a rotated rectangle keeps its rotation, small and large squares behave the same, and a scribble, a sine wave, handwriting loops and a 12-point flick are all refused. No device evidence |
| F052 | Draw and hold | Personal | P2 | implemented | Hold at the end of a freehand shape and the corrected shape is previewed over the page; dragging on resizes it; lifting commits it as one undo step; dragging it back below the minimum size cancels and keeps the stroke as drawn. The in-progress path is observed with a `UIGestureRecognizer` that records the same touches and never recognises (`StrokeSamplingGestureRecognizer`) — PencilKit exposes no public API for a stroke in progress, and this is the documented way to watch touches without delaying or cancelling them. Settings ▸ Writing gestures; on by default. Portable geometry for the adjustment is `ShapeAdjustment.dragging`. The hold timing itself has no simulator test and no device evidence |
| F053 | Ruler | Personal | P2 | deferred | BACKLOG P2 |
| F054 | Connectors | Personal | P2 | deferred | BACKLOG P2 |
| F055 | Quick diagramming | Personal | P2 | deferred | BACKLOG P2 |
| F056 | Layers | Personal | P2 | deferred | BACKLOG P2; `Page.inkLayers` is an array but launch uses one layer |

## Search and recognition

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F057 | Library search | Launch | G4 | simulator-tested | Catalog FTS5 (portable: passing — `CatalogDatabaseTests.testRebuildFromSnapshotsThenQuery`, `testSearchDistinguishesNoMatchesFromNotYetIndexed`, `testRankingOrderTitleTypedPDFTextRecognized`, `FTSQueryTests`) and Workspace `search(_:scope:)` (`LibraryServiceTests.testSearchTypedHitsRecognizedRecordsInvalidationAndScopes`); App/Search `SearchView`/`SearchViewModel` (library, folder and notebook scopes, index-state rows, jump to the hit). Simulator [run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941): `AppFlowTests.testSearchGroupsHitsByNotebookHonoursScopeAndSeparatesNotYetIndexed` groups hits by notebook, narrows to a course scope, reports the not-yet-indexed count separately from a miss, and clears without searching on an empty query |
| F058 | Document search | Launch | G4 | simulator-tested | App/Editor `NotebookSearch` answers from the open snapshot and the page's source PDF without waiting for the index: simulator `EditorSearchTests.testFindsTypedTextTapeLabelsAndProblemMetadata`, `testSearchIgnoresShortQueriesAndNonTextObjects`, `testSearchIsCaseAndDiacriticInsensitive`, `testSearchRespectsItsLimit`, `testSnippetCentresOnTheMatchAndMarksTruncation`. Catalog-backed `SearchScope.document` is portable (`LibraryServiceTests.testSearchTypedHitsRecognizedRecordsInvalidationAndScopes`) |
| F059 | Handwriting conversion | Launch best effort | G4 | in progress | Recognition **for search** is built and measured: App/Interchange `VisionTextRecognizer` and `RecognitionQueue` (debounced, one page at a time, pausable) — simulator `InterchangeOCRTests.testCleanPrintedTextIsRecognizedAccurately` (character error rate < 0.15 on clean printed text), `testCorpusErrorRatesAreMeasuredAndReported`, `testRecognizedLinesCarryPageSpaceBoundsInsideThePage`, `testRecognitionReturnsNothingForABlankPageRatherThanFailing`, `testErrorRateMathIsCorrect`; stale-record invalidation portable (`CatalogDatabaseTests.testEditingPageRevisionDropsStaleRecognizedRecordsButKeepsTyped`). The editable **conversion** preview promised in PRODUCT_SPEC §6 is not written — no screen turns recognized text into editable text. The corpus is synthetic printed text, not handwriting: A15 still needs a student-written corpus on a device. Not a parity claim |
| F060 | Recognition languages | Launch English | G4 | simulator-tested | English only: App/Interchange `VisionTextRecognizer.recognitionLanguages = ["en-US"]` with language correction, writing `SearchRecord.language`. Simulator: `InterchangeOCRTests.testCleanPrintedTextIsRecognizedAccurately`, `testCorpusErrorRatesAreMeasuredAndReported` (English corpus, measured error rates) |
| F061 | Handwriting spelling | Advanced | P4 | deferred | BACKLOG P4 |
| F062 | Handwriting appearance (reflow, beautify) | Advanced | P4 | deferred | BACKLOG P4 |

## Import and export

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F063 | PDF and image import | Launch | G3 | simulator-tested | Workspace `importFiles`/`ImportDestination` (portable: passing — `LibraryServiceTests.testImportAlignmentFixturesMatchesSidecarGeometry`, `testImportLong300PagePDFCreatesOnePagePerPDFPage`, `testImportImageCreatesLetterWidthPageKeepingAspect`, `testMalformedAndEncryptedPDFsFailWithoutCreatingADocument`, `testImportCancellationLeavesLibraryUnchanged`; `PDFFixtureTests.testInspectorRejectsMalformedFixturesWithTheRightErrors`, `testInspectorReportsEncryptMarker`, `testInspectorReadsImageOnlyAndLongMixedFixtures`, `ImageFixtureTests`). App/Interchange `PDFKitInspector`/`ImageIOInspector` agree with the portable inspectors on the same fixtures — simulator `InterchangeInspectorTests.testPDFKitInspectorReportsTheSameBoxesAndRotationAsTheMinimalInspector`, `testPDFKitInspectorReadsOutlineTitlesTextPresenceAndImageOnlyPages`, `testPDFKitInspectorRejectsEncryptedGarbageAndOversizedFiles`, `testImageIOInspectorReadsMinimalPNGAndJPEGDimensions`. The Files picker and `ImportDestinationSheet` are untested |
| F064 | Office import | Platform | P8 | deferred | BACKLOG P8 |
| F065 | Native import | Own format only | G3 | implemented | Archive `ArchiveReader` (portable: passing — `ArchiveRoundTripTests`, 9 tests) and Workspace restore (`LibraryServiceTests.testExportArchiveAndRestoreAsCopyIsEqualModuloIdentifiers`); App/Library accepts `dev.courseleaf.archive` in its Files picker (`ImportSupport.importableTypes`) with no simulator test. No third-party notebook decoder (see `MIGRATION_FROM_GOODNOTES.md`) |
| F066 | Share and drag import | Launch | G3 | in progress | The Files picker is wired end to end: `LibraryContentView.fileImporter` → `ImportSupport.requests(forPickedURLs:)` → `SecurityScopedFileAccess.prepareForImport` into `Staging/` (staging cleanup portable: passing — `LibraryStoreTests.testOpenCreatesLayoutAndClearsStaging`). Drag and drop and "Open in" are **not** wired: `ImportSupport.loadRequests(from:stagingDirectory:)` and `request(forOpenedURL:)` exist but no view calls `onDrop` or `onOpenURL`, although `CFBundleDocumentTypes` is declared in `App/project.yml` |
| F067 | Email import | Platform | P8 | deferred | BACKLOG P8 |
| F068 | Scan documents | Launch | G3 | implemented | App/Interchange `DocumentScannerView` wraps `VNDocumentCameraViewController` and shows an explicit placeholder when scanning is unsupported or the camera is denied (`cameraAuthorization`). A simulator has no document camera, so only a device closes this and the permission path (A16) |
| F069 | PDF export | Launch | G3 | simulator-tested | App/Interchange `PDFExporter`/`PageCompositor` over PageGeometry `ExportGeometry`. Simulator: `InterchangeExportTests.testExportPlacesAnObjectWithinOnePointOfItsPageRect` (every edge within 1 pt of page space, A05), `testExportKeepsSourcePDFSquareAtItsExpectedPageRectForEveryRotationAndCrop` (A04 rotations and crop origins against the fixture sidecar), `testExportKeepsSourcePDFTextSearchable` (A12), `testExportingASubsetOfPagesKeepsOrderAndCount`, `testInkIsCompositedAtItsPageCoordinates`. Portable: passing — `PageMappingTests.testAlignmentFixturesAgreeWithSidecarWithin1e9`, `CanvasAndExportGeometryTests` |
| F070 | Image export and printing | Launch | G3 | simulator-tested | DocumentCore `ExportFormat.png/.jpeg`; App/Interchange `ImageExporter` (one image per page at 144 dpi) and `PrintCoordinator` (`UIPrintInteractionController` over the same renderer), both offered by App/Export `ExportSheet`. Simulator [run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941): `AppFlowTests.testImageExportRendersTheObjectAtItsPageRectAndEncodesPNGAndJPEG` (every edge within 1 pt of page space, the pixel size the raster scale implies, PNG and JPEG signatures, a PDF request refused), `testImageExportWritesOnePerSelectedPageInDocumentOrder` (one file per selected page, document order, named in sequence), and `testAnExportedPDFIsPrintableAndAnImageFileIsNotOfferedToThePrinter` (the system accepts the exported PDF as a printable item; an unprintable file is reported, not sent). The print panel itself is interactive and untested |
| F071 | Native export and backup | Own format at launch | G1/G3 | implemented | Archive `DocumentArchiveWriter`/`LibraryArchiveWriter` (portable: passing — `ArchiveRoundTripTests.testDocumentRoundTripRestoresAnEqualSnapshotAndAssets` (A13), `ArchiveRejectionTests`, 40 tests (A14), `ZipTests`) and Workspace `exportArchive` (`LibraryServiceTests.testExportArchiveAndRestoreAsCopyIsEqualModuloIdentifiers`); App/Export `ExportSheet` offers the archive and App/Settings `StorageSettingsView` the library backup, neither with a simulator test |
| F072 | Batch folder export | Personal | P1 | deferred | BACKLOG P1 |
| F073 | Cloud PDF writeback | Platform | P8 | deferred | BACKLOG P8 |

## Audio and lecture review

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F074 | Audio capture | Personal | P3 | deferred | BACKLOG P3 |
| F075 | Note replay | Personal | P3 | deferred | BACKLOG P3 |
| F076 | Replay display modes | Personal | P3 | deferred | BACKLOG P3 |
| F077 | Ongoing (background) recording | Personal | P3 | deferred | BACKLOG P3 |
| F078 | Transcription | Advanced | P3 (after speech evaluation) | deferred | BACKLOG P3; needs on-device speech capability check |
| F079 | Audio enhancement | Advanced | P3 | deferred | BACKLOG P3 |
| F080 | Audio sharing and backup | Personal | P3 | deferred | BACKLOG P3 |

## Study and recall

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F081 | Tape reveal | Launch | G4 | simulator-tested | DocumentCore `TapeContent`; Editing `setTapeRevealed` (portable: passing — `DocumentEditorTests.testTapeRevealRecordsEventsOnLinkedReviewItems`); App/Editor tape tool, tap to reveal and the Reveal/Hide menu items. Simulator [run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941): `AppFlowTests.testReviewQueueScopesToACourseAndMarksReviewedAndRevealsTheAnswerTape` reveals a tape through `ReviewQueueViewModel`, reads the revealed state back from the document, and checks the item's history records added, revealed, markedReviewed in order. The export half is simulator-covered: `InterchangeExportTests.testTapeExportPolicyDecidesWhetherAnswersAreCovered` over every `TapeExportPolicy` (bands portable — `PageMappingTests.testTapePolicyAndCompositingBands`) |
| F082 | Tape styling | Personal | P2 | deferred | BACKLOG P2 (solid colour only at launch) |
| F083 | Flashcards | Personal | P3 | deferred | BACKLOG P3 |
| F084 | Spaced repetition | Personal | P3 | deferred | BACKLOG P3. Launch review queue is manual (`ReviewRules`), not a scheduler |
| F085 | Study import/export (CSV/TSV) | Personal | P3 | deferred | BACKLOG P3 |
| F086 | Time Keeper | Personal | P3 | deferred | BACKLOG P3 |

## Math and AI

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F087 | Math conversion | Advanced | P4 | deferred | BACKLOG P4 |
| F088 | Math Assist (recognize, evaluate) | Advanced | P4 | deferred | BACKLOG P4 |
| F089 | Math tutoring | Advanced | P4 | deferred | BACKLOG P4 |
| F090 | Equation graphs | Advanced validation needed | P4 | deferred | BACKLOG P4 |
| F091 | Note questions and quizzes | Advanced | P5 | deferred | BACKLOG P5 |
| F092 | Writing assistance | Advanced | P5 | deferred | BACKLOG P5 |
| F093 | Generated visuals | Advanced | P5 | deferred | BACKLOG P5 |
| F094 | AI editing workflow | Advanced | P5 | deferred | BACKLOG P5 |
| F095 | AI usage controls | Advanced | P5 | deferred | BACKLOG P5 |

## Whiteboards and typed documents

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F096 | Whiteboard engine | Platform | P6 | deferred | BACKLOG P6 |
| F097 | Notebook to whiteboard conversion | Platform | P6 | deferred | BACKLOG P6 |
| F098 | Text Document (block) engine | Platform | P6 | deferred | BACKLOG P6 |
| F099 | Tables and media blocks | Platform | P6 | deferred | BACKLOG P6 |

## Sharing and integrations

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F100 | Shared documents (links, roles, revoke) | Platform | P7 | deferred | BACKLOG P7 |
| F101 | Presentations (external screen, pointer) | Personal | P1 | deferred | BACKLOG P1 |
| F102 | Meeting workflow | Advanced and Platform | P5 + P8 | deferred | BACKLOG P5 (AI) and P8 (calendar) |
| F103 | Integrated planner (calendar) | Platform | P8 | deferred | BACKLOG P8 |
| F104 | External AI integrations | Platform | P8 | deferred | BACKLOG P8 |

## Protection and the wider ecosystem

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F105 | Apple (iCloud) sync | Personal | P1 | deferred | BACKLOG P1 |
| F106 | Cross-platform cloud library | Platform | P7 | deferred | BACKLOG P7 |
| F107 | Backup management | Launch manual; Personal auto | G1/G3 manual; P1 automatic | implemented | Archive `LibraryArchiveWriter` (portable: passing — `ArchiveRoundTripTests.testLibraryArchiveWithSeveralDocumentsRoundTrips`, `testLibraryWriterRefusesDuplicateDocumentsAndLeavesNoFile`) and Workspace `backupLibrary`/`restoreLibrary` with both `RestoreMode`s (`LibraryServiceTests.testBackupIsValidatedAndRestoresInBothModes`); App/Settings `StorageSettingsView` backup and restore actions are written and untested. Automatic backup stays BACKLOG P1 |
| F108 | Document lock (password/biometrics) | Personal | P1 | deferred | BACKLOG P1 |
| F109 | Marketplace | Separate marketplace | Separate | deferred | Separate product decision; no card in BACKLOG beyond the P8 note |
| F110 | Organizational tools (SSO, admin, billing) | Separate product | Separate | deferred | Separate product decision |
| F111 | Workspaces | Unconfirmed roadmap | Unconfirmed | deferred | Announced, not confirmed shipped by the benchmark; no Courseleaf card. Recheck sources before any comparison |
| F112 | Word Complete | Retired | Retired | retired | Discontinued benchmark feature; not a requirement |

## Courseleaf-original capabilities (not benchmark rows)

| ID | Capability | Milestone | Status | Owner / evidence |
|---|---|---|---|---|
| C001 | Problem Pages (title, source, Given/Find, result region, status) | G4 | implemented | DocumentCore `ProblemMetadata`; Editing `setProblem`/`setProblemStatus` (portable: passing — `DocumentEditorTests.testProblemMetadataAndReviewCommandsAreUndoableAndInTheSnapshot`, `ReviewRulesTests.testCycleStatusVisitsEveryStatusInOrder`; survives the archive round trip, `ArchiveRoundTripTests`); App/ProblemInspector `ProblemInspectorView` edits all five fields, the result region and the page's review items. The screen has no test; problem metadata is findable in the editor (`EditorSearchTests.testFindsTypedTextTapeLabelsAndProblemMetadata`) |
| C002 | Course review queue (page/region, prompt, reveal, mark reviewed, jump back) | G4 | implemented | DocumentCore `ReviewItem`; Editing `ReviewRules` (portable: passing — `ReviewRulesTests`, 4 tests; `DocumentEditorTests.testReviewItemsOfDeletedPagesAreHiddenUntilRestore`); Catalog queue (`CatalogDatabaseTests.testReviewQueuePerCourseSubtreeAndUnfiled`); Workspace `reviewQueue`/`markReviewed`/`reopenReview` (`LibraryServiceTests.testReviewQueuePerCourseAndUnfiledWithMarkAndReopen`); App/Review `ReviewQueueView`/`ReviewDetailView`/`ReviewQueueViewModel` are written and have no simulator test |
| C003 | Durable commit protocol and recovery (LKG manifest, page recovery from revisions, save coalescing) — portable part | G1 | unit-tested | Persistence `DocumentPackageStore`, `SaveScheduler`; `DocumentPackageStoreTests.testA07EveryFailingStepLeavesPreviousManifestReadable`, `testA08CrashAtEveryStepReopensToPreOrPostState`, `testInvalidManifestFallsBackToLastKnownGood`, `testMissingCurrentPageFileIsRecoveredFromEarlierRevision`, `testUnsupportedSchemaIsAnErrorNotAnEmptyDocument`, `SaveSchedulerTests` (5 tests); run recorded in VALIDATION (219 Linux tests at `2de9721`). Disk latency and force-quit behaviour remain device gates (A07/A08) and no device exists |
| C004 | Rebuildable catalog (delete and rebuild yields identical results) — portable part | G4 | unit-tested | Catalog `CatalogDatabase`; `CatalogDatabaseTests.testDeletingTheCatalogAndRebuildingYieldsIdenticalResults`, `testRebuildIsAtomic`, `testInMemoryAndOnDiskProduceIdenticalResults`, and through the service `LibraryServiceTests.testCatalogDeletedThenRebuiltAnswersIdenticalQueries`; run recorded in VALIDATION (219 Linux tests at `2de9721`). The Settings "Rebuild search index" action is C005 |
| C005 | Save status UI, session wiring and Settings maintenance actions (Workspace `DocumentSession`, `SaveStatus` display, rebuild index, storage report) | G1/G4 | implemented | Workspace `LibraryService`/`DocumentSession` (portable: passing — `LibraryServiceTests.testCreateEditFlushCloseReopenRestoresEqualSnapshot`, `testSaveStatusGoesUnsavedSavingSavedOnlyAfterDurableCommitAndRecordsLatency`, `testCatalogDeletedThenRebuiltAnswersIdenticalQueries`; `LibraryStoreTests.testStorageReportCountsBytesPerCategory`). App: `AppEnvironment` opens the library and turns service failures into alerts, `SaveStatusText` separates every state — simulator `AppShellTests.testEnvironmentOpensALibraryAtATemporaryRoot`, `testEnvironmentReportsServiceFailuresAsAnAlertInsteadOfCrashing`, `testSaveStatusTextSeparatesEveryState`, `testWorkspaceErrorsAreExplainedInPlainEnglish`. App/Settings `StorageSettingsView` (rebuild index, storage report, empty trash) has no test |

## Counts (2026-09-12, commit `cb91777`)

Benchmark rows: 112.

- **`simulator-tested`** — 17: F001, F008, F010, F014, F020, F022, F023, F025,
  F026, F028, F029, F032, F038, F058, F060, F063, F069. Each names a case from the
  63-test iPad simulator run.
- **`implemented`** — 24: F003, F004, F005, F006, F009, F011, F012, F015, F018,
  F035, F039, F041, F042, F044, F048, F049, F051, F057, F065, F068, F070, F071,
  F081, F107. The code exists and compiles for the simulator; the portable half is
  covered by Linux tests, the screen is not covered by any test.
- **`in progress`** — 3: F007 (no page copy or move between notebooks), F059 (no
  editable conversion preview), F066 (drag and drop and "Open in" not wired).
- **`deferred`** with a backlog card or a separate product decision: 67.
- **`retired`:** 1 (F112).
- **`device-tested`:** 0, and it stays 0 until a physical iPad and an Apple Pencil
  exist for this project.

Courseleaf-original rows: C003 and C004 `unit-tested` (portable logic only);
C001, C002 and C005 `implemented`.
