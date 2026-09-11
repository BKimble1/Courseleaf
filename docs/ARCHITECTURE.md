# Courseleaf architecture

Courseleaf (internal codename; not a cleared public name) is a native iPad
notebook for handwriting and PDF coursework with an original Problem Page and
review workflow. This document is the contract every module follows. Change it
in the same commit as the code it describes.

## 1. Layering

```
App/Courseleaf (iPadOS 18, SwiftUI shell + UIKit editor)
  ├─ Library, Editor, ProblemInspector, Review, Search, Export, Settings (screens)
  ├─ InkEngine/PencilKitInkEngine       PencilKit adapter (PKDrawing <-> InkDrawing)
  ├─ Interchange/                        PDFKit/CoreGraphics import & export, scanner, OCR, printing
  └─ Entitlements/                       StoreKit 2 behind EntitlementStore

Swift package "CourseleafCore" (builds and tests on Linux and Apple)
  DocumentCore   model types, IDs, geometry primitives, SHA-256, ink abstraction, snapshot validation
  PageGeometry   PDF boxes/rotation, page <-> canvas <-> export transforms, paper template geometry
  Editing        DocumentEditor: commands, undo groups, selection, Problem Pages, review queue rules
  Persistence    managed library and document packages: atomic commits, revisions, trash, recovery, GC
  Archive        .courseleaf archive container, validation, document/library export & import
  Catalog        rebuildable SQLite catalog + FTS5 search index, indexing state, course review queue
  Fixtures       deterministic test fixtures (minimal PDF writer, dense ink, malformed inputs)
```

Rules:

- Business and document logic lives in the package and is unit-tested there.
  App code adapts frameworks (PencilKit, PDFKit, Vision, StoreKit) and drives UI.
- No app-wide mutable singleton. `AppEnvironment` is created once in the app
  entry point and injected; every store is an actor or `@Observable` object
  owned by it.
- Abstractions exist only where there is a concrete current use or a specified
  later compatibility need (`InkEngine`, `FileSystem`, `EntitlementStore`,
  `TextRecognizer`).

## 2. Ownership and truth

- **Document packages are authoritative.** Each notebook is a directory
  package (see `docs/FORMAT.md`). Its manifest is replaced atomically and only
  after every file it references exists and validates.
- **The catalog is derived.** `Catalog` holds a SQLite database rebuildable by
  scanning `library.json` and every package. Losing it costs search speed and
  nothing else. Search records are keyed by page revision so stale data is
  invalidated deterministically.
- **Previews are disposable.** Thumbnails and OCR caches may be deleted at any
  time.
- **Assets are immutable and content-addressed** (`assets/<xx>/<sha256>.<ext>`).
  Imported PDFs and images are stored byte-for-byte; ink blobs are the engine's
  native serialization. Garbage collection removes a file only when no live
  page, deleted page (trash), retained revision, in-flight export or (future)
  sync queue references it.

## 3. Coordinate system

There is exactly one document coordinate system, **page space**:

- Units are PDF points (1/72 in).
- Origin is the top-left corner of the *visible* page, x right, y down.
- The visible page is the PDF CropBox (intersected with the MediaBox) after
  applying the page's `/Rotate` value; for template pages it is the page size.
- Every stored geometry (object frames, ink drawing data, problem result
  regions, review regions, search bounds) is in page space.

`PageGeometry.PageMapping` provides the transforms:

| Transform | Use |
|---|---|
| `pdfUserToPage` | position PDFKit/CoreGraphics page content under the overlay |
| `pageToPDFUser` | export annotations back into the source page's user space |
| `pageToCanvas(scale:offset:)` / `canvasToPage` | screen coordinates for editing and hit testing |

Rotation cases 0/90/180/270 and non-zero CropBox origins are explicit test
cases (`PageGeometryTests`), and the same mapping is used for editing,
selection, recognition boxes and export. Acceptance A04/A05 depend on this.

PencilKit draws in the canvas view's coordinate space. The canvas for a page
is laid out so that one canvas point equals one page point at zoom 1 with the
canvas origin at the page origin; zoom is applied by the containing scroll
view. Drawing data is therefore stored in page space without conversion.

## 4. Compositing order

Back to front, identical on screen and in PDF/image export:

1. Page background: paper template (procedural) or source PDF page / image.
2. **Image objects** (photos, pasted slides) in page order.
3. **Ink layer** (PencilKit canvas; pen, pencil and highlighter strokes with
   the engine's own blending).
4. **Text, shape and tape objects** in page order.

Known limitation (launch): ink is always above images and below text/shapes.
Object ordering commands (bring to front / send to back) reorder within a
band; the UI does not offer moving ink between bands. Tape is always drawn
last so it covers what it is meant to cover.

## 5. Ink engine

`DocumentCore.InkEngine` / `InkDrawing` describe the operations the editor
needs beyond drawing: bounds, hit testing (rect and freehand polygon),
transform, recolor, remove, extract, append. The app implements
`PencilKitInkEngine` with public PencilKit APIs:

- Drawing data is `PKDrawing.dataRepresentation()` stored as an immutable
  asset; the package never re-encodes it.
- Stroke transforms set `PKStroke.transform`, which moves the stroke path and
  its erase `mask` together. Recoloring constructs a new `PKStroke` with the
  same `path`, `transform` and `mask` and a new `PKInk`. Partially erased ink
  never reappears (A10).
- Erasing uses `PKEraserTool(.bitmap)` (pixel/partial) and `PKEraserTool(.vector)`
  (whole stroke). Both are public APIs.
- Input policy uses `PKCanvasView.drawingPolicy` (`.pencilOnly` by default,
  `.anyInput` when finger drawing is enabled).
- Freehand and rectangular lasso, selection filters, and multi-object
  transforms are app-owned (`SelectionController`), not PencilKit's built-in
  lasso, because PencilKit's lasso only knows its own strokes.

`ReferenceInkEngine` (polyline strokes with masks) implements the same
protocol on Linux so editing, persistence and export-geometry tests exercise
the real semantics.

## 6. Editing and undo

`Editing.DocumentEditor` owns a `DocumentSnapshot` and applies `EditCommand`
values. Every command is invertible and records a `ChangeSet`. A user
operation that touches several things (move ink + text + image together,
delete a page and its review items) is one `CompositeCommand` and therefore
one undo step (A09).

In the app a single `UndoManager` per open document is shared by the
`NotebookEditorViewController` (which overrides `undoManager`) and every
`PKCanvasView` it hosts, so stroke undo and object undo interleave correctly.
Ink changes are recorded as `ReplaceInk(pageID, layerID, old, new)` commands
whose payloads are engine blobs.

Locking: locked objects are excluded from selection hit tests and transform
commands; commands on a selection that contains locked or mixed-kind objects
are filtered to the actions valid for every member, and the UI hides the rest.

## 7. Persistence and save timing

- One writer per open document (`DocumentStore` is an actor). Commits write
  new assets, then changed page files, then the revision record, verify every
  reference, then atomically replace `manifest.json`; the previous manifest
  is retained as `manifest.lkg.json` (last known good).
- `SaveScheduler` coalesces edits: a commit starts at most 300 ms after the
  last edit and no later than 1 s after the first uncommitted edit, plus an
  explicit flush when leaving a page or the editor and when the app resigns
  active. The commit latency is measured and recorded (`SaveStatus.saved(at:latency:)`).
- The UI shows `unsaved`, `saving`, `saved` and `failed(reason)`. `saved` is
  set only after the manifest rename completed and the directory was synced.
- Failures (disk full, permission, interrupted commit) leave the previous
  manifest intact; the store reports the error and keeps the in-memory state
  so the student can retry or export a copy. Recovery on open: parse the
  manifest, fall back to `manifest.lkg.json`, then verify each page file and
  asset; a page whose current file is missing is recovered from its most
  recent revision file that still exists.
- Nothing heavy runs in the drawing path: serialization, hashing, thumbnails,
  OCR and export run on background tasks after the stroke ends.

## 8. Virtualization and memory

The editor keeps live `PageCanvasView`s (PKCanvasView + object layer + tiled
background) for the visible page and its two neighbours only. Other pages are
placeholders showing a cached thumbnail. Thumbnail and background caches are
`NSCache`-bounded. A 300-page PDF therefore never allocates 300 canvases (A06).

## 9. Search and recognition

- Search records: `(documentID, pageID, revisionID, kind, text, bounds, language, confidence)`.
  Kinds: `title`, `typed`, `pdfText`, `recognized`.
- Typed text and titles are indexed synchronously on commit. PDF text
  extraction (PDFKit) and OCR (Vision `VNRecognizeTextRequest`) run in
  `RecognitionQueue`, which indexes only changed or requested pages, is
  cancellable, and reports per-page state: `notIndexed`, `queued`, `indexed`,
  `failed`. Search results show "not yet indexed" distinctly from "no matches".
- Recognized text is derived data and never replaces ink. Conversion to a text
  object shows an editable preview first.

## 10. Threading

- Stores are actors; UI state objects are `@MainActor @Observable`.
- The editor view controller and PencilKit run on the main thread; everything
  else (commit, hashing, thumbnails, PDF rendering for export, OCR) runs on
  background tasks with cancellation.

## 11. Rationale for key decisions

- **PencilKit** gives Apple Pencil latency and tool behaviour that a custom
  renderer would take months to match. Its limits (no mixed-object lasso, no
  custom brush) are handled in the app layer, not by private API.
- **Package + rebuildable catalog** keeps a notebook a single self-contained
  directory that can be backed up, exported and recovered without a database.
- **Page space in PDF points** removes conversions between editing,
  recognition and export; rotation and cropping are solved once.
- **iPadOS 18 baseline**: `@Observable`, `NavigationSplitView` columns,
  `PKToolPicker` custom items, Swift 6 toolchain. Recorded in `docs/PRODUCT_SPEC.md`.
