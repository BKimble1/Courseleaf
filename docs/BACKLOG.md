# Backlog (after launch)

Concrete cards for the post-launch expansions in the build prompt (section 12).
Each card lists dependencies, data changes, UI behaviour, acceptance tests,
supported platforms and operating cost. Feature register IDs point back to
`docs/FEATURE_REGISTER.md`. None of these ship as empty menu entries at launch.
Cards are ordered P1→P8 by dependency, not by promise.

## P1 Personal Apple experience

**Covers:** F002, F009 (custom templates/covers), F013, F014 (horizontal
progression), F016, F017, F019, F021, F026 (colour ordering, eyedropper), F072,
F101, F105, F107 (automatic backup), F108.

- **Dependencies:** stable revision storage (`Revision`, immutable assets) shipped
  and device-validated; a Mac target is *not* included; iPhone reading/search needs
  its own layout pass.
- **Data changes:** sync metadata per document (remote revision cursor, pending
  upload queue, conflict copies as new `DocumentID`s with a `conflictOf` field);
  custom outline entries (`Document.outline: [OutlineEntry]`); user templates and
  covers as assets referenced from `PaperTemplate`/`CoverStyle`; toolbar layout and
  palettes in settings; lock flag and keychain-stored secret reference for F108.
  Adding optional fields keeps `formatVersion 1`; a conflict-copy field is optional.
- **UI behaviour:** sync status separate from save status (queued, syncing,
  up-to-date, failed); same-page concurrent edits produce a visible conflict copy,
  never a silent overwrite; iPhone app is read/search only; Zoom Window is a
  magnified strip with auto-advance; widgets show quick note and up to four
  favourites; automatic backup shows the last validated completion, not the last
  attempt; document lock covers previews, search results and exports explicitly.
- **Acceptance tests:** two offline devices editing different pages merge; same
  page yields two copies; iCloud quota exhaustion, account sign-out, delete while
  offline, duplicated delivery, reinstall and schema upgrade each leave local work
  usable; batch folder export restores the hierarchy; lock never leaks page content
  through thumbnails or search snippets.
- **Platforms:** iPad, iPhone (reading), iCloud.
- **Operating cost:** CloudKit within Apple's free developer quota for private
  databases; support load for sync questions; no server code.

## P2 Rich objects and pen behaviour

**Covers:** F022 (fountain/brush), F024, F027, F030, F031, F033, F034, F036, F037,
F039 (align, capture), F043, F045, F046, F049 (grouping), F050, F051 (stroke
recognition), F052–F056, F082.

- **Dependencies:** `PencilKitInkEngine` mask-preserving transforms proven on
  device (A10); `SelectionController` stable; Pencil Pro hardware for F031 testing.
- **Data changes:** `ObjectContent.group`/`groupID`; sticky-note content type with
  collapsed state; element collections as a library-level package of page fragments
  (export/import as `.courseleaf` sub-archive); multiple `InkLayer`s per page with
  visibility and lock; tape pattern/image reference; stroke pattern is a per-stroke
  attribute only if the ink engine can render it without private API (otherwise a
  shape-object fallback).
- **UI behaviour:** eraser filters (highlighter only, etc.) and auto tool return;
  scribble-to-erase and circle-to-select are gestures with a visible undo and an
  opt-out; rulers and alignment guides snap in page points; connectors attach to
  shape anchors and re-route on move; layers are real editor state (active layer,
  visibility, lock) and export visible layers.
- **Acceptance tests:** a gesture evaluation set of legitimate scribbles, equations
  and diagrams where scribble-erase must not remove them; every new object type
  round-trips through archive, undo (one step per user action) and PDF export at
  correct coordinates; layer lock prevents edits; sticky note collapsed/expanded
  export behaviour matches the documented rule.
- **Platforms:** iPad; Pencil Pro features degrade gracefully on older Pencils and
  finger input.
- **Operating cost:** none recurring.

## P3 Lectures and study sets

**Covers:** F074–F080, F083–F086.

- **Dependencies:** durable segmented file writes (Persistence commit protocol
  extended to audio segments); AVFoundation session/route/interruption handling;
  speech capability check on device for F078; P1 optional for reminders on iPhone.
- **Data changes:** `Recording` entity (clip ID, segment files as immutable assets,
  monotonic timeline, pause/interruption map); `NoteEvent` (timestamp on the clip
  timeline → page/stroke or object reference by ID, never by array index); flashcard
  deck and card entities with a documented scheduler state; CSV/TSV import mapping.
- **UI behaviour:** visible recording state, pause/resume, per-clip management and
  export; replay highlights ink as it was written (spotlight/progressive/static);
  moving old ink later does not change its recorded moment; flashcards with a
  documented spaced-repetition schedule and local reminders; transcription only
  where the device supports it, with a useful non-transcribed fallback.
- **Acceptance tests:** audio route change, phone-call interruption, app
  backgrounding and force-quit each leave recoverable clips; timeline stays correct
  across pauses; edits after recording keep event mapping; scheduler behaves across
  time-zone changes; CSV round trip.
- **Platforms:** iPad (recording, replay); iPhone later for review only.
- **Operating cost:** none for on-device; cloud transcription is explicitly out of
  scope for this card.

## P4 Recognition and math

**Covers:** F040, F061, F062, F087–F090.

- **Dependencies:** A15 evaluation corpus and error metrics from launch; licence,
  language and cost review of any specialist handwriting/math SDK or on-device
  model; a deterministic calculator engine for bounded evaluation.
- **Data changes:** typeset equation object (`ObjectContent.equation` with a
  LaTeX-like source string and cached layout); personal dictionary in settings;
  recognition records gain a model/version field for invalidation.
- **UI behaviour:** editable typeset equations first; handwritten math shows the
  interpreted expression before any evaluation; unsupported problems are stated,
  not guessed; reflow and style-preserving correction keep original ink until
  accepted; advanced solving/graphing/tutoring only after their own prototype
  clears quality and licensing gates, with verified calculation separated from any
  generated explanation.
- **Acceptance tests:** published corpus with per-category error rates; calculator
  results checked against a reference for the bounded operation set; spelling
  suggestions never modify ink without acceptance; a wrong interpretation is
  correctable before evaluation.
- **Platforms:** iPad.
- **Operating cost:** SDK licence fees if a third-party engine is chosen; otherwise
  none.

## P5 Optional AI

**Covers:** F091–F095, F102 (AI part).

- **Dependencies:** a backend gateway with server-held provider keys, authenticated
  requests and per-account quotas; an account system (which brings account deletion
  and billing guidance requirements); explicit consent flow before any content
  leaves the device; P4 corpus for grounding quality.
- **Data changes:** none to the document format for questions/summaries; generated
  edits are ordinary objects inserted through `EditCommand` with a provenance field;
  local request log with retention policy; quota state cached locally.
- **UI behaviour:** student selects the notebook, pages or selection sent; recipient
  and purpose are disclosed and permission obtained before sending; answers cite
  pages; outputs are previewed, insertable and undoable; requests are cancellable;
  quota and budget errors are explained; a returned model string is never executed
  as a document operation without validation.
- **Acceptance tests:** malicious instructions embedded in imported notes do not
  change behaviour; idempotent billing on retry; deletion of server-side data on
  request; offline behaviour degrades to local features; per-request size caps.
- **Platforms:** iPad; backend on the owner's chosen host.
- **Operating cost:** provider tokens, hosting, monitoring and support; set a
  service budget cap before enabling; not included in any one-time unlock.

## P6 Other document engines

**Covers:** F096–F099.

- **Dependencies:** P2 object model; a separate renderer per engine (not stretched
  notebook pages).
- **Data changes:** new `DocumentKind.whiteboard` with world coordinates, boards,
  spatial index and finite export regions; `DocumentKind.textDocument` with a block
  tree (headings, lists, quotes, code, tables, media, links); migration commands
  from notebook pages to a board.
- **UI behaviour:** whiteboard minimap, bounded rendering, region export; block
  editor with reorder, slash commands, undo, keyboard selection and input-method
  correctness; neither is faked with a giant text box over a canvas.
- **Acceptance tests:** 10k-object board pans without stalls; finite export matches
  chosen region; block editor keyboard selection and IME composition tests; both
  kinds round-trip through the archive.
- **Platforms:** iPad first.
- **Operating cost:** none recurring.

## P7 Collaboration and other platforms

**Covers:** F100, F106.

- **Dependencies:** an interoperable versioned model (P1 revisions), authenticated
  document membership, a tested merge/CRDT strategy or licensed solution chosen
  after a prototype; server-enforced permissions.
- **Data changes:** membership and role records; operation log with ordering;
  presence is ephemeral (not stored in the package).
- **UI behaviour:** view/comment/edit roles, invite/revoke (server enforced; the UI
  explains that already downloaded copies cannot be recalled), presence, offline
  operations that reconcile on reconnect; public sharing adds abuse reporting.
- **Acceptance tests:** two independent clients editing concurrently converge;
  revoke is enforced on the server; offline queues replay in order; Android/
  Windows/web clients each have a renderer capability matrix with rendering
  fixture comparisons.
- **Platforms:** iPad plus each additional client as its own project.
- **Operating cost:** servers, storage, abuse handling and support at the scale of
  sharing offered; requires accounts (see P5 obligations).

## P8 Integrations and ecosystem

**Covers:** F047, F064, F067, F073, F102 (calendar part), F103, F104.

- **Dependencies:** scoped authorization for each provider under its terms; P1 sync
  status model for cloud writeback; a conversion service or on-device converter
  for Office import.
- **Data changes:** provider tokens in the keychain; import provenance on assets;
  calendar-linked note references (event ID, read-only display vs. editing clearly
  separated).
- **UI behaviour:** one-way backup vs. sync is labelled; calendar display is
  read-only unless event editing is separately implemented; email ingestion and
  external assistant connectors create documents through the normal import path
  with validation; GIF search is online and marked as such.
- **Acceptance tests:** token revocation, provider errors and offline states;
  Office conversion fidelity fixtures with documented layout limits; imported
  content passes the same archive/PDF validation as local imports.
- **Platforms:** iPad.
- **Operating cost:** provider API fees where applicable; support for provider
  changes.
- **Separately approved products (not cards):** creator marketplace (F109), school
  management, SSO, domain controls, billing administration and enterprise
  governance (F110) each need their own business decision, legal review and
  operational plan before any card is written.

## Historical and uncertain items

- **Word Complete (F112)** was discontinued by the benchmark product in March 2025.
  It is retired and not a requirement or a parity target.
- **Workspaces (F111)** was advertised as forthcoming on the benchmark's homepage
  when researched. It is not listed as a confirmed shipped capability and has no
  Courseleaf card.
- **Marketing comparisons:** before any comparative claim about competitor
  features, plan entitlements or prices, recheck the current source pages; the
  research snapshot is dated 2026-09-11 and contains documented inconsistencies
  (free allowances, sync tiers, experimental rollouts).
