# Feature register

Every benchmark record F001–F112 from `docs/research/Goodnotes_Research_and_App_Plan.md`,
mapped to a Courseleaf milestone and an honest status. Updated 2026-09-12 at commit
`3b105a5`: the portable core modules (DocumentCore, PageGeometry, Editing,
Persistence, Archive, Catalog, Fixtures) are committed with 203 passing Linux tests
(`docs/VALIDATION.md` → Portable test runs). The Workspace façade (`LibraryService`,
`DocumentSession`) and every screen under `App/` are still being written in
parallel. Nothing in this table has been compiled with an Apple SDK or run on an
iPad yet.

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
PageGeometry, Editing, Workspace, App/Library, App/Editor, App/Interchange) and the
test or fixture that will demonstrate it. Test names given are portable tests that
exist in `Tests/` and passed at the commit named in `docs/VALIDATION.md`
("portable: passing"); `CourseleafTests` entries are simulator tests still to be
written. A status moves right only when the named evidence exists in `docs/VALIDATION.md`.

**Composite rows.** A row's status is that of its least-advanced required part. A
user-visible capability whose portable logic already passes its tests but whose
Workspace or `App/` part is unwritten stays `in progress`; the evidence column says
which portable tests pass and what is still missing. Only rows with no app part
(C003, C004) carry `unit-tested`.

## Library and document organization

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F001 | Folders (nested courses/folders) | Launch | G1 | in progress | Persistence `LibraryStore` (portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`, `testDeletingAFolderTrashesItsSubtreeAndRestoreBringsItBack`); Workspace `folders(in:)`/`createFolder` and App/Library not written |
| F002 | Folder appearance (colours, icons) | Personal | P1 | deferred | BACKLOG P1. `Folder.color` exists in the model; icon choice and a picker UI are not launch scope |
| F003 | Library views (grid, list) | Launch | G1 | in progress | App/Library over `LibraryServicing.documents(in:)`; Workspace and screen not written; `CourseleafTests` (simulator) planned |
| F004 | Item management (rename, move, delete) | Launch | G1 | in progress | Persistence `LibraryStore` (portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`, `testDuplicateYieldsDistinctIdentifiersAndEqualContent`); Workspace `rename`/`move`/`duplicate`/`delete` and App/Library not written |
| F005 | Favorites (documents, folders; pages via bookmarks) | Launch | G1 | in progress | DocumentCore `Document.isFavorite`, `Folder.isFavorite` (portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`); Workspace `LibraryScope.favorites` and App/Library not written; page favourites are bookmarks (F011) |
| F006 | Trash (recover documents, folders, pages; empty) | Launch | G1 | in progress | Persistence trash (portable: passing — `LibraryStoreTests.testTrashRestorePurgeAndEmptyTrash`); page trash in Editing (portable: passing — `DocumentEditorTests.testReviewItemsOfDeletedPagesAreHiddenUntilRestore`, `testRestoreUsesMinOfOriginalIndexAndPageCountAndClampsLastViewed`); Workspace `restore`/`purge`/`emptyTrash` and App/Library not written |
| F007 | Page order (reorder, copy, move, combine) | Launch | G1/G2 | in progress | Editing `movePage`/`duplicatePage`/`insertPages`/`copiesOfPages` (portable: passing — `DocumentEditorTests.testA11PageOperationsKeepOtherPagesAndIDsStable`, `testMakeDuplicateAndCopiesOfPagesUseFreshIDsAndSharedAssets`); move/copy between notebooks needs Workspace sessions and the App/Editor page sheet, not written |
| F008 | Covers | Launch | G1 | in progress | DocumentCore `CoverStyle` (8 original palettes × 4 patterns); Persistence `setCover` (portable: passing — `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`); App/Library cover rendering and picker not written |
| F009 | Templates (custom template/cover import) | Launch | G1 built-in; P1 custom import | in progress | Built-in originals only at launch (F010). Importing user templates/covers is BACKLOG P1 |
| F010 | Paper choices (blank, ruled, grid, Cornell, …) | Launch | G1 | in progress | PageGeometry `TemplateGeometry` (blank, lined, grid, dotted, cornell, engineering in page points; portable: passing — `TemplateGeometryTests`, 6 tests); App/Editor template renderer not written. Planner paper not at launch |

## Navigation and the writing environment

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F011 | Page navigation (thumbnails, bookmarks, outlines) | Launch | G2 | in progress | Editing `setPageBookmark` command exists; App/Editor thumbnails and bookmark list not written; `CourseleafTests` planned |
| F012 | Imported outlines (PDF table of contents) | Launch | G3 | in progress | App/Interchange (PDFKit outline) not written; fixture `Fixtures/text-and-outline.pdf` (portable: passing — `FixtureCatalogTests.testTextAndOutlineFixtureContainsTitles`, `PDFFixtureTests.testInspectorRoundTripsBoxesRotationOutlineAndText`) |
| F013 | Custom outlines | Personal | P1 | deferred | BACKLOG P1 |
| F014 | Canvas navigation (zoom, scroll direction) | Launch | G2 | in progress | App/Editor not written: zoom and vertical scrolling at launch; canvas mapping (portable: passing — `PageMappingTests.testCanvasMappingAppliesZoomAndOffset`); horizontal progression is BACKLOG P1 |
| F015 | Reading mode | Launch | G2 | in progress | App/Editor not written (input disabled, links followable, no edits) |
| F016 | Multiple windows | Personal | P1 | deferred | BACKLOG P1; `UIApplicationSupportsMultipleScenes` is false at launch |
| F017 | Toolbar layout customization | Personal | P1 | deferred | BACKLOG P1 |
| F018 | Keyboard controls (shortcuts) | Launch | G2 | in progress | App/Editor `UIKeyCommand` set not written; `CourseleafTests` planned; A17 |
| F019 | Zoom Window | Personal | P1 | deferred | BACKLOG P1 |
| F020 | Quick capture | Launch | G1 | in progress | DocumentCore `DocumentKind.quickNote`; Workspace `createQuickNote`/`LibraryScope.inbox` and App/Library not written |
| F021 | Home widgets | Personal | P1 | deferred | BACKLOG P1 |

## Pens and input

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F022 | Pen styles (fountain, ball, brush) | Launch subset | G2 | in progress | App/Editor `PencilKitInkEngine` not written: PencilKit pen only, labelled "Pen". No fountain/brush simulation; that is BACKLOG P2 |
| F023 | Pencil (graphite) | Launch | G2 | in progress | PencilKit pencil ink via App/Editor `PencilKitInkEngine`, not written |
| F024 | Stroke patterns (dashed, dotted) | Personal | P2 | deferred | BACKLOG P2 |
| F025 | Thickness presets | Launch | G2 | in progress | App/Editor tool presets stored in settings, not written |
| F026 | Color controls | Launch subset | G2 | in progress | Presets and a custom colour at launch (App/Editor, not written; `Color` hex coding portable: passing — `GeometryTests.testColorHex`); ordering and eyedropper are BACKLOG P1 |
| F027 | Ink response (pressure, tip, stabilization) | Personal | P2 | deferred | BACKLOG P2; PencilKit pressure response is inherent, no extra controls |
| F028 | Highlighter | Launch | G2 | in progress | PencilKit marker ink (App/Editor, not written); band order (portable: passing — `PageMappingTests.testTapePolicyAndCompositingBands`); export blending is A05/A12 simulator/device evidence |
| F029 | Stylus and touch (finger drawing, palm rejection) | Launch | G2 | in progress | App/Editor `PKCanvasView.drawingPolicy` (pencilOnly default, anyInput opt-in), not written; palm rejection is a device gate (A03/A16) |
| F030 | Hover preview | Personal | P2 | deferred | BACKLOG P2 |
| F031 | Pencil Pro (squeeze, barrel roll) | Personal | P2 | deferred | BACKLOG P2 |

## Erasing and selection

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F032 | Eraser variants | Launch subset | G2 | in progress | App/Editor: pixel (`PKEraserTool(.bitmap)`) and whole-stroke (`.vector`), not written; segment eraser BACKLOG P2. Mask semantics (portable: passing — `ReferenceInkTests.testPartialEraseThenMoveAndRecolorKeepsMask`, `InkFixtureTests.testPartiallyErasedSampleKeepsMasksThroughTransformAndRoundTrip`) (A10) |
| F033 | Erase filters | Personal | P2 | deferred | BACKLOG P2 |
| F034 | Tool return after erasing | Personal | P2 | deferred | BACKLOG P2 |
| F035 | Clear page | Launch | G2 | in progress | Editing `clearPage` (portable: passing — `DocumentEditorTests.testClearPageRemovesObjectsAndEmptiesInkButKeepsMetadata`); App/Editor menu item not written |
| F036 | Scribble to erase | Personal | P2 | deferred | BACKLOG P2 |
| F037 | Circle to select | Personal | P2 | deferred | BACKLOG P2 |
| F038 | Lasso filters | Launch | G2 | in progress | Editing `SelectionFilter`/`SelectionRules` (portable: passing — `SelectionTests.testRectHitTestUsesRotatedBoundsSkipsLockedAndAppliesFilters`, `testPolygonHitTestRequiresWholeBoundsInside`); App/Editor `SelectionController` (freehand + rectangle) not written |
| F039 | Object editing (transform, recolor, copy, delete, align, capture) | Launch | G2 | in progress | Editing `transformObjects`, `SelectionAction` (portable: passing — `SelectionTests.testAvailableActionsMatrix`, `testClipboardPasteGivesFreshIDsAndOffsets`, `DocumentEditorTests.testTransformRules`); App/Editor handles not written; align and capture-as-image are BACKLOG P2 |
| F040 | Handwriting reflow | Advanced | P4 | deferred | BACKLOG P4 |
| F041 | Undo and redo | Launch | G2 | in progress | Editing `DocumentEditor` grouped undo (portable: passing — `DocumentEditorTests.testA09GroupedMoveOfObjectsAndInkUndoesInOneStepAndRedoReapplies`, `testNestedGroupsFormOneRecordAndFailedCommandLeavesSnapshotUntouched`, `testRedoIsClearedByANewCommand`); shared `UndoManager` in App/Editor not written; A09 |

## Text and visual objects

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F042 | Text boxes | Launch | G2 | in progress | DocumentCore `TextContent` (size, weight, design, alignment, colour); App/Editor text editing not written |
| F043 | Full-page typing | Personal | P2 | deferred | BACKLOG P2 |
| F044 | Images and camera | Launch | G2/G3 | in progress | DocumentCore `ImageContent` (crop, opacity); App/Interchange photo picker and scanner not written; A16 |
| F045 | Elements (reusable selections) | Personal | P2 | deferred | BACKLOG P2 |
| F046 | Collection exchange | Personal | P2 | deferred | BACKLOG P2 |
| F047 | Animated GIFs | Platform | P8 | deferred | BACKLOG P8 |
| F048 | Object locking | Launch | G2 | in progress | Editing `setObjectsLocked`, locked objects excluded from hit tests and transforms (portable: passing — `DocumentEditorTests.testLockedObjectsRejectTransformRemoveAndUpdateButAcceptUnlock`, `SelectionTests.testRectHitTestUsesRotatedBoundsSkipsLockedAndAppliesFilters`); App/Editor not written |
| F049 | Object stacking (front/back, groups) | Launch | G2 | in progress | Editing `bringToFront`/`sendToBack`/`reorderObject` within a band (portable: passing — `DocumentEditorTests.testAddRemoveUpdateReorderObjectsOnTheSingleArray`, `SelectionTests.testPointHitTestIsExactForRotationAndFollowsCompositingOrder`); App/Editor not written; grouping BACKLOG P2. Limitation: ink band is fixed (PRODUCT_SPEC §6) |
| F050 | Sticky notes | Personal | P2 | deferred | BACKLOG P2 |

## Geometry and layer controls

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F051 | Shape recognition | Launch subset | G2 | in progress | Explicit shape tool over DocumentCore `ShapeContent` (line, arrow, rectangle, ellipse); App/Editor shape tool not written. Stroke-to-shape recognition is BACKLOG P2 |
| F052 | Draw and hold | Personal | P2 | deferred | BACKLOG P2 |
| F053 | Ruler | Personal | P2 | deferred | BACKLOG P2 |
| F054 | Connectors | Personal | P2 | deferred | BACKLOG P2 |
| F055 | Quick diagramming | Personal | P2 | deferred | BACKLOG P2 |
| F056 | Layers | Personal | P2 | deferred | BACKLOG P2; `Page.inkLayers` is an array but launch uses one layer |

## Search and recognition

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F057 | Library search | Launch | G4 | in progress | Catalog FTS5 (portable: passing — `CatalogDatabaseTests.testRebuildFromSnapshotsThenQuery`, `testSearchDistinguishesNoMatchesFromNotYetIndexed`, `testRankingOrderTitleTypedPDFTextRecognized`, `FTSQueryTests`); Workspace `search(_:scope:)` and App/Search not written |
| F058 | Document search | Launch | G4 | in progress | Workspace `SearchScope.document` and App/Editor find not written; same Catalog tests |
| F059 | Handwriting conversion | Launch best effort | G4 | in progress | App/Interchange Vision `TextRecognizer` with editable preview, not written; stale-record invalidation (portable: passing — `CatalogDatabaseTests.testEditingPageRevisionDropsStaleRecognizedRecordsButKeepsTyped`); subject to the A15 corpus in VALIDATION. Not a parity claim |
| F060 | Recognition languages | Launch English | G4 | in progress | English only; `SearchRecord.language`; App/Interchange recognizer not written |
| F061 | Handwriting spelling | Advanced | P4 | deferred | BACKLOG P4 |
| F062 | Handwriting appearance (reflow, beautify) | Advanced | P4 | deferred | BACKLOG P4 |

## Import and export

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F063 | PDF and image import | Launch | G3 | in progress | Workspace `importFiles`/`ImportDestination` and App/Interchange PDFKit inspector not written; fixtures rotated/cropped/malformed/encrypted/image-only/long (portable: passing — `PDFFixtureTests.testInspectorRejectsMalformedFixturesWithTheRightErrors`, `testInspectorReportsEncryptMarker`, `testInspectorReadsImageOnlyAndLongMixedFixtures`, `ImageFixtureTests`) |
| F064 | Office import | Platform | P8 | deferred | BACKLOG P8 |
| F065 | Native import | Own format only | G3 | in progress | Archive `ArchiveReader` (portable: passing — `ArchiveRoundTripTests`, 9 tests); Workspace import path and App/Interchange picker not written; no third-party notebook decoder (see `MIGRATION_FROM_GOODNOTES.md`) |
| F066 | Share and drag import | Launch | G3 | in progress | App/Interchange not written: Files picker, drag and drop, open-in via `CFBundleDocumentTypes` (declared in `App/project.yml`); security-scoped copy into `Staging/` (`LibraryStoreTests.testOpenCreatesLayoutAndClearsStaging` covers staging cleanup) |
| F067 | Email import | Platform | P8 | deferred | BACKLOG P8 |
| F068 | Scan documents | Launch | G3 | in progress | App/Interchange VisionKit document camera not written; permission-denied path (A16) |
| F069 | PDF export | Launch | G3 | in progress | PageGeometry `ExportGeometry` (portable: passing — `PageMappingTests.testAlignmentFixturesAgreeWithSidecarWithin1e9`, `CanvasAndExportGeometryTests`); App/Interchange PDF renderer not written; A05 on simulator/device |
| F070 | Image export and printing | Launch | G3 | in progress | DocumentCore `ExportFormat.png/.jpeg`; App/Interchange image renderer and `UIPrintInteractionController` not written |
| F071 | Native export and backup | Own format at launch | G1/G3 | in progress | Archive `DocumentArchiveWriter`/`LibraryArchiveWriter` (portable: passing — `ArchiveRoundTripTests.testDocumentRoundTripRestoresAnEqualSnapshotAndAssets` (A13), `ArchiveRejectionTests`, 40 tests (A14), `ZipTests`); Workspace `exportArchive` and App/Export sheet not written |
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
| F081 | Tape reveal | Launch | G4 | in progress | DocumentCore `TapeContent`; Editing `setTapeRevealed` (portable: passing — `DocumentEditorTests.testTapeRevealRecordsEventsOnLinkedReviewItems`); `TapeExportPolicy` bands (`PageMappingTests.testTapePolicyAndCompositingBands`); App/Editor tape tool not written |
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
| F107 | Backup management | Launch manual; Personal auto | G1/G3 manual; P1 automatic | in progress | Archive `LibraryArchiveWriter` (portable: passing — `ArchiveRoundTripTests.testLibraryArchiveWithSeveralDocumentsRoundTrips`, `testLibraryWriterRefusesDuplicateDocumentsAndLeavesNoFile`); Workspace `backupLibrary`/`restoreLibrary` (`RestoreMode.addCopies` default) and App/Settings not written. Automatic backup is BACKLOG P1 |
| F108 | Document lock (password/biometrics) | Personal | P1 | deferred | BACKLOG P1 |
| F109 | Marketplace | Separate marketplace | Separate | deferred | Separate product decision; no card in BACKLOG beyond the P8 note |
| F110 | Organizational tools (SSO, admin, billing) | Separate product | Separate | deferred | Separate product decision |
| F111 | Workspaces | Unconfirmed roadmap | Unconfirmed | deferred | Announced, not confirmed shipped by the benchmark; no Courseleaf card. Recheck sources before any comparison |
| F112 | Word Complete | Retired | Retired | retired | Discontinued benchmark feature; not a requirement |

## Courseleaf-original capabilities (not benchmark rows)

| ID | Capability | Milestone | Status | Owner / evidence |
|---|---|---|---|---|
| C001 | Problem Pages (title, source, Given/Find, result region, status) | G4 | in progress | DocumentCore `ProblemMetadata`; Editing `setProblem`/`setProblemStatus` (portable: passing — `DocumentEditorTests.testProblemMetadataAndReviewCommandsAreUndoableAndInTheSnapshot`, `ReviewRulesTests.testCycleStatusVisitsEveryStatusInOrder`; survives archive round trip `ArchiveRoundTripTests`); App/ProblemInspector not written |
| C002 | Course review queue (page/region, prompt, reveal, mark reviewed, jump back) | G4 | in progress | DocumentCore `ReviewItem`; Editing `ReviewRules` (portable: passing — `ReviewRulesTests`, 4 tests; `DocumentEditorTests.testReviewItemsOfDeletedPagesAreHiddenUntilRestore`); Catalog queue (`CatalogDatabaseTests.testReviewQueuePerCourseSubtreeAndUnfiled`); Workspace `reviewQueue`/`markReviewed`/`reopenReview` and App/Review not written |
| C003 | Durable commit protocol and recovery (LKG manifest, page recovery from revisions, save coalescing) — portable part | G1 | unit-tested | Persistence `DocumentPackageStore`, `SaveScheduler`; `DocumentPackageStoreTests.testA07EveryFailingStepLeavesPreviousManifestReadable`, `testA08CrashAtEveryStepReopensToPreOrPostState`, `testInvalidManifestFallsBackToLastKnownGood`, `testMissingCurrentPageFileIsRecoveredFromEarlierRevision`, `testUnsupportedSchemaIsAnErrorNotAnEmptyDocument`, `SaveSchedulerTests` (5 tests); run recorded in VALIDATION at `3b105a5`. Disk latency and force-quit behaviour remain device gates (A07/A08) |
| C004 | Rebuildable catalog (delete and rebuild yields identical results) — portable part | G4 | unit-tested | Catalog `CatalogDatabase`; `CatalogDatabaseTests.testDeletingTheCatalogAndRebuildingYieldsIdenticalResults`, `testRebuildIsAtomic`, `testInMemoryAndOnDiskProduceIdenticalResults`; run recorded in VALIDATION at `3b105a5`. The Settings "Rebuild search index" action is C005 |
| C005 | Save status UI, session wiring and Settings maintenance actions (Workspace `DocumentSession`, `SaveStatus` display, rebuild index, storage report) | G1/G4 | in progress | Workspace `LibraryService`/`DocumentSession` and App/Editor, App/Settings not written; `StorageReport` counting (portable: passing — `LibraryStoreTests.testStorageReportCountsBytesPerCategory`) |

## Counts (2026-09-12, commit `3b105a5`)

Benchmark rows: 112. **In progress** (launch scope G1–G4): 44 — F001, F003–F012
(F009 built-in part only), F014, F015, F018, F020, F022, F023, F025, F026, F028,
F029, F032, F035, F038, F039, F041, F042, F044, F048, F049, F051, F057–F060, F063,
F065, F066, F068–F071, F081, F107 (manual part only). **Deferred** with a backlog
card or a separate product decision: 67. **Retired:** 1 (F112). Implemented,
simulator-tested or device-tested benchmark rows: 0 — statuses move only with
recorded evidence. Courseleaf-original rows: C003 and C004 `unit-tested` (portable
logic only, 3b105a5); C001, C002, C005 `in progress`.
