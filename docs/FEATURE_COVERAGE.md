# Feature coverage

The same ground as `docs/FEATURE_REGISTER.md` (F001–F112), grouped by the twelve
categories a student would recognise, with what Courseleaf does **today**, what
is missing, the evidence, what a gap depends on, and which phase should do it.

Written for the premium-editor release. It exists because a register of 112 rows
is good for looking one feature up and bad for answering "what is this app
actually like to use, and what is it not".

## How to read it

- **Now** — in the build, with named evidence in the register.
- **Partial** — the useful half is there and the missing half is named.
- **Gap** — not built. Says what it depends on and when it should happen.
- **Out of this release** — deliberately excluded, with the reason.

Phases: **P1–P8** are the backlog cards in `docs/BACKLOG.md`. **Separate** means
a different product decision, not a later sprint.

Where Goodnotes is the benchmark, its capabilities are compared as documented on
its own site and help centre. Several are **plan- or platform-restricted** there
(marked), which is the difference between "Goodnotes can" and "a student on the
plan and platform in front of them can" — the comparison is only useful with
that attached.

---

## 1. Library, folders, favourites, trash, covers, templates

**Now.** Folders and courses to any depth; recents, favourites, an Inbox for
quick notes, and a recoverable trash with restore and purge. Notebooks carry a
cover and a paper template (blank, lined, grid, dotted, Cornell, engineering
grid), and the template is real geometry shared with export, not a picture.
Rename, move, duplicate, delete. Library-wide backup to a validated archive, and
restore as copies or only-what-is-missing.

**Partial.** Covers are generated designs, not a gallery to browse. Template
choice is at creation and per page, but there is no custom-template import.

**Gaps.** Custom paper import (P2 — depends on nothing but a picker and a
validator). Cover artwork gallery (P1). Home-screen widgets (P1, `F021`).

**Evidence.** `LibraryStoreTests`, `LibraryServiceTests`, `ArchiveRoundTripTests`,
`ArchiveRejectionTests`, `AppShellTests`.

## 2. Page management, bookmarks, outlines, tabs, multiple windows

**Now.** Insert, duplicate, move, delete and restore pages; bookmarks; the
imported PDF's own outline; a page navigator with thumbnails; vertical scroll or
horizontal paging, and that choice is now remembered between notebooks. Deleted
pages go to a per-document recoverable list, not straight out.

**Partial.** Page operations all live in a modal navigator. At a wide size a
persistent thumbnail sidebar would be better than opening a sheet to move one
page — the brief asks for it and this release did not do it.

**Gaps.** Thumbnail sidebar (P1; depends on nothing — it is the same view
controller in a different container). Tabs across notebooks (P2). Multiple
windows: `UIApplicationSupportsMultipleScenes` is deliberately `false`, because
two scenes over one document package needs a second look at session ownership
first (P3, depends on `AppEnvironment` session keying).

**Evidence.** `PageNavigatorViewController`, `EditorLayoutTests`,
`DocumentEditorTests` page commands.

## 3. Pen, pencil, highlighter, palettes, favourites, erasers, gestures

**Now.** Three inks with honest names — Pen (`.pen`), Pencil (`.pencil`),
Highlighter (`.marker`) — each with width presets and bounds. **This release
rebuilt the toolbar**: it is a persistent row under the navigation bar; the six
tools, three widths for the active tool, a row of colours and saved favourites
are each one tap; favourites carry tool, colour and width together and are
editable, reorderable and kept across notebooks and relaunches. Pixel and
whole-stroke erasers. Pencil-only or finger drawing. **Scribble to erase** is
new and off by default. ⌘1–⌘6 switch tools.

**Partial.** Colour is a fixed palette plus recents plus a system picker; there
is no eyedropper and no per-palette organisation (P1). Opacity is not a control.

**Gaps.** Fountain/brush/ball-point pen *styles* (`F022`): PencilKit exposes
`.pen`, `.pencil`, `.marker` and nothing else through public API, so a fourth
name would be the same ink with a different label. Not built, and it will not be
until there is something real behind it. Stroke patterns (P2), hover preview
(P2), Pencil Pro squeeze and barrel roll (P2 — **device-only**, and nothing here
has ever touched an Apple Pencil).

**Evidence.** `EditorToolStateTests`, `EditorToolbarInteractionTests`,
`EditorToolStateMigrationTests`, `EditorToolbarUITests`, `ScribbleEraseTests`.

## 4. Lasso, reusable elements, locking, stacking, layers

**Now.** Freehand and rectangle lasso with per-kind filters (ink, text, images,
shapes, tape); move, scale, rotate, recolour, delete, duplicate, copy and paste
a mixed selection as one undoable operation, with PencilKit stroke transforms
and erase masks preserved. Object locking. Front/back ordering.

**Important correction.** Stacking is **within a compositing band**, not
arbitrary. Images draw below the ink layer; text, shapes and tape draw above it;
tape draws last. "Bring to front" reorders inside a band and cannot lift an
image above handwriting. The register and this document both say so; the UI
should say so too, and does not yet (P1, one sentence in the menu).

**Gaps.** Reusable elements/stickers (P2). Real layers (P2 — `Page.inkLayers` is
an array already, so the format is ready; the UI and the compositing rules are
not). Circle-to-select (P2).

**Evidence.** `SelectionTests`, `DocumentEditorTests`, `AppFlowTests` A09,
`CanvasAndExportGeometryTests.testTapePolicyAndCompositingBands`.

## 5. Shapes, ruler, snapping, connectors, diagramming

**Now.** Manual insertion of a line, arrow, rectangle or ellipse by dragging.
**New in this release**: freehand **shape recognition** with draw-and-hold —
draw a shape, hold at the end, a clean one is previewed, dragging resizes it,
lifting commits it as one undo step, and dragging it back to nothing keeps the
stroke as drawn. Straight lines, ellipses/circles and rectangles/squares only.
Snapping to the axes and to equal sides is configurable and never straightens a
deliberate diagonal.

**Partial.** A corrected shape is committed as ordinary ink, so it erases,
lassos, exports and prints exactly like handwriting — and cannot be re-opened
later as a parametric shape. That was the trade: it adds no new persisted type,
so there is no archive-compatibility surface to get wrong. Parametric conversion
is P2.

**Gaps.** Triangles and arrows in recognition (P2 — deliberately absent until
their geometry, selection and export are tested too). Ruler (P2). Connectors and
quick diagramming (P2).

**Evidence.** `ShapeRecognitionTests`, `ShapeAdjustment`, `StrokeGeometry`.

## 6. Text, handwriting conversion, spelling, recognition languages

**Now.** Text boxes with size, weight, design, alignment and colour, edited in
place. Handwriting **recognition for search** is built and measured (Vision,
English), so handwriting is findable.

**Partial.** Handwriting *conversion to editable text* (`F059`) is not a command
a student can run; the recognition that would back it exists and is measured.
P1, and it depends only on a UI for reviewing and inserting the result.

**Gaps.** Full-page typing (P2). Spelling (system behaviour in a `UITextView`;
not surfaced). Languages beyond English (P4 — each needs its own error-rate
measurement before it is claimed).

**Evidence.** `InterchangeOCRTests` (measured error rates), `EditorSearchTests`.

## 7. PDF, images, scanning, Files, export, printing

**Now.** Import PDFs (the 300-page fixture is a test case) and images; crop box,
rotation and page mapping are one coordinate system shared with export. Camera
scanning. Annotate a PDF as ordinary pages. Export PDF, PNG and the native
`.courseleaf` archive; print through the system panel; share via the share
sheet. Tape export policy is explicit.

**Partial.** Export cannot be cancelled once started, and exported files
accumulate in the temporary directory. The print panel anchors to the middle of
the window rather than to the button. All three are named in the register and
are P1.

**Also now.** Files "Open in Courseleaf", the share sheet and dropping a file
onto the library all reach the same import flow the file picker uses. The
declared document types have been in the Info.plist since the app shipped and
nothing answered them until this release. `LSSupportsOpeningDocumentsInPlace`
stays `false`: an opened file is imported as a copy, which is what the document
package model means, and saying so is better than half-supporting editing in
place.

**Gaps.** JPEG export exists in the code and is not reachable (P1).

**Evidence.** `InterchangeExportTests`, `PDFFixtureTests`, `PageMappingTests`,
`AppFlowTests` image export and printing.

## 8. Problem Pages, review, tape, flashcards, spaced repetition, timers

**Now.** Mark a region as a problem, cover the answer with tape, add it to a
**manual review queue** scoped by course, reveal and re-cover the answer, mark
reviewed, reopen. **New in this release**: review shows the actual page, cropped
to the item's region, redrawn when the answer is revealed — before this it
showed metadata and a button that changed a page the student could not see.
Deleted or unreadable source pages say so instead of showing a blank box.

**Called by its real name.** This is a list the student built. There is no
scheduler, nothing is ever due, and it is not spaced repetition (`F084`, P3).
Saying otherwise would be the easiest lie in the app to tell.

**Gaps.** Flashcards (P3), study timers (P3), a real scheduler (P3 — it needs a
scheduling model, a notification story and a way to not nag).

**Evidence.** `ReviewRulesTests`, `AppFlowTests` review queue, `ReviewPagePreview`.

## 9. Audio recording, note-linked replay, transcription

**Gap, entirely.** Nothing is built. It needs a recording engine, a time-to-ink
mapping in the document format, and a privacy story for recording lectures.
P5, and it is the largest single gap against the benchmark.

## 10. Backup, sync, document protection, recovery

**Now.** Every commit is assets → page files → revision → reference check →
atomic manifest replace, keeping a last-known-good manifest; a crash at any step
reopens to the pre- or post-state. Validated library backup and restore.
Recoverable trash. Unreadable ink is now reported rather than replaced, and a
notebook whose final save fails **stays open** with its pending work rather than
closing through the failure — the save scheduler keeps a failed commit's changes
so a retry can succeed, and closing regardless is what used to throw them away.

**Gaps.** Cloud sync — **out of this release** (see below). Per-document
passwords/Face ID (P3). Version history a student can browse (P3 — retained
revisions exist in the format already).

**Evidence.** `DocumentPackageStoreTests` A07/A08, `LibraryStoreTests`,
`ArchiveRejectionTests`.

## 11. Collaboration, cross-platform, AI, maths, whiteboards, text documents

**Out of this release, all of it**, and each is a separate project rather than a
backlog card:

| Area | Depends on | Acceptance |
| --- | --- | --- |
| Cloud sync | An account system, a conflict model for the document format, a server | Two devices edit the same notebook offline and converge without losing a stroke |
| Collaboration | Sync, plus presence and permissions | Two students write on one page and both see it |
| AI assistance | A paid service, a data-handling policy, a pricing decision | A student can say what leaves the iPad, and turn it off |
| Maths assistance | Recognition of notation, which is not the same problem as recognition of prose | Measured accuracy on a maths corpus, published like the OCR rates |
| Whiteboards | An unbounded canvas, which is a different geometry model | An infinite canvas that exports and prints |
| Text documents | A word-processing engine | — |
| Marketplace | Account infrastructure and a payments story | — |

Goodnotes offers versions of most of these; several are **plan-restricted**
(subscription) and some are **platform-restricted** (not on every OS it ships
on). None of it is implied to be missing "for now" here — none of it is started.

## 12. Accessibility, keyboard and Pencil hardware, performance, diagnostics

**Now.** VoiceOver labels, values and selected traits on every writing control;
Dynamic Type on the chrome; ~44pt targets with small glyphs; the writing row
scrolls rather than shrinking; reduce-motion respected by the shape preview;
dark appearance. Keyboard: undo/redo, zoom, fit, select-all, escape, page
navigation, and tool shortcuts — all of which stand down while a text box has
the keyboard, so arrows move the cursor and ⌘Z undoes typing.

**Gaps and honest limits.**

- **Every hardware behaviour is unverified.** There is no iPad and no Apple
  Pencil in this project's environment. Pencil latency, palm rejection, hover,
  squeeze, double-tap and the three-finger undo gesture are all **device-only**
  and stay open (`A02`, `A03`, `A06`, `A16`, `A17`, `A19` in
  `docs/VALIDATION.md`).
- **Performance targets are unmeasured on hardware.** The paths this release
  changed — ink serialization at a gesture boundary rather than on a timer, and
  eviction only serializing a page that is genuinely dirty — should reduce main-
  actor work on scroll, and that is an argument, not a measurement. The three
  workloads to measure are named in `docs/VALIDATION.md`: a dense drawing page,
  an image-heavy notebook, and the 300-page PDF fixture.
- Diagnostics: there is no in-app log or report-a-problem path (P2).

**Evidence.** `EditorToolbarInteractionTests` (labels, traits, target sizes),
`EditorToolbarUITests` (dark, landscape, portrait, accessibility text size,
with screenshots), `AccessibilityNotesView` in Settings.

---

## What this release deliberately did not do

Kept out on purpose, so the list above stays true: cloud sync, collaboration,
paid AI services, account infrastructure, a marketplace, and a new
whiteboard/text-document engine. Each is in the table in §11 with what it would
depend on and what would count as done.

Nothing was added as a button that does not work. Where a capability is missing,
the app either does not mention it or says plainly that it is not available.
