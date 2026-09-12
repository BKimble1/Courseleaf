# Feature register

Every benchmark record F001–F112 from `docs/research/Goodnotes_Research_and_App_Plan.md`,
mapped to a Courseleaf milestone and an honest status. Updated 2026-09-12 while the
launch modules are being written in parallel; nothing in this table has been run on
an iPad yet.

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
test or fixture that will demonstrate it. Test names given are the portable tests
already present in `Tests/`; `CourseleafTests` entries are simulator tests still to be
written. A status moves right only when the named evidence exists in `docs/VALIDATION.md`.

## Library and document organization

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F001 | Folders (nested courses/folders) | Launch | G1 | in progress | Persistence `LibraryStore`, App/Library; `LibraryStoreTests.testCreateListRenameMoveFavoriteCover`, `testDeletingAFolderTrashesItsSubtreeAndRestoreBringsItBack` |
| F002 | Folder appearance (colours, icons) | Personal | P1 | deferred | BACKLOG P1. `Folder.color` exists in the model; icon choice and a picker UI are not launch scope |
| F003 | Library views (grid, list) | Launch | G1 | in progress | App/Library over `LibraryServicing.documents(in:)`; `CourseleafTests` (simulator) planned |
| F004 | Item management (rename, move, delete) | Launch | G1 | in progress | Persistence `LibraryStore`; `LibraryStoreTests.testCreateListRenameMoveFavoriteCover` |
| F005 | Favorites (documents, folders; pages via bookmarks) | Launch | G1 | in progress | Workspace `LibraryScope.favorites`, `Document.isFavorite`, `Folder.isFavorite`; page favourites are bookmarks (F011) |
| F006 | Trash (recover documents, folders, pages; empty) | Launch | G1 | in progress | Persistence; `LibraryStoreTests.testTrashRestorePurgeAndEmptyTrash`; page trash: Editing `deletePage`/`restorePage` (A11) |
| F007 | Page order (reorder, copy, move, combine) | Launch | G1/G2 | in progress | Editing `movePage`, `duplicatePage`, `copiesOfPages`; `EditingTests` (A11) to be written |
| F008 | Covers | Launch | G1 | in progress | DocumentCore `CoverStyle` (original procedural palettes/patterns), App/Library |
| F009 | Templates (custom template/cover import) | Launch | G1 built-in; P1 custom import | in progress | Built-in originals only at launch (F010). Importing user templates/covers is BACKLOG P1 |
| F010 | Paper choices (blank, ruled, grid, Cornell, …) | Launch | G1 | in progress | PageGeometry `TemplateGeometry` (blank, lined, grid, dotted, cornell, engineering in page points); `TemplateGeometryTests` (6 tests). Planner paper not at launch |

## Navigation and the writing environment

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F011 | Page navigation (thumbnails, bookmarks, outlines) | Launch | G2 | in progress | App/Editor thumbnails; Editing `setPageBookmark`; `CourseleafTests` planned |
| F012 | Imported outlines (PDF table of contents) | Launch | G3 | in progress | App/Interchange (PDFKit outline); fixture `Fixtures/text-and-outline.pdf`; `FixturesTests.testTextAndOutlineFixtureContainsTitles` |
| F013 | Custom outlines | Personal | P1 | deferred | BACKLOG P1 |
| F014 | Canvas navigation (zoom, scroll direction) | Launch | G2 | in progress | App/Editor: zoom and vertical scrolling at launch; horizontal progression is BACKLOG P1 |
| F015 | Reading mode | Launch | G2 | in progress | App/Editor (input disabled, links followable, no edits) |
| F016 | Multiple windows | Personal | P1 | deferred | BACKLOG P1; `UIApplicationSupportsMultipleScenes` is false at launch |
| F017 | Toolbar layout customization | Personal | P1 | deferred | BACKLOG P1 |
| F018 | Keyboard controls (shortcuts) | Launch | G2 | in progress | App/Editor `UIKeyCommand` set; `CourseleafTests` planned; A17 |
| F019 | Zoom Window | Personal | P1 | deferred | BACKLOG P1 |
| F020 | Quick capture | Launch | G1 | in progress | Workspace `createQuickNote`, `LibraryScope.inbox`, `DocumentKind.quickNote` |
| F021 | Home widgets | Personal | P1 | deferred | BACKLOG P1 |

## Pens and input

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F022 | Pen styles (fountain, ball, brush) | Launch subset | G2 | in progress | App/Editor `PencilKitInkEngine`: PencilKit pen only, labelled "Pen". No fountain/brush simulation; that is BACKLOG P2 |
| F023 | Pencil (graphite) | Launch | G2 | in progress | PencilKit pencil ink |
| F024 | Stroke patterns (dashed, dotted) | Personal | P2 | deferred | BACKLOG P2 |
| F025 | Thickness presets | Launch | G2 | in progress | App/Editor tool presets stored in settings |
| F026 | Color controls | Launch subset | G2 | in progress | Presets and a custom colour at launch; ordering and eyedropper are BACKLOG P1 |
| F027 | Ink response (pressure, tip, stabilization) | Personal | P2 | deferred | BACKLOG P2; PencilKit pressure response is inherent, no extra controls |
| F028 | Highlighter | Launch | G2 | in progress | PencilKit marker ink; blend/band order `PageMappingTests.testTapePolicyAndCompositingBands`; export blending is A05/A12 device evidence |
| F029 | Stylus and touch (finger drawing, palm rejection) | Launch | G2 | in progress | `PKCanvasView.drawingPolicy` (pencilOnly default, anyInput opt-in); palm rejection is a device gate (A03/A16) |
| F030 | Hover preview | Personal | P2 | deferred | BACKLOG P2 |
| F031 | Pencil Pro (squeeze, barrel roll) | Personal | P2 | deferred | BACKLOG P2 |

## Erasing and selection

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F032 | Eraser variants | Launch subset | G2 | in progress | Pixel (`PKEraserTool(.bitmap)`) and whole-stroke (`.vector`) at launch; segment eraser BACKLOG P2. Mask semantics: `ReferenceInkTests.testPartialEraseThenMoveAndRecolorKeepsMask` (A10) |
| F033 | Erase filters | Personal | P2 | deferred | BACKLOG P2 |
| F034 | Tool return after erasing | Personal | P2 | deferred | BACKLOG P2 |
| F035 | Clear page | Launch | G2 | in progress | Editing `clearPage` (keeps page and metadata) |
| F036 | Scribble to erase | Personal | P2 | deferred | BACKLOG P2 |
| F037 | Circle to select | Personal | P2 | deferred | BACKLOG P2 |
| F038 | Lasso filters | Launch | G2 | in progress | Editing `SelectionFilter`, `SelectionRules`; App/Editor `SelectionController` (freehand + rectangle) |
| F039 | Object editing (transform, recolor, copy, delete, align, capture) | Launch | G2 | in progress | Editing `transformObjects`, `SelectionAction`; align and capture-as-image are BACKLOG P2 |
| F040 | Handwriting reflow | Advanced | P4 | deferred | BACKLOG P4 |
| F041 | Undo and redo | Launch | G2 | in progress | Editing `DocumentEditor` grouped undo; shared `UndoManager` in App/Editor; A09 |

## Text and visual objects

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F042 | Text boxes | Launch | G2 | in progress | DocumentCore `TextContent` (size, weight, design, alignment, colour); App/Editor |
| F043 | Full-page typing | Personal | P2 | deferred | BACKLOG P2 |
| F044 | Images and camera | Launch | G2/G3 | in progress | `ImageContent` (crop, opacity); App/Interchange photo picker and scanner; A16 |
| F045 | Elements (reusable selections) | Personal | P2 | deferred | BACKLOG P2 |
| F046 | Collection exchange | Personal | P2 | deferred | BACKLOG P2 |
| F047 | Animated GIFs | Platform | P8 | deferred | BACKLOG P8 |
| F048 | Object locking | Launch | G2 | in progress | Editing `setObjectsLocked`; locked objects excluded from hit tests and transforms |
| F049 | Object stacking (front/back, groups) | Launch | G2 | in progress | Editing `bringToFront`/`sendToBack`/`reorderObject` within a band; grouping BACKLOG P2. Limitation: ink band is fixed (PRODUCT_SPEC) |
| F050 | Sticky notes | Personal | P2 | deferred | BACKLOG P2 |

## Geometry and layer controls

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F051 | Shape recognition | Launch subset | G2 | in progress | Explicit shape tool (`ShapeContent`: line, arrow, rectangle, ellipse). Stroke-to-shape recognition is BACKLOG P2 |
| F052 | Draw and hold | Personal | P2 | deferred | BACKLOG P2 |
| F053 | Ruler | Personal | P2 | deferred | BACKLOG P2 |
| F054 | Connectors | Personal | P2 | deferred | BACKLOG P2 |
| F055 | Quick diagramming | Personal | P2 | deferred | BACKLOG P2 |
| F056 | Layers | Personal | P2 | deferred | BACKLOG P2; `Page.inkLayers` is an array but launch uses one layer |

## Search and recognition

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F057 | Library search | Launch | G4 | in progress | Catalog FTS5; `CatalogDatabaseTests.testRebuildFromSnapshotsThenQuery`, `testSearchDistinguishesNoMatchesFromNotYetIndexed`, `testRankingOrderTitleTypedPDFTextRecognized` |
| F058 | Document search | Launch | G4 | in progress | Workspace `SearchScope.document`; same Catalog tests |
| F059 | Handwriting conversion | Launch best effort | G4 | in progress | App/Interchange Vision `TextRecognizer` with editable preview; subject to the A15 corpus in VALIDATION. Not a parity claim |
| F060 | Recognition languages | Launch English | G4 | in progress | English only; `SearchRecord.language` |
| F061 | Handwriting spelling | Advanced | P4 | deferred | BACKLOG P4 |
| F062 | Handwriting appearance (reflow, beautify) | Advanced | P4 | deferred | BACKLOG P4 |

## Import and export

| ID | Capability | Research target | Milestone | Status | Owner / evidence |
|---|---|---|---|---|---|
| F063 | PDF and image import | Launch | G3 | in progress | Workspace `importFiles`/`ImportDestination`; App/Interchange PDFKit inspector; fixtures rotated/cropped/malformed/encrypted/image-only/long; `PDFFixtureTests.testInspectorRejectsMalformedFixturesWithTheRightErrors` |
| F064 | Office import | Platform | P8 | deferred | BACKLOG P8 |
| F065 | Native import | Own format only | G3 | in progress | Archive `ArchiveReader`; `ArchiveRoundTripTests`; no third-party notebook decoder (see `MIGRATION_FROM_GOODNOTES.md`) |
| F066 | Share and drag import | Launch | G3 | in progress | App/Interchange: Files picker, drag and drop, open-in via `CFBundleDocumentTypes`; security-scoped copy into `Staging/` |
| F067 | Email import | Platform | P8 | deferred | BACKLOG P8 |
| F068 | Scan documents | Launch | G3 | in progress | App/Interchange VisionKit document camera; permission-denied path (A16) |
| F069 | PDF export | Launch | G3 | in progress | App/Interchange over PageGeometry `ExportGeometry`; `PageMappingTests.testAlignmentFixturesAgreeWithSidecarWithin1e9`; A05 on device |
| F070 | Image export and printing | Launch | G3 | in progress | `ExportFormat.png/.jpeg`; `UIPrintInteractionController` |
| F071 | Native export and backup | Own format at launch | G1/G3 | in progress | Archive `DocumentArchiveWriter`, `LibraryArchiveWriter`; `ArchiveRoundTripTests.testDocumentRoundTripRestoresAnEqualSnapshotAndAssets` (A13), `ArchiveRejectionTests` (A14) |
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
| F081 | Tape reveal | Launch | G4 | in progress | DocumentCore `TapeContent`; Editing `setTapeRevealed`; `TapeExportPolicy`; `PageMappingTests.testTapePolicyAndCompositingBands` |
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
| F107 | Backup management | Launch manual; Personal auto | G1/G3 manual; P1 automatic | in progress | Workspace `backupLibrary`/`restoreLibrary` (`RestoreMode.addCopies` default); `ArchiveRoundTripTests.testLibraryArchiveWithSeveralDocumentsRoundTrips`. Automatic backup is BACKLOG P1 |
| F108 | Document lock (password/biometrics) | Personal | P1 | deferred | BACKLOG P1 |
| F109 | Marketplace | Separate marketplace | Separate | deferred | Separate product decision; no card in BACKLOG beyond the P8 note |
| F110 | Organizational tools (SSO, admin, billing) | Separate product | Separate | deferred | Separate product decision |
| F111 | Workspaces | Unconfirmed roadmap | Unconfirmed | deferred | Announced, not confirmed shipped by the benchmark; no Courseleaf card. Recheck sources before any comparison |
| F112 | Word Complete | Retired | Retired | retired | Discontinued benchmark feature; not a requirement |

## Courseleaf-original capabilities (not benchmark rows)

| ID | Capability | Milestone | Status | Owner / evidence |
|---|---|---|---|---|
| C001 | Problem Pages (title, source, Given/Find, result region, status) | G4 | in progress | DocumentCore `ProblemMetadata`; Editing `setProblem`/`setProblemStatus`; survives archive (`ArchiveRoundTripTests`) and recovery |
| C002 | Course review queue (page/region, prompt, reveal, mark reviewed, jump back) | G4 | in progress | DocumentCore `ReviewItem`; Editing `ReviewRules`; Catalog `CatalogDatabaseTests.testReviewQueuePerCourseSubtreeAndUnfiled` |
| C003 | Durable save status and recovery (LKG manifest, page recovery from revisions) | G1 | in progress | Persistence; `DocumentPackageStoreTests.testA07…`, `testA08…`, `testInvalidManifestFallsBackToLastKnownGood`, `SaveSchedulerTests` |
| C004 | Rebuildable catalog (delete and rebuild yields identical results) | G4 | in progress | `CatalogDatabaseTests.testDeletingTheCatalogAndRebuildingYieldsIdenticalResults`, `testRebuildIsAtomic` |

## Counts (2026-09-12)

Launch scope (G0–G6) in progress: 50 rows (F001, F003–F008, F009 built-in part, F010–F012, F014, F015, F018, F020, F022, F023, F025, F026, F028, F029, F032, F035, F038, F039, F041, F042, F044, F048, F049, F051, F057–F060, F063, F065, F066, F068–F071, F081, F107 manual part). Deferred with a backlog card: 61. Retired: 1 (F112). Implemented, unit-tested, simulator-tested or device-tested: 0 — statuses move only with recorded evidence.
