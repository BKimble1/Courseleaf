# Validation

Acceptance evidence for the launch gates. Every row starts `pending`; a row changes
only when the named evidence exists and is recorded here with the source commit,
device/OS or CI job, fixture and metrics. Unresolved failures are listed, never
hidden.

Statuses: `pending`, `passed`, `failed`, `blocked`, `accepted limitation`. A row
may carry portable-test evidence and still be `pending` on the device gate; the
environment column says which environment the status refers to.

Environments: `linux` (`swift test` in the session or CI `core-linux`), `sim` (CI
`app-ios-simulator`, Xcode + iPad simulator), `device` (physical iPad + Apple
Pencil, recorded model/OS). See `docs/BUILD_AND_TEST.md`.

"Portable: passing (3b105a5)" in the evidence column means the named Linux tests
passed in the run recorded under *Portable test runs*. It never moves a row past
`pending` on its own: every A-row also needs the Workspace/App part (unwritten at
3b105a5) and, where listed, simulator or device evidence.

## A01–A20

| Test | How it is verified | Environment | Status | Evidence (planned) |
|---|---|---|---|---|
| A01 Blank notebook | Create, write, close, force-terminate, relaunch; committed ink is present byte-for-byte | linux (package round trip) + device | pending | Portable: passing (3b105a5) — `DocumentPackageStoreTests.testCreateCommitReopenRoundTripsAndWritesOnlyChangedPages`, `testNoOpCommitWritesNothing`; device run with ink asset digest before/after (needs App/Editor) |
| A02 Dense drawing | Page with 10,000 strokes: pan, zoom, write; no sustained input stall | device | pending | Fixture `Fixtures/ink/dense-500.json` scaled to 10k via `InkFixtures`; Instruments (Time Profiler, Hangs) trace on device |
| A03 Drawing responsiveness | Usable 60 Hz interaction, no repeated app-induced main-thread stalls > 100 ms while writing | device | pending | Instruments Hangs/Animation Hitches on the baseline iPad; method and hardware recorded below |
| A04 PDF alignment | Annotations aligned at 0/90/180/270° and zoom levels, non-zero CropBox origins | linux + sim + device | pending | Portable: passing (3b105a5) — `PageMappingTests.testRotate0/90/180/270WithCropOrigin`, `testRoundTripsWithin1e9ForEveryRotation`, `testAlignmentFixturesAgreeWithSidecarWithin1e9`, `testCropBoxIsIntersectedWithMediaBoxAndDisplaySizeMatchesModel`; simulator [run 34694155083](https://github.com/BKimble1/QuickWrite/actions/runs/34694155083): `InterchangeExportTests.testExportKeepsSourcePDFSquareAtItsExpectedPageRectForEveryRotationAndCrop` proves placement for every rotation and crop origin **in the exported page**. Still open: alignment of the live overlay at several zoom levels on screen, which needs a device or a UI test |
| A05 Export alignment | Exported PDF matches page-space positions within 1 pt for geometric fixtures | linux (geometry) + sim (real export) | **passed (sim)** | Linux: `CanvasAndExportGeometryTests`, `PageMappingTests.testSourcePageTransformPlacesRotatedPageContentAtPageOrigin`. Simulator [run 34694155083](https://github.com/BKimble1/QuickWrite/actions/runs/34694155083): `InterchangeExportTests.testExportPlacesAnObjectWithinOnePointOfItsPageRect` samples 1 pt inside and 1 pt outside every edge of an exported object, and `testExportKeepsSourcePDFSquareAtItsExpectedPageRectForEveryRotationAndCrop` checks all eight rotation and crop-origin fixtures against the `Fixtures/alignment.json` sidecar. Device re-check still worthwhile but not required for this claim |
| A06 Long PDF | 300-page mixed PDF opens with live canvases only for visible ±2 pages; bounded memory | sim + device | pending | Simulator [run 34694155083](https://github.com/BKimble1/QuickWrite/actions/runs/34694155083): `EditorLayoutTests.testPoolNeverExceedsItsLiveLimitScrollingThroughThreeHundredPages` scrolls a 300-page layout and asserts the live-canvas pool never exceeds its limit. Still open: opening the real `Fixtures/long-300-mixed.pdf` end to end and a device memory graph |
| A07 Save failure | Simulated disk-full/write failure keeps last valid revision, reports unsaved | linux + device | pending | Portable: passing (3b105a5) — `DocumentPackageStoreTests.testA07EveryFailingStepLeavesPreviousManifestReadable`, `FileSystemTests.testFaultInjectionNumbersMutatingOperationsAndBlocksAfterCrash`, `SaveSchedulerTests.testFailureReportsFailedKeepsEditsPendingAndLaterFlushRetries`; device low-disk run with the save-status UI (needs App/Editor) |
| A08 Interruption recovery | Termination during content write or manifest replace reopens a valid document | linux + device | pending | Portable: passing (3b105a5) — `DocumentPackageStoreTests.testA08CrashAtEveryStepReopensToPreOrPostState`, `testInvalidManifestFallsBackToLastKnownGood`, `testMissingCurrentPageFileIsRecoveredFromEarlierRevision`, `LibraryStoreTests.testLibraryManifestIsReplacedAtomicallyWithLKGFallback`; device force-quit during save |
| A09 Mixed selection | Move ink + text + image + shape together; one undo restores exact prior state | linux + sim | pending | Portable: passing (3b105a5) — `DocumentEditorTests.testA09GroupedMoveOfObjectsAndInkUndoesInOneStepAndRedoReapplies`, `testNestedGroupsFormOneRecordAndFailedCommandLeavesSnapshotUntouched`; simulator test through `NotebookEditorViewController` with the shared `UndoManager` (needs App/Editor) |
| A10 Partial erasing | Recolor, move, reopen, export partially erased ink without resurrecting erased regions | linux (reference engine) + sim (PencilKit) + device | pending | Portable: passing (3b105a5) — `ReferenceInkTests.testPartialEraseThenMoveAndRecolorKeepsMask`, `InkFixtureTests.testPartiallyErasedSampleKeepsMasksThroughTransformAndRoundTrip` over `Fixtures/ink/partially-erased.json`; simulator [run 34694155083](https://github.com/BKimble1/QuickWrite/actions/runs/34694155083): `EditorInkEngineTests.testTransformingAStrokeConcatenatesTheTransformAndKeepsTheEraseMask` and `testRecoloringKeepsPathTransformAndMaskAndOnlyChangesTheInkColour` prove the real PencilKit engine keeps the erase mask through transform and recolour. Still open: reopen-and-export after a partial erase, and a device check |
| A11 Page operations | Copy/move/delete/restore/reorder use stable IDs; neighbours untouched | linux | pending | Portable: passing (3b105a5) — `DocumentEditorTests.testA11PageOperationsKeepOtherPagesAndIDsStable`, `testMakeDuplicateAndCopiesOfPagesUseFreshIDsAndSharedAssets`, `testDeletingTheLastPageIsRefused`, `LibraryStoreTests.testDuplicateYieldsDistinctIdentifiersAndEqualContent`; stays pending until the Workspace session and the App/Editor page sheet drive the same commands end to end |
| A12 Text and links | Export keeps source text searchable; links functional where advertised | sim | **passed (sim), with a recorded limitation** | Simulator [run 34694155083](https://github.com/BKimble1/QuickWrite/actions/runs/34694155083): `InterchangeExportTests.testExportKeepsSourcePDFTextSearchable` exports the three-page `text-and-outline` fixture and asserts PDFKit reads the source text back and `findString` locates it. Links and outlines are **not** carried into the export: that is an accepted launch limitation stated in `PRODUCT_SPEC.md` §6, and it is recorded here rather than claimed as working |
| A13 Native archive | Export/import restores editable ink, objects, page metadata, Problem Pages and review items | linux + sim | pending | Portable: passing (3b105a5) — `ArchiveRoundTripTests.testDocumentRoundTripRestoresAnEqualSnapshotAndAssets`, `testRestoreAsCopyIsEqualModuloIdentifiers`, `testLibraryArchiveWithSeveralDocumentsRoundTrips`; still needed: Workspace `exportArchive`/`importFiles` end to end and a simulator check that a restored PencilKit ink blob is editable |
| A14 Invalid archive | Traversal, oversized expansion, missing assets, unsupported schema, bad checksums rejected; library untouched | linux | pending | Portable: passing (3b105a5) — `ArchiveRejectionTests` (40 cases), `ZipTests` (11 cases), `testOpeningABadArchiveLeavesTheDirectoryUntouched`; still needed: Workspace `restoreLibrary` proving the *library* (not just a directory) is untouched after a rejected archive |
| A15 OCR and search | Published corpus with error/search rates; stale index entries removed after edits | linux (index) + device (recognition) | pending | Portable: passing (3b105a5) — `CatalogDatabaseTests.testEditingPageRevisionDropsStaleRecognizedRecordsButKeepsTyped`, `testSearchDistinguishesNoMatchesFromNotYetIndexed`, `testDeletedPagesLeaveTheCatalog`; corpus (printed/scanned, neat, cursive, small, mixed equations, low-quality photos) with character error rate and query success table recorded below (needs App/Interchange recognizer and a device) |
| A16 Permissions | Camera denied, limited photos, no Pencil, no network each leave core notes usable | sim + device | pending | Simulator: deny camera/photos and exercise scan/insert paths; device: no Pencil (finger mode), airplane mode |
| A17 Layout and access | Portrait/landscape, keyboard, large text, VoiceOver, split width usable | sim + device | pending | Simulator screenshots per size class and Dynamic Type; Accessibility Inspector audit; device VoiceOver pass; ink position unchanged across rotation (pixel comparison) |
| A18 Purchases | Success, cancel, pending, revoked, offline, restore verified (only if monetization ships) | sim (StoreKit test config) + device (sandbox) | pending | `EntitlementStore` tests with a `.storekit` configuration; sandbox tester run. Marked `blocked` or n/a if no product ships |
| A19 Beta use | Several real lectures and assignment exports on device with no unresolved data-loss issue | device | pending | Log of sessions (date, notebook, page counts, exports), any data-loss reproduction and its fix commit |
| A20 Release evidence | Build/test reports, real screenshots, known limitations and exact source commit accompany the archive | Mac | pending | CI run URLs, `Build/Courseleaf.xcarchive` origin commit, screenshot set, this file |

## Portable test runs

Record each `swift test` run used as evidence (command, commit, result line).

| Date | Commit | Command | Result |
|---|---|---|---|
| 2026-09-12 | `3b105a5` | `export PATH=/opt/swift-root/usr/bin:$PATH && swift test --scratch-path .build-docs` (Linux x86_64, Swift 6.2.4, SQLite 3.45.1) | `Executed 203 tests, with 0 failures (0 unexpected) in 13.845 (13.845) seconds`; `Test Suite 'All tests' passed` |
| 2026-09-12 | `3b105a5` | `swift test --scratch-path .build-docs --parallel` (same toolchain) | 203/203 tests passed, exit code 0 |
| 2026-09-12 | `683238a` | `swift test` (same toolchain), after the Workspace façade landed | `Executed 219 tests, with 0 failures (0 unexpected) in 13.344 seconds` |
| 2026-09-12 | `2de9721` | `swift test --parallel`, after the whole app layer landed | 219/219 tests passed, exit code 0 |
| 2026-09-12 | `2de9721` | `swift run fixturegen <dir>` then `diff -r Fixtures <dir>` | no differences: all 19 fixtures (410,348 bytes) regenerate byte-identically |

Per-target counts at `3b105a5`: DocumentCoreTests 23, PageGeometryTests 18,
EditingTests 31, PersistenceTests 27, ArchiveTests 60, CatalogTests 28,
FixturesTests 15, WorkspaceTests 1 (API-only placeholder; total 203).

Per-target counts at `2de9721`: the same, with WorkspaceTests at 17 real
end-to-end tests instead of the placeholder (total 219). `LibraryService` and
`DocumentSession` now exist and are exercised: create/edit/flush/reopen, save
status ordering and latency, undo through the session, PDF and image import
against the alignment and 300-page fixtures, archive export and restore-as-copy,
validated library backup and both restore modes, trash, search scoping with
recognition invalidation, the course review queue, catalog rebuild, and a
document whose schema is too new.

## Continuous integration evidence

Every row is a real GitHub Actions run on the pushed commit
(`.github/workflows/courseleaf.yml`). CI is the only place an Apple SDK is
available in this project's remote sessions.

| Date | Commit | Job | Result |
|---|---|---|---|
| 2026-09-12 | `3b105a5` | `core-linux` (`swift:6.2-noble` container) | success: build + `swift test --parallel` |
| 2026-09-12 | `683238a` | `core-linux` | success |
| 2026-09-12 | `1f316ea` | `core-linux` | success |
| 2026-09-12 | `453373a` | `core-linux` | success |
| 2026-09-12 | `1f316ea` | `app-ios-simulator`, step "Core package builds with Xcode toolchain (macOS)" | success on Xcode 26.3 (17C529) |
| 2026-09-12 | `453373a` | `app-ios-simulator`, package targets | DocumentCore, PageGeometry, Persistence, Catalog, CSQLite, Editing, Archive, Fixtures and Workspace all compiled for `arm64-apple-ios-simulator` (iOS 26.2 SDK) |
| 2026-09-12 | `7627793` | `app-ios-simulator`, full job ([run 34694155083](https://github.com/BKimble1/QuickWrite/actions/runs/34694155083)) | **app built and `CourseleafTests` ran on an iPad simulator: `totalTestCount` 63, 0 failed, 0 skipped.** Per suite: AppShellTests 17, EditorInkEngineTests 6, EditorLayoutTests, EditorSearchTests, EditorToolStateTests, InterchangeInspectorTests, InterchangeExportTests, InterchangeOCRTests |

Getting there took eight real defects, each found from compiler or test-runner
output and fixed in the history: a missing Workspace product; a system-library
target Xcode cannot resolve inside a project; a caseless enum declaring a raw
type; four editor type errors; a PencilKit width API that does not exist under
either name we tried; `XCTUnwrap` given an `await` (an autoclosure cannot contain
one), which stopped the test bundle compiling; and a closure capturing `self`
before initialization.

Two of those were false-green defects in the harness itself and are worth
recording, because they made the job report success while proving nothing:

1. `Scripts/build-ios.sh` ended its `xcodebuild` pipeline with `|| true`, which
   resets `PIPESTATUS[0]` to zero. Three runs reported success while the app had
   failed to compile.
2. The zero-test guard added to catch that piped its output into `tee`, so its
   own non-zero exit was discarded too.

Both are fixed, and the summary step now **fails** the job when the result bundle
reports zero tests. A green `app-ios-simulator` job therefore now means the app
built, the bundle ran, and at least one test executed.

## Performance targets

Targets from the build prompt (G5). **Simulator timing is not a Pencil latency
benchmark**: the simulator has no Pencil input path, different GPU and CPU, no
ProMotion display, and its frame pacing does not represent an iPad. Screen
recordings are not latency measurements either. Each target below must be
measured on a physical iPad and recorded with hardware, OS build, source commit,
fixture, conditions (battery, thermal, background apps) and method.

| Target | Must be measured on a physical iPad as |
|---|---|
| 60 Hz-class navigation and drawing, no repeated app-induced main-thread stalls > 100 ms | Instruments Hangs and Animation Hitches during a 10-minute writing session on the baseline iPad; count of hangs > 100 ms attributable to the app |
| 10,000-stroke page stays usable for writing and panning | Same trace on the dense fixture page; input-to-render delay observed with the Pencil; memory of the page canvas |
| 300-page mixed PDF opens without a live canvas per page or uncontrolled memory growth | Memory graph while scrolling end to end; `PKCanvasView` instance count ≤ 3 (visible ±2 neighbours) |
| Completed normal edits reach a durable save within 1 s | `SaveStatus.saved(at:latency:)` latency histogram logged on device over a session; scheduler bounds (≤ 300 ms after last edit, ≤ 1 s after first) are unit-tested in `SaveSchedulerTests` but the disk latency is device-only |
| Geometric PDF export fixtures align within 1 PDF point | Exported fixture read back with PDFKit on device or simulator; difference table per rotation/crop case |

Baseline hardware: **to be chosen and recorded** (model, chip, iPadOS build, Pencil
generation). If a target is unrealistic on the chosen hardware, record the
measurement and agree a revised product limit here rather than adjusting the test.

## Unresolved failures

No test is failing. Linux passes 219/219 in the session and in CI. The iPad
simulator ran 63 tests with 0 failures at `7627793`.

Device rows remain open: no physical iPad or Apple Pencil exists in this
environment, so A02, A03, A06, A16, A17 and A19 have no evidence and must not be
marked otherwise. Simulator rows may now cite the run above where a named test
actually covers them; a row is only moved when the test that covers it is named.
