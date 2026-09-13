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
| A04 PDF alignment | Annotations aligned at 0/90/180/270° and zoom levels, non-zero CropBox origins | linux + sim + device | pending | Portable: passing (3b105a5) — `PageMappingTests.testRotate0/90/180/270WithCropOrigin`, `testRoundTripsWithin1e9ForEveryRotation`, `testAlignmentFixturesAgreeWithSidecarWithin1e9`, `testCropBoxIsIntersectedWithMediaBoxAndDisplaySizeMatchesModel`; simulator [run 34694155083](https://github.com/BKimble1/Courseleaf/actions/runs/34694155083): `InterchangeExportTests.testExportKeepsSourcePDFSquareAtItsExpectedPageRectForEveryRotationAndCrop` proves placement for every rotation and crop origin **in the exported page**. Still open: alignment of the live overlay at several zoom levels on screen, which needs a device or a UI test |
| A05 Export alignment | Exported PDF matches page-space positions within 1 pt for geometric fixtures | linux (geometry) + sim (real export) | **passed (sim)** | Linux: `CanvasAndExportGeometryTests`, `PageMappingTests.testSourcePageTransformPlacesRotatedPageContentAtPageOrigin`. Simulator [run 34694155083](https://github.com/BKimble1/Courseleaf/actions/runs/34694155083): `InterchangeExportTests.testExportPlacesAnObjectWithinOnePointOfItsPageRect` samples 1 pt inside and 1 pt outside every edge of an exported object, and `testExportKeepsSourcePDFSquareAtItsExpectedPageRectForEveryRotationAndCrop` checks all eight rotation and crop-origin fixtures against the `Fixtures/alignment.json` sidecar. Device re-check still worthwhile but not required for this claim |
| A06 Long PDF | 300-page mixed PDF opens with live canvases only for visible ±2 pages; bounded memory | sim + device | pending | Simulator [run 34694155083](https://github.com/BKimble1/Courseleaf/actions/runs/34694155083): `EditorLayoutTests.testPoolNeverExceedsItsLiveLimitScrollingThroughThreeHundredPages` scrolls a 300-page layout and asserts the live-canvas pool never exceeds its limit. Still open: opening the real `Fixtures/long-300-mixed.pdf` end to end and a device memory graph |
| A07 Save failure | Simulated disk-full/write failure keeps last valid revision, reports unsaved | linux + device | pending | Portable: passing (3b105a5) — `DocumentPackageStoreTests.testA07EveryFailingStepLeavesPreviousManifestReadable`, `FileSystemTests.testFaultInjectionNumbersMutatingOperationsAndBlocksAfterCrash`, `SaveSchedulerTests.testFailureReportsFailedKeepsEditsPendingAndLaterFlushRetries`; device low-disk run with the save-status UI (needs App/Editor) |
| A08 Interruption recovery | Termination during content write or manifest replace reopens a valid document | linux + device | pending | Portable: passing (3b105a5) — `DocumentPackageStoreTests.testA08CrashAtEveryStepReopensToPreOrPostState`, `testInvalidManifestFallsBackToLastKnownGood`, `testMissingCurrentPageFileIsRecoveredFromEarlierRevision`, `LibraryStoreTests.testLibraryManifestIsReplacedAtomicallyWithLKGFallback`; device force-quit during save |
| A09 Mixed selection | Move ink + text + image + shape together; one undo restores exact prior state | linux + sim | **passed (sim)** | Portable: passing (3b105a5) — `DocumentEditorTests.testA09GroupedMoveOfObjectsAndInkUndoesInOneStepAndRedoReapplies`, `testNestedGroupsFormOneRecordAndFailedCommandLeavesSnapshotUntouched`; simulator [run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941): `AppFlowTests.testGroupedMoveOfMixedSelectionUndoesInOneStepThroughTheEditorViewController` moves a text box, an image and a shape together with a replaced ink layer through the real view controller, undoes once and asserts the snapshot equals the prior one exactly, asserts the other page is untouched, redoes to the moved snapshot, then undoes, flushes, closes and reopens the document to show the undone state is what reached disk. The device gate (a lasso drag with a Pencil) is still open |
| A10 Partial erasing | Recolor, move, reopen, export partially erased ink without resurrecting erased regions | linux (reference engine) + sim (PencilKit) + device | pending | Portable: passing (3b105a5) — `ReferenceInkTests.testPartialEraseThenMoveAndRecolorKeepsMask`, `InkFixtureTests.testPartiallyErasedSampleKeepsMasksThroughTransformAndRoundTrip` over `Fixtures/ink/partially-erased.json`; simulator [run 34694155083](https://github.com/BKimble1/Courseleaf/actions/runs/34694155083): `EditorInkEngineTests.testTransformingAStrokeConcatenatesTheTransformAndKeepsTheEraseMask` and `testRecoloringKeepsPathTransformAndMaskAndOnlyChangesTheInkColour` prove the real PencilKit engine keeps the erase mask through transform and recolour. Still open: reopen-and-export after a partial erase, and a device check |
| A11 Page operations | Copy/move/delete/restore/reorder use stable IDs; neighbours untouched | linux | pending | Portable: passing (3b105a5) — `DocumentEditorTests.testA11PageOperationsKeepOtherPagesAndIDsStable`, `testMakeDuplicateAndCopiesOfPagesUseFreshIDsAndSharedAssets`, `testDeletingTheLastPageIsRefused`, `LibraryStoreTests.testDuplicateYieldsDistinctIdentifiersAndEqualContent`; stays pending until the Workspace session and the App/Editor page sheet drive the same commands end to end |
| A12 Text and links | Export keeps source text searchable; links functional where advertised | sim | **passed (sim), with a recorded limitation** | Simulator [run 34694155083](https://github.com/BKimble1/Courseleaf/actions/runs/34694155083): `InterchangeExportTests.testExportKeepsSourcePDFTextSearchable` exports the three-page `text-and-outline` fixture and asserts PDFKit reads the source text back and `findString` locates it. Links and outlines are **not** carried into the export: that is an accepted launch limitation stated in `PRODUCT_SPEC.md` §6, and it is recorded here rather than claimed as working |
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
| 2026-09-12 | `7627793` | `app-ios-simulator`, full job ([run 34694155083](https://github.com/BKimble1/Courseleaf/actions/runs/34694155083)) | **app built and `CourseleafTests` ran on an iPad simulator: `totalTestCount` 63, 0 failed, 0 skipped.** Per suite: AppShellTests 17, EditorInkEngineTests 6, EditorLayoutTests, EditorSearchTests, EditorToolStateTests, InterchangeInspectorTests, InterchangeExportTests, InterchangeOCRTests |

| 2026-09-12 | `9d683f4` | `core-linux` and `app-ios-simulator`, full run ([run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941)) | **69 simulator tests, 0 failures**, plus 219 Linux tests, 0 failures. Adds `AppFlowTests`: end-to-end undo through the editor view controller, image export geometry and encoding, printing, the review queue and library search |

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

## Premium-editor release (2026-09-12)

What this release's own tests prove, and what they deliberately do not.

**Proved by test, on Linux (`core-linux`) and the iPad simulator
(`app-ios-simulator`).**

| Claim | Test |
|---|---|
| A serialization still in flight when a page's drawing is replaced writes nothing, and the replacement is what reaches disk | `EditorReliabilityTests.testAStaleSerializationCannotOverwriteInkThatReplacedIt` — closes the session, reopens the package, compares the restored asset |
| Strokes drawn while an earlier serialization is stuck are all saved | `…testStrokesAfterASlowSerializationAreStillSaved` — three strokes, reopened and counted |
| Evicting a page with a serializer that never finishes still commits | `…testEvictingAPageCommitsInkThatHasNotBeenSerializedYet` |
| An immediate undo of a first stroke removes it | `…testAFirstStrokeCanBeUndoneImmediately` |
| Two quick strokes are two undo steps | `…testTwoQuickStrokesAreTwoUndoSteps` |
| Undoing a clear page restores what was on screen | `…testUndoingClearPageRestoresTheStrokeThatWasStillOnScreen` |
| The Edit menu / three-finger-swipe manager steps the document's history | `…testTheResponderChainManagerStepsTheDocumentsHistory` |
| PencilKit's registrations never reach the editor's UndoManager | `…testPencilKitRegistrationsNeverReachTheEditorsUndoManager` |
| Undecodable ink is reported, refuses input, keeps its asset | `…testAPageWhoseInkCannotBeReadRefusesInputAndKeepsItsAsset`, `…testTheLoaderTellsMissingApartFromUnreadableAndEmpty` |
| Export sees a stroke that has not left its canvas | `…testTheExportBarrierSeesAStrokeThatHasNotLeftTheCanvas` |
| Saved preferences from the shipped build survive the new schema | `EditorToolStateMigrationTests` — decodes a version-1 blob written by the shipped build, asserts every field, and that favourites are seeded from the student's own pens |
| One tap to a favourite, a visible colour, a visible width | `EditorToolbarInteractionTests`, `EditorToolbarUITests` |
| A colour change updates buttons in place rather than rebuilding the row | `EditorToolbarInteractionTests.testChangingColourUpdatesTheExistingButtonsInsteadOfRebuildingTheRow` |
| Scribble erase accepts a cross-out and refuses a sine wave, repeated letters, shading, hatching, a zigzag drawing and a summation sign | `ScribbleEraseTests` (Linux) |
| Shape correction keeps a 30° diagonal diagonal, snaps a 2° line flat, refuses a scribble | `ShapeRecognitionTests` (Linux) |
| A search or review deep link reaches the region, not just the page | `DeepLinkAndReviewTests` |
| Review shows the work, and revealing the answer changes the picture | `DeepLinkAndReviewTests.testReviewRendersThePageAndTheTapeStateItIsActuallyIn` |

**Screenshots.** `EditorToolbarUITests` attaches screenshots of the real
simulator UI — default, highlighter selected, colour and width changed, a
favourite applied, the options menu, landscape, portrait, dark appearance and an
accessibility text size — to `Build/CourseleafTests.xcresult`, which the
`app-ios-simulator` job uploads as the `ios-simulator-results` artifact.

**Not proved, and not claimed.**

- Nothing here touched an Apple Pencil. Every hardware behaviour — latency, palm
  rejection, hover, the three-finger undo gesture, and whether the hold in
  draw-and-hold feels right in the hand — is **device-only**. The checklist for
  it is `docs/DEVICE_CHECKLIST.md`.
- No performance target below has been measured. The paths this release changed
  (ink serialization at a gesture boundary instead of on a timer; eviction
  serializing only a page that is genuinely dirty) are an argument that main-
  actor work on scroll went down, not a measurement that it did.
- Scribble erase and draw-and-hold have Linux evidence for their *decisions* and
  no simulator or device evidence for their *timing*. A gesture that is right in
  principle and wrong in the hand is still wrong.

**A false green, found and fixed.** The `core-linux` job ran
`swift test --parallel 2>&1 | tee test-output.log`, so the step reported `tee`'s
exit code and not the test run's. It went green on a run with three failing
tests in this very release. The step is `bash` with `pipefail` now, and the
verdict reads `swift test`'s xUnit report — because with `--parallel` a passing
run prints no "Executed N tests" line at all, only failures get one, so the log
could not be counted. This is the third false-green defect this project has
found in its own harness; all three are recorded here.

## Defects the end-to-end tests found

Driving the real screens rather than the engine underneath turned up seven
things the module tests could not see. They are recorded here because "the
tests pass" is only meaningful alongside what the tests caught.

1. **Selected-page export used the caller's order** rather than document order,
   so exporting a selection could produce a PDF with the pages shuffled. Fixed
   in `PDFExporter.selectedPages` at `7627793`.
2. **The review queue lost the answer tape reference.** The catalog's projection
   of a review item deliberately omitted `answerTapeID`, but
   `ReviewQueueViewModel` reads it to reveal or hide the answer — so revealing
   an answer from the queue silently did nothing whenever the catalog was
   available, which is the normal path, while working on the package-scan
   fallback. The tape id is now catalogued (schema version 2, rebuilt on
   mismatch like any other index change).
3. **Reviewed items were unreachable.** The service returned only pending items,
   so the queue's own "show reviewed" toggle and `reopen` action could never act
   on anything. `reviewQueue` now takes `includeReviewed:` and both the catalog
   and fallback paths honour it; the view model asks for everything and filters.

The first simulator runs that compiled every new target found five more.

4. **A second search hit left the first highlight on the page.** Navigating to
   another result cancelled the task that was going to clear the previous
   highlight — which is the task that clears it — so the old yellow band stayed
   until the page was rebuilt. The highlighted page is now tracked and cleared
   explicitly. `DeepLinkAndReviewTests.testTheHighlightIsClearedAndDoesNotFollowTheStudentToAnotherPage`.
5. **Undo through the responder chain offered no redo.** The bridge refused to
   register while the manager had a group open, and a manager running an undo
   always does — so the registration that builds the redo stack never happened.
   The undoing and redoing cases are handled before that guard now.
   `EditorReliabilityTests.testTheResponderChainManagerStepsTheDocumentsHistory`.
6. **A stored preferences blob with no fields reset the toolbar.** Migration
   seeded favourites from the *default* presets whenever the `favorites` key was
   absent, rebuilding the shipped set under new identifiers and pushing two
   favourites off the end. It now seeds only from presets that were really
   stored. `EditorToolStateMigrationTests.testAValueWithNoFieldsAtAllDecodesToTheDefaults`.
7. **A test was not testing what it said.** The unreadable-ink case fed PencilKit
   a short ASCII string, which PencilKit accepts, returning an empty drawing — so
   the assertions ran against a blank page rather than a failed load. The fixture
   now uses bytes PencilKit refuses, and the test asserts that it refuses them
   before relying on it.
8. **The shipped highlighter favourite was never on the row.** The toolbar shows
   two favourites at its narrowest tier and three at its medium one, and the
   editor is a `NavigationSplitView` detail pane — so with the library sidebar
   showing it is about 840 points wide on a 13-inch iPad in *either* orientation,
   never the widest tier. The shipped order put the highlighter fifth, behind
   three more pens, so the one tap favourites exist to save — pen to highlighter
   — was not available in any default layout, on any iPad, while the release
   notes promised it. The pen and the highlighter are now first and second.
   `EditorToolbarInteractionTests.testAPenAndAHighlighterAreBothOnTheRowAtEveryTier`
   asserts it for every tier, and `EditorToolbarUITests.testSwitchingBetweenTwoFavouritesIsOneTapEach`
   taps them in the running app.

   Worth naming plainly: this one was found by a UI test failing for what looked
   like its own reason — it asked for the fifth favourite and did not get it —
   and the first two attempts to fix it treated the test as wrong about the
   device. The test was wrong about the *app*, and so was the feature.

## Unresolved failures

No test is failing. Linux passes 222/222 in the session and in CI. The iPad
simulator ran 69 tests with 0 failures at `9d683f4` [run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941).

Device rows remain open: no physical iPad or Apple Pencil exists in this
environment, so A02, A03, A06, A16, A17 and A19 have no evidence and must not be
marked otherwise. Simulator rows may now cite the run above where a named test
actually covers them; a row is only moved when the test that covers it is named.
