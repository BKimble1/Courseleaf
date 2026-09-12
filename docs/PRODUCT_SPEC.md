# Product specification (launch)

What the first Courseleaf release does, screen by screen, and what it deliberately
does not do. "Courseleaf" is a codename; the public name is chosen at release
(`docs/RELEASE_CHECKLIST.md`). Behaviour described here is the target the code in
`Sources/` and `App/` is written to; verification status lives in
`docs/FEATURE_REGISTER.md` and `docs/VALIDATION.md`, never here.

## 1. Product in one paragraph

A native iPad notebook for students who write by hand, annotate lecture PDFs and
revisit their work before exams. Everything works offline, without an account, and
without any AI service. Notebooks are self-contained document packages the student
can export, back up and restore. The original workflow is the **Problem Page**: a
page with student-defined problem fields and a status, which can be sent to a
course-level **review queue** and revisited in place.

## 2. Platform and deployment target

- **iPadOS 18.0 or later, iPad only** (`TARGETED_DEVICE_FAMILY = 2`). No iPhone or Mac
  target at launch; the iPad binary running on a Mac is not a supported product.
- Rationale for 18.0: the app uses `@Observable` view models, `NavigationSplitView`
  column behaviour, `PKToolPicker` custom tool items, PencilKit stroke/mask APIs and
  the Swift 6 toolchain in Swift 5 language mode. Supporting 17 would require
  parallel view-model and tool-picker code paths for little audience gain among
  students on current iPads. Tradeoff recorded: iPads that cannot run iPadOS 18 are
  excluded. The choice is re-checked against the SDK actually used for the release
  archive (`RELEASE_CHECKLIST.md`).
- Orientation: portrait and landscape. Multi-scene (multiple windows) is off at launch.
- Requires: nothing. Apple Pencil is recommended; finger drawing is a setting.
  Camera and photo library are optional and used only when the student starts a
  scan or picks an image.

## 3. Screens

### 3.1 Library

- Sidebar scopes: Recents, Favorites, Inbox (unfiled quick notes), Courses/folders
  (nested), Trash. Content area shows notebooks as a grid of original covers or as a
  list with title, modified date, page count and pending-review count.
- Create: notebook (title, paper, page size, cover; sensible defaults; opens
  immediately), folder or course (a course folder owns a review queue), quick note
  (one tap, default paper, lands in Inbox with an obvious "File in…" action later).
- Item actions: open, rename, move, duplicate, favourite, change cover, delete (to
  Trash). Folder delete moves the whole subtree to Trash. Trash lists documents and
  folders with restore, delete permanently and empty.
- Import button and drag-and-drop accept PDF, PNG/JPEG and `.courseleaf` archives
  (section 3.6). Search field opens the Search screen scoped to the current folder.
- A document whose package schema is newer than the app shows as read-only
  "Needs a newer version of the app"; it is never opened as empty.

### 3.2 Notebook Editor

- Large writing surface; compact top toolbar (tools, undo/redo, page navigator,
  reading mode, search-in-document, share/export, more); tool options in a popover.
  Controls stay reachable at narrow split widths by collapsing to a menu.
- Tools: Pen, Pencil, Highlighter (PencilKit inks; width and colour presets, custom
  colour), Eraser (pixel or whole stroke), Lasso (freehand or rectangle with content
  filters: ink, text, images, shapes, tape), Text box, Image, Shape (line, arrow,
  rectangle, ellipse), Tape.
- Input: Pencil-only drawing by default; finger drawing is a setting. Two-finger
  pan/zoom always works. Palm rejection is PencilKit's behaviour and is validated
  on a device, not claimed from the simulator.
- Selection: only actions valid for every selected object are shown (move, resize,
  rotate, copy, cut, paste, duplicate, delete, recolor, lock/unlock, bring to
  front/send to back, edit text, crop image, reveal/hide tape, add to review). Locked
  objects are not selectable by lasso. One user operation is one undo step.
- Pages: thumbnails strip/sheet with insert (blank, from template, duplicate),
  reorder, move/copy to another notebook, delete (recoverable from the notebook's
  page trash), bookmark; imported PDF outlines are listed for navigation.
- Reading mode: no edits, links in imported PDFs followable, page turning and zoom
  only.
- Save status is always visible: Unsaved, Saving, Saved (after durable commit), or
  Failed with the reason and Retry / Export a copy actions. Leaving a page, closing
  the editor and the app resigning active flush pending edits.
- State restoration: last viewed page, zoom and tool return on reopen.
- Keyboard: standard shortcuts (undo/redo, next/previous page, zoom, tool switching,
  find) via `UIKeyCommand`; the on-screen keyboard never covers the text box being
  edited.

### 3.3 Problem Inspector

Opened from the editor for the current page.

- Toggle "Problem Page" on/off (off keeps the page as an ordinary page; turning it
  off clears the metadata after confirmation).
- Fields: Title (required when on), Source reference, Given, Find (all free text).
- Result region: "Set on page" draws a rectangle in page coordinates; clear removes it.
- Status: Unfinished, Check again, Understood.
- Review: "Add page to review" or "Add region to review" with an optional prompt;
  lists existing review items for this page with their state and a "Cover answer
  with tape" shortcut that places a tape over the result region and links it to the
  item.
- All edits are undoable in the editor's undo stack and persist through save,
  archive export/import and recovery.

### 3.4 Review Queue

- Reached from a course in the Library or from the sidebar ("Review"). Scope: one
  course (folder subtree) or everything, including unfiled notebooks.
- List of pending items: notebook title, page number, problem title/status, prompt,
  when added, last reviewed.
- Opening an item shows the page (or the region, zoomed) in a review view: the tape
  covering the answer, if any, is tappable to reveal/hide; Mark reviewed; Reopen
  (for reviewed items); Go to page (opens the editor at the exact location).
- The queue is a manual, contextual list ordered by creation date. It is **not** a
  spaced-repetition scheduler and shows no "due" dates.

### 3.5 Search

- Scope: whole library, a folder, or the open notebook.
- Indexes: titles, typed text, real PDF text, and recognized handwriting/scans
  (English, on-device, best effort). Results show the notebook, page, a snippet and
  the kind of match; tapping opens the page and highlights the match bounds.
- Index state is visible: "No matches" is distinct from "N pages not yet indexed"
  and "N pages failed to index". Recognition runs in the background, only for
  changed or requested pages, and can be cancelled. Losing or rebuilding the index
  never changes notebook content (Settings → Rebuild search index).

### 3.6 Export, import and backup

- Export a notebook or selected pages as **PDF** (presentation copy: source PDF
  vectors and text preserved, annotations drawn at page coordinates, ink rasterized
  at 2× page points by default), **PNG/JPEG** (one image per page), or a
  **Courseleaf archive** (`.courseleaf`, full editing fidelity). Tape policy per
  export: as shown, cover all, or reveal all. Progress and cancel; errors named.
- Print through the system print panel using the same PDF renderer.
- Import PDF, PNG/JPEG or `.courseleaf` from Files, drag-and-drop or "Open in".
  Destination: new notebook (in the current folder) or insert before/after a chosen
  page of an existing notebook. Files are copied into staging before the external
  access ends; a cancelled or failed import creates nothing. Encrypted, corrupt,
  oversized and unsupported files are reported with a clear message.
- Backup: "Back up library…" writes one validated `.courseleaf` library archive to a
  destination the student chooses (Files, external drive, cloud folder). "Restore
  from backup…" validates the archive completely first, then restores documents as
  copies by default (option: restore only documents missing from the library). A
  failed restore never touches the existing library.

### 3.7 Settings

- Input: Pencil-only drawing / allow finger drawing; left-handed layout (tool
  options and page navigator mirrored).
- Paper defaults: template, page size, cover palette for new notebooks.
- Appearance: system/light/dark; page background dimming in dark mode is off by default.
- Storage: usage by documents, trash, search index and previews; Empty trash; Rebuild
  search index; Clear previews.
- Backup: Back up now, Restore, last backup time (from the last successful,
  validated archive).
- Accessibility: control text size follows Dynamic Type; VoiceOver labels are
  reviewed here as a checklist link, not a switch.
- Support: link to the support page and the privacy policy; app version and build.
- Purchases: "Restore purchases" and the unlock, shown only when a product is
  configured (section 5).

## 4. Problem Page workflow

1. Create a Problem Page from a blank template (new page → Problem Page) or turn an
   existing page into one from the Problem Inspector.
2. Set its title, optional source reference, optional Given/Find text and, if wanted,
   the result region by drawing a rectangle on the page.
3. Write and annotate normally with every editor tool; the metadata stays out of the
   way (a small title chip at the top of the page).
4. Set the status: Unfinished → Check again → Understood, in any order, any time.
5. Add the page or a rectangular region to the course review queue, optionally with
   a prompt ("Why does the sign flip?").
6. Cover the answer with a tape object; tapping tape toggles reveal/hide and records
   a review event. Tape has an explicit export policy.
7. Open the course's review queue, work through items, reveal answers, mark reviewed
   or reopen, and jump straight back to the original page location.
8. All of this metadata lives inside the document package and survives native
   archive export/import, backup/restore and crash recovery.

## 5. Pricing mode

- Default: an optional **non-consumable local unlock** behind `EntitlementStore`
  (StoreKit 2 adapter in `App/Entitlements`). Nothing is gated until a product is
  configured before launch; with no product configured every feature is available
  and no purchase UI is shown.
- If configured: the gated set is decided and written down before submission; core
  data always stays viewable and exportable regardless of entitlement. Transactions
  are verified, pending/cancelled/revoked/offline/restore states are handled, and
  prices come from StoreKit, never hardcoded. StoreKit test configuration is kept
  separate from production products. A hardcoded "unlocked = true" is not an
  implementation.
- No subscriptions, no backend, no accounts at launch.

## 6. Explicit limitations at launch

- **Compositing order is fixed**: page background, then images, then the ink layer,
  then text/shapes/tape. Ink is always above images and below text and shapes.
  Front/back commands reorder objects within their band; ink cannot be moved
  between bands.
- **Presentation PDF export** keeps the source PDF's vector content and text
  (searchable in other viewers) but does **not** carry over PDF links or outlines,
  and annotations are not editable PDF annotations. Highlighter uses multiply-style
  blending as on screen.
- **Ink is rasterized** in every export (PDF, PNG, JPEG) at the chosen scale
  (default 2× page points, 144 dpi). Native archives keep ink as engine data.
- **Handwriting search and conversion** is best-effort on-device OCR (Vision,
  English), subject to the evaluation corpus in `docs/VALIDATION.md` (A15). Results
  carry no precision claim; conversion shows an editable preview and never replaces
  ink. Math is not recognized.
- **Review queue is manual**, not spaced repetition: no scheduling, due dates or
  scores.
- **Migration from other notebook apps is via exported PDFs only**
  (`docs/MIGRATION_FROM_GOODNOTES.md`). Previously flattened handwriting is not
  independently editable; no proprietary format is decoded.
- **No accounts, no sync, no cloud, no AI**, no collaboration, no audio recording, no
  flashcards, no whiteboards or block documents at launch. None of these appear as
  empty or "coming soon" screens.
- **Single ink layer per page**; the format allows more, the UI offers one.
- **Pens** are PencilKit's pen, pencil and marker. They are labelled Pen, Pencil and
  Highlighter, not as fountain/brush simulations.
- **Eraser**: pixel and whole-stroke; no segment eraser, no erase-by-type filters.
- **Shapes** are drawn with a shape tool; rough strokes are not converted to shapes.
- Imported PDFs: embedded scripts are never executed and embedded URLs are never
  followed automatically (only tapped links in reading mode).

## 7. Accessibility and layout commitments

- Portrait, landscape, Split View and Slide Over widths down to roughly 320 pt:
  toolbars collapse to menus, sidebars become sheets, the canvas never scrolls
  horizontally unless zoomed, and ink never moves relative to the page when the
  layout changes.
- Keyboard visible: text editing scrolls the edited box into view; shortcuts listed
  in the shortcut overlay (hold ⌘).
- Left-handed mode mirrors tool options and page navigator to the right edge.
- Dynamic Type for every control label and list (canvas content is page geometry
  and does not scale with text size).
- VoiceOver: every toolbar item, page thumbnail, review item and setting has a label
  and, where relevant, a value and custom actions (e.g. "Mark reviewed", "Delete
  page"). The canvas is an accessibility element describing page number and content
  kinds; drawing itself requires a Pencil or finger.
- Strong contrast: neutral surfaces, one accent, minimum 4.5:1 for text on chrome;
  no colour-only status indicators (save status also has an icon and text).
- Reduce Motion respected for page transitions; no autoplaying animation.
- Permission denials (camera, photos), no Pencil, no network and low disk space each
  leave writing, reading and export usable (A16).

## 8. Data-safety promises visible to the student

- "Saved" is shown only after the manifest rename and directory sync complete
  (target: within 1 s of the last edit; coalesced at most 300 ms after the last edit).
- Every failure keeps the last valid revision readable; the student can retry or
  export a copy.
- Deleted pages and notebooks go to a recoverable trash.
- A backup is reported successful only after its archive validates end to end.
- All data stays on the iPad unless the student exports it (`PRIVACY_POLICY_DRAFT.md`).
