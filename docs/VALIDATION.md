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

## A01–A20

| Test | How it is verified | Environment | Status | Evidence (planned) |
|---|---|---|---|---|
| A01 Blank notebook | Create, write, close, force-terminate, relaunch; committed ink is present byte-for-byte | linux (package round trip) + device | pending | `DocumentPackageStoreTests.testCreateCommitReopenRoundTripsAndWritesOnlyChangedPages`; device run with ink asset digest before/after |
| A02 Dense drawing | Page with 10,000 strokes: pan, zoom, write; no sustained input stall | device | pending | Fixture `Fixtures/ink/dense-500.json` scaled to 10k via `InkFixtures`; Instruments (Time Profiler, Hangs) trace on device |
| A03 Drawing responsiveness | Usable 60 Hz interaction, no repeated app-induced main-thread stalls > 100 ms while writing | device | pending | Instruments Hangs/Animation Hitches on the baseline iPad; method and hardware recorded below |
| A04 PDF alignment | Annotations aligned at 0/90/180/270° and zoom levels, non-zero CropBox origins | linux + sim + device | pending | `PageMappingTests` (rotate 0/90/180/270 with crop origin, `testAlignmentFixturesAgreeWithSidecarWithin1e9`); simulator screenshot diff over `Fixtures/alignment-*.pdf`; device visual check |
| A05 Export alignment | Exported PDF matches page-space positions within 1 pt for geometric fixtures | linux (geometry) + sim (real export) | pending | `ExportGeometry` tests; simulator test exporting `alignment-*.pdf` fixtures and reading the marker back with PDFKit; `Fixtures/alignment.json` sidecar |
| A06 Long PDF | 300-page mixed PDF opens with live canvases only for visible ±2 pages; bounded memory | sim + device | pending | `Fixtures/long-300-mixed.pdf`; simulator test counting `PKCanvasView` instances; device memory graph |
| A07 Save failure | Simulated disk-full/write failure keeps last valid revision, reports unsaved | linux + device | pending | `DocumentPackageStoreTests.testA07EveryFailingStepLeavesPreviousManifestReadable`; `SaveSchedulerTests.testFailureReportsFailedKeepsEditsPendingAndLaterFlushRetries`; device low-disk run |
| A08 Interruption recovery | Termination during content write or manifest replace reopens a valid document | linux + device | pending | `DocumentPackageStoreTests.testA08CrashAtEveryStepReopensToPreOrPostState`, `testInvalidManifestFallsBackToLastKnownGood`, `testMissingCurrentPageFileIsRecoveredFromEarlierRevision`; device force-quit during save |
| A09 Mixed selection | Move ink + text + image + shape together; one undo restores exact prior state | linux + sim | pending | `EditingTests` grouped-undo test (to be written); simulator test through `NotebookEditorViewController` with shared `UndoManager` |
| A10 Partial erasing | Recolor, move, reopen, export partially erased ink without resurrecting erased regions | linux (reference engine) + sim (PencilKit) + device | pending | `ReferenceInkTests.testPartialEraseThenMoveAndRecolorKeepsMask`; `Fixtures/ink/partially-erased.json`; simulator `PencilKitInkEngine` test comparing rendered pixels before/after |
| A11 Page operations | Copy/move/delete/restore/reorder use stable IDs; neighbours untouched | linux | pending | `EditingTests` page command tests (to be written); `LibraryStoreTests.testDuplicateYieldsDistinctIdentifiersAndEqualContent` |
| A12 Text and links | Export keeps source text searchable; links functional where advertised | sim | pending | Simulator export of `Fixtures/text-and-outline.pdf`, PDFKit text search on the output. Links/outlines are an **accepted limitation** at launch (`PRODUCT_SPEC.md` §6) once recorded here |
| A13 Native archive | Export/import restores editable ink, objects, page metadata, Problem Pages and review items | linux | pending | `ArchiveRoundTripTests.testDocumentRoundTripRestoresAnEqualSnapshotAndAssets`, `testRestoreAsCopyIsEqualModuloIdentifiers`, `testLibraryArchiveWithSeveralDocumentsRoundTrips` |
| A14 Invalid archive | Traversal, oversized expansion, missing assets, unsupported schema, bad checksums rejected; library untouched | linux | pending | `ArchiveRejectionTests` (40 cases) and `ZipTests`; `testOpeningABadArchiveLeavesTheDirectoryUntouched` |
| A15 OCR and search | Published corpus with error/search rates; stale index entries removed after edits | linux (index) + device (recognition) | pending | `CatalogDatabaseTests.testEditingPageRevisionDropsStaleRecognizedRecordsButKeepsTyped`, `testSearchDistinguishesNoMatchesFromNotYetIndexed`; corpus (printed/scanned, neat, cursive, small, mixed equations, low-quality photos) with character error rate and query success table recorded below |
| A16 Permissions | Camera denied, limited photos, no Pencil, no network each leave core notes usable | sim + device | pending | Simulator: deny camera/photos and exercise scan/insert paths; device: no Pencil (finger mode), airplane mode |
| A17 Layout and access | Portrait/landscape, keyboard, large text, VoiceOver, split width usable | sim + device | pending | Simulator screenshots per size class and Dynamic Type; Accessibility Inspector audit; device VoiceOver pass; ink position unchanged across rotation (pixel comparison) |
| A18 Purchases | Success, cancel, pending, revoked, offline, restore verified (only if monetization ships) | sim (StoreKit test config) + device (sandbox) | pending | `EntitlementStore` tests with a `.storekit` configuration; sandbox tester run. Marked `blocked` or n/a if no product ships |
| A19 Beta use | Several real lectures and assignment exports on device with no unresolved data-loss issue | device | pending | Log of sessions (date, notebook, page counts, exports), any data-loss reproduction and its fix commit |
| A20 Release evidence | Build/test reports, real screenshots, known limitations and exact source commit accompany the archive | Mac | pending | CI run URLs, `Build/Courseleaf.xcarchive` origin commit, screenshot set, this file |

## Portable test runs

Record each `swift test` run used as evidence (command, commit, result line).

| Date | Commit | Command | Result |
|---|---|---|---|
| (none recorded yet) | | `swift test --parallel` | |

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

None recorded yet (no runs).
