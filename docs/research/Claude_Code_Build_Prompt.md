# Claude Code master build prompt

Copy the master prompt below into Claude Code in the intended app repository. Keep `Goodnotes_Research_and_App_Plan.md` in that workspace. Use the strongest suitable coding/reasoning setting actually available in your installed Claude environment. This prompt does not depend on a product or command named Ultra Code.

## Master prompt

You are the lead native iPad engineer responsible for creating an original, dependable note-taking app that I can use for college and eventually publish on the Apple App Store. Build the software, not just a prototype interface or a proposal. Read this entire prompt and `Goodnotes_Research_and_App_Plan.md` before making architectural changes.

Use **Courseleaf** as an internal development codename. It is not a cleared public product name. Do not imply affiliation with Goodnotes or use its name, icon, screenshots, covers, fonts, proprietary code, or marketplace content in the app. Implement familiar note-taking capabilities through original code and an original interface. Follow existing repository instructions and preserve unrelated work.

My main device is an iPad with Apple Pencil. I want the useful daily handwriting/PDF workflow found in a mature notebook app, plus an original student-oriented Problem Page and review workflow. The research file contains the wider Goodnotes benchmark. Preserve the complete benchmark in the backlog, but finish the launch product before adding additional engines or services.

### 1 Work style and scope

1. Inspect the repository, branch, uncommitted changes, project instructions, build scripts, available SDKs, and current tests. If no project exists, create a native Swift app project in this workspace with reproducible configuration and a runnable scheme.
2. Establish the available native build environment. Record `xcodebuild -version`, available SDKs, signing capabilities, and simulator/device destinations when those tools exist. On Windows/Linux, implement what can be verified there, use an existing authorized Mac runner if available, and identify precisely what still requires a Mac. Do not claim a native build passed from portable tests.
3. Briefly state the implementation plan, then start work. Make routine reversible engineering decisions without asking me to approve every class, screen, or dependency. Ask only when a missing decision blocks meaningful progress or an action needs external authorization.
4. Treat G0 through G6 below as the current implementation scope. Preserve later work as concrete backlog cards. Do not silently turn a failed launch requirement into a future feature or mark a deferred feature complete.
5. Keep working through the current scope as capacity allows. Do not stop after scaffolding, mock screens, a README, or a passing trivial test. If context or execution limits interrupt the work, save a precise handoff and a buildable checkpoint where possible.
6. Do not create paid services, purchase SDKs, upload private notes, change unrelated repositories, or submit an App Store release without authorization. Finish source, tests, assets, and draft release material before requesting the remaining account-dependent step.
7. Keep provider credentials out of the app and repository. Do not bypass tool permissions, use private Apple APIs, weaken tests to get a green result, or invent API capabilities.
8. Prefer a small number of maintained dependencies. Verify actual licenses and supported platforms before adopting one. Do not assume a package is free for commercial use because its demo is public.
9. Record honest outcomes: implemented, unit-tested, simulator-tested, device-tested, or blocked. These statuses are different.

### 2 Product brief

Create a fast, native, offline-capable notebook for college students who annotate slides, work handwritten problems, and revisit material before exams. The core experience must be usable without an app account, an internet connection, or an AI subscription.

The original differentiating workflow is **Problem Pages**:

- A page has a problem title, optional source reference, optional Given and Find labels, free working space, an optional result region, and a review status.
- The student defines these fields. Do not require automatic equation recognition or AI to use them.
- The student can send a page or rectangular region to a course-level review queue, add an optional question, hide/reveal an answer, mark it reviewed, and return directly to the original page.
- Keep this structure out of the way during normal writing. Ordinary blank notebooks remain first-class.

Use an original design with a large writing surface, neutral colors, strong contrast, readable labels, compact tools, and original covers. Design the Library, Notebook Editor, Problem Inspector, Review Queue, Search, Export/Backup, and Settings screens. Support portrait, landscape, keyboard input, split widths, and left-handed use. Avoid introducing social feeds, a marketplace, or AI chat as the main screen.

### 3 Technical decisions

Default to Swift and SwiftUI for the shell with UIKit integration for the editor; PencilKit behind an app-owned InkEngine adapter; PDFKit/Core Graphics for PDF work; a versioned local document-package format; and a rebuildable SQLite catalog/search index.

Choose the deployment target after checking the actual current SDK and framework requirements. Prefer iPadOS 18 or later as a provisional baseline when compatible with the selected APIs and audience, and document the final choice. Do not raise the minimum just to avoid an implementation problem without explaining the tradeoff. Compile with an App Store-accepted SDK at release time.

Use public PencilKit APIs for drawing data and transforms. Do not assume its built-in lasso can provide a complete mixed-object editor. Do not assume Scribble exposes Goodnotes-quality handwriting recognition, or that a tool picker provides custom ink rendering automatically.

Document content is authoritative in managed document packages. SQLite stores a rebuildable catalog and derived search data; it is not a conflicting second copy of the document. Use stable UUIDs, schema versions, immutable assets, per-page revisions, and an atomic manifest update. Store original imported PDFs and images without destructive modification.

Suggested modules, adapted if the repository already has a sound structure:

- AppShell and Library
- DocumentCore and Persistence
- InkEngine and CanvasObjects
- PDFImportExport and FileInterchange
- SearchRecognition
- ProblemPages and Review
- Settings and optional Entitlements
- Tests, Fixtures, and ReleaseDocumentation

Keep business/document logic independently testable. Avoid a single giant SwiftUI view or app-wide mutable singleton. Create only abstractions with a concrete current use or a specified later compatibility need.

### 4 Persistent project instructions

Create or carefully update a concise `CLAUDE.md` containing build commands, architecture constraints, data-safety rules, and verification expectations. Put detailed material in separate documents:

- `docs/PRODUCT_SPEC.md`: the app's launch behavior and explicit limitations.
- `docs/FEATURE_REGISTER.md`: all F001 through F112 from the research file, mapped to milestones and statuses, with implementation/test references.
- `docs/ARCHITECTURE.md`: storage, coordinates, rendering, ownership, threading, and rationale.
- `docs/FORMAT.md`: original native archive schema and version/migration rules.
- `docs/BUILD_AND_TEST.md`: actual commands and environments.
- `docs/VALIDATION.md`: results with source commit, device/OS, fixtures, metrics, and unresolved failures.
- `docs/RELEASE_CHECKLIST.md`: remaining release steps with clear owners.
- `docs/NEXT_SESSION.md`: concise resume state, current branch/commit, active gate, commands, blockers, next actions.

Do not copy the entire research report into `CLAUDE.md`. Read only the relevant detailed sections when working on a milestone. Keep the feature register accurate as implementation progresses.

### 5 G0 Feasibility and environment

Build and run a small native harness before a large UI implementation:

1. A blank page with Pencil/finger drawing, pen/pencil/highlighter, and erasing.
2. A real PDF page with an interactive ink overlay.
3. Fixtures with rotated pages and nonzero CropBox origins.
4. One text box, image, shape, and mixed-object lasso experiment.
5. Save drawing and object data, terminate/relaunch, and restore.
6. Export the annotated page and inspect it independently.
7. A dense drawing fixture and a long PDF fixture.

Confirm coordinate transforms, mask-preserving stroke manipulation, tool behavior, undo integration, overlay lifecycle, and public API availability. Record what needs app-owned selection or rendering. Try compatible physical iPad/Pencil testing when available; otherwise keep that evidence gate explicitly open while doing useful implementation work.

Use the result to choose the exact editor approach. If a key assumption fails, revise the architecture and record the impact before scaling it across the app. Do not substitute a screenshot canvas that cannot edit or persist real content.

### 6 G1 Library and reliable storage

Implement:

- Nested courses/folders and notebooks, list/grid views, recent/favorite access, rename/move/duplicate/delete.
- Original covers and blank, lined, grid, dotted, Cornell, and engineering paper templates. Template spacing should use page units, not screen pixels.
- Quick capture with sensible defaults and an obvious way to file the note later.
- Stable page IDs; insert, duplicate, reorder, move/copy between notebooks, delete, restore, and bookmarks.
- A last-known-good document revision and recoverable trash.
- Versioned native archive export/import and full manual backup/restore.

Write content assets to temporary locations, finalize immutable files, verify references, then atomically commit the manifest. Serialize writers per document. Do not rewrite every page or the full PDF on each Pencil event. Coalesce saves briefly and target durable completion within one second after normal completed edits; measure this. Flush when leaving the page/editor. UI save status must reflect actual durable success.

Handle write failures, disk exhaustion, interrupted commits, invalid manifests, missing files, unsupported schemas, and duplicate imports. Failed restore/import must not replace a working library. Reject archive path traversal, excessive expansion, and invalid sizes/checksums before trusting imported data.

Make the catalog recoverable from document packages. Cache loss may reduce search speed but must not lose notes. Protect needed assets from garbage collection while referenced by history, trash, active exports, or future sync queues.

### 7 G2 Complete everyday editor

Implement these real interactions:

1. Pen, pencil, and highlighter with width/color presets. Use accurate names for actual ink behavior; do not label an ordinary system pen as a fully custom fountain simulation.
2. Pencil-only drawing preference, optional finger drawing, useful palm rejection, and reliable pan/zoom gesture arbitration.
3. Pixel/partial and whole-stroke erasing through supported APIs. Preserve source PDFs, images, and typed objects unless explicitly selected and deleted.
4. Undo/redo for strokes, erasing, object transforms, text editing, page operations where appropriate, and Problem Page edits. Group a single user operation into one sensible undo unit.
5. Freehand and rectangular lasso for supported ink and objects; selection-type filters; move, resize, rotate, copy, paste, duplicate, delete, and recolor where applicable.
6. Text boxes with practical font size, weight, alignment, and color controls; image insertion, crop/resize/rotation; original basic lines, arrows, rectangles, and ellipses.
7. Object locking and front/back placement. Unsupported mixed-selection actions must be hidden or explained rather than silently affecting only some objects.
8. Page thumbnails, bookmarks, existing PDF outline navigation, reading mode, and state restoration.
9. A clear export/tape visibility behavior and contextual controls that remain accessible at narrow widths.

Use one documented page coordinate system and consistent transforms for editing, selection, recognition boxes, and export. Make cropped/rotated PDFs explicit test cases. Preserve stroke masks: partially erased ink must never reappear after recoloring, moving, reopening, or exporting.

Virtualize heavy canvases. Maintain only visible/nearby active pages with bounded thumbnail/background caches. Do not allocate a PKCanvasView for every page in a 300-page document. No OCR, AI request, full-file serialization, or heavy export work should run synchronously in the drawing event path.

### 8 G3 Import export and migration

Implement PDF, JPEG/PNG, and original native-archive import through Files and supported share/drag flows. Support creating a notebook or inserting before/after a chosen page. Copy security-scoped external files into managed storage before releasing access. Add a document scanner with a graceful permission-denied path.

Preserve original PDF bytes, page dimensions, existing visible content, and supported links/outlines. Handle encrypted, corrupt, huge, mixed-size, rotated, cropped, and image-only PDFs with progress/cancel and clear errors. Do not execute embedded PDF scripts or follow embedded URLs automatically.

Provide:

- A dependable presentation PDF for an entire notebook or selected pages.
- Image export for supported selections/pages.
- A native archive that restores editable ink, objects, page metadata, Problem Pages, and review items.
- Manual full-library backup and validated restore.
- Printing through a supported system flow.

For PDF export, draw original pages and application annotations at correct coordinates. Test highlighter blending, clipping, object order, fonts, tape visibility, image transparency, and page selection. Keep source text searchable when advertised. Do not market a fully rasterized PDF as vector/search-preserving export.

If offering editable PDF annotations, define exactly which types are interoperable and prove round trips in another viewer. Native archives remain the editing-fidelity contract. Do not claim all Goodnotes features or recordings survive ordinary PDF export.

Goodnotes migration is via user-exported PDFs. Display that existing flattened handwriting is not independently editable. Retain source files and tell users to keep their original Goodnotes backups. Do not reverse engineer `.goodnotes` as a launch dependency or claim lossless proprietary migration.

### 9 G4 Search Problem Pages and review

Implement global and within-notebook search for titles, typed content, actual PDF text, and successfully recognized content. Link every search record to a page revision and useful bounds. Navigate to results and visibly distinguish no matches from not-yet-indexed content.

Add an on-device recognition adapter and evaluate English handwriting plus scanned imported pages. Store recognized text as derived data. Keep recognition off the drawing path, queue only changed/requested pages, allow cancellation, and report errors without damaging documents.

Create a repeatable evaluation corpus with printed/scanned text, neat handwriting, cursive, small writing, mixed equations, and low-quality images. Report text error and search success. Do not claim math recognition from plain OCR. If recognition is weak, retain original ink and offer an editable conversion preview rather than destructive replacement or fabricated confidence.

Implement the complete original student workflow:

1. Create a Problem Page from a blank template or existing page.
2. Set its title, source reference, optional Given/Find text, and result region.
3. Write and annotate normally.
4. Mark a page/region as unfinished, check again, or understood.
5. Add a page/region to the review queue with an optional prompt.
6. Cover/reveal an answer using a simple tape/occlusion object.
7. Review material in the course queue and jump to the original location.
8. Preserve this metadata through native export/import and recovery.

This launch queue is a manual/contextual review tool. Do not call it a validated adaptive spaced-repetition algorithm. The richer card scheduler is a later milestone.

### 10 G5 Reliability and user validation

Implement and run meaningful tests for persistence transactions, interrupted writes, invalid archives, page identity, coordinate transforms, partially erased ink, mixed selection/undo, export rendering, indexing invalidation, and review metadata. Use deterministic original fixtures. Avoid tests that merely reproduce internal code decisions without checking externally meaningful behavior.

Use the research file's A01 through A20 acceptance table. Initial performance targets are:

- Comfortable 60 Hz-class navigation/drawing on the chosen baseline physical iPad, without repeated application-induced stalls above 100 ms in normal use.
- A 10,000-stroke page remains usable for writing and panning.
- A 300-page mixed PDF opens without a live canvas per page or uncontrolled memory growth.
- Completed normal edits reach a durable save within the measured one-second target.
- Geometric PDF export fixtures align within one PDF point.

These targets require measurements. Do not describe simulator timing or a screen recording as an end-to-end Pencil latency benchmark. Record baseline hardware, OS, fixture, conditions, and measurement method. If a target is unrealistic on supported hardware, explain and agree a revised product limit rather than manufacturing a result.

Exercise portrait/landscape, narrow split widths, keyboard visible, Dynamic Type in controls, VoiceOver labels/actions, permission denials, no network, limited disk space, and no Pencil. Screen changes must not move ink relative to the document. Use an actual iPad for long writing and exporting sessions before release readiness is claimed.

Run several real lecture/assignment workflows as beta validation. Preserve any data-loss reproduction and fix the root cause. Passing many unit tests is not a substitute for this gate.

### 11 G6 Release preparation

Prepare an App Store-quality build with an original icon/identity, onboarding, support path, privacy-policy draft reflecting the real implementation, accurate feature descriptions, and screenshots from the implemented app. Do not claim unimplemented sync, AI, encryption, or migration fidelity.

Default to an optional non-consumable local-feature unlock behind an entitlement abstraction, configurable before launch. Core data stays viewable and exportable after entitlement changes. Implement StoreKit 2 only if this launch pricing mode is retained; do not introduce a backend subscription system for local notebooks.

For purchases, verify transaction signatures/results, pending and canceled flows, restore, revocation, offline behavior, and localized product display. Keep StoreKit test configuration separate from production products. A hardcoded `isPro = true` is not an implementation.

Keep app accounts and cloud AI out of launch. If accounts are later added, provide account/data deletion with accurate billing guidance. If personal content is sent to third-party AI later, disclose the recipient and purpose and obtain permission before sending. Never include provider API keys in the shipped binary.

Check current Apple release requirements, app privacy answers, required-reason API/privacy manifest applicability, SDK licenses, bundle/signing settings, and device support. Use real review notes and fully functioning URLs before submission. Do not invent my team ID, support domain, signing certificate, or App Store Connect credentials.

Prepare the reproducible archive workflow and exact remaining signing/submission steps. If account access is missing, complete all other work and identify the specific external blocker. No public submission is authorized merely by this build prompt.

### 12 Full feature roadmap after launch

Preserve the full F001-F112 register, including limitations and retired items. For each expansion below, create a concrete card with dependencies, data changes, UI behavior, acceptance tests, supported platforms, and operating cost. Do not build fake menu entries for these cards in launch.

**P1 Personal Apple experience.** Implement iCloud sync, iPhone reading/search, richer page/library organization, named custom outlines, more palettes, customized toolbar, Zoom Window, widgets, multiwindow, and external presentation. Sync depends on stable revision storage. Concurrent same-page edits must preserve both variants as a visible conflict until true merging is proven. Test two offline devices, quota exhaustion, account changes, deletion, retries, and schema upgrades.

**P2 Rich objects and pen behavior.** Add reusable element collections, collection import/export, collapsible sticky notes, user layers, eraser filters, automatic tool return, scribble erase, circle select, dashed/dotted strokes, rulers, alignment guides, connectors, and Pencil Pro enhancements. Preserve mask-aware stroke semantics and undo. Layer/object locking must be real editor behavior. Build a gesture evaluation set that includes legitimate scribbles, equations, and diagrams so recognition does not erase normal work.

**P3 Lectures and study sets.** Add durable segmented audio capture, timestamped note events, replay, clip management/export, optional background capture, flashcards, a documented spaced-repetition scheduler, CSV/TSV import/export, and review reminders. Validate audio routing/interruption, pause/resume, clip recovery, note edits after recording, and time-zone changes. Timestamp recording events against a monotonic clip timeline. Do not assume stroke array positions remain stable through erasing.

**P4 Recognition and math.** Evaluate specialist SDKs or on-device models for handwriting spelling, personal dictionary, reflow, style-preserving correction, and handwritten math. Begin with editable typeset equations and a bounded deterministic calculator. Add advanced solving, graphing, and tutoring only after language/notation tests, licensing, and cost review. Show the interpreted expression, handle unsupported problems explicitly, and separate verified calculation from generated explanation.

**P5 Optional AI.** Implement a backend adapter for notebook-grounded questions, summaries, quizzes, and flashcards; later add generated diagrams, images, and previewed document edits. Include authenticated usage quotas, service budget caps, request limits, server-held keys, page citations, cancellation, idempotent billing/retries, and deletion/retention behavior. Test malicious instructions embedded in imported notes. A returned model string is not automatically a safe document operation.

**P6 Other document engines.** Implement a multi-board whiteboard with world coordinates, spatial indexing, minimap, bounded rendering, content-to-board migration, and finite-region export. Separately implement a rich block editor with headings, lists, tables, code, images/media, block reordering, undo, and export. Do not fake either by stretching notebook pages or placing a giant text box over a canvas. Validate keyboard selection and input-method behavior for the block editor.

**P7 Collaboration and other platforms.** Define an interoperable versioned model, authenticated document membership, view/comment/edit roles, invite/revoke, presence, offline operations, ordering, and conflict resolution. Revoke must be enforced by the server, not just a hidden client button; explain that previously downloaded copies cannot be recalled. Test at least two independent clients editing concurrently. Choose a tested merge/CRDT strategy or a licensed solution after a prototype. Android/Windows/web need their own renderer and capability matrix. Public sharing also needs abuse reporting and operational support appropriate to its scope.

**P8 Integrations and ecosystem.** Add optional calendar-linked notes/planners, cloud-storage import/writeback, email ingestion, external assistant connectors, GIF search, and richer format conversion only with scoped authorization and provider terms. Distinguish one-way backup from sync and read-only calendar display from event editing. A creator marketplace, school management, SSO, domain controls, billing administration, and enterprise governance remain separately approved products.

**Historical and uncertain items.** Keep retired Word Complete out of current requirements. Do not list announced Workspaces as a confirmed implemented Goodnotes capability. Recheck current source pages before making marketing comparisons or asserting exact competitor plan entitlements.

### 13 Required evidence after each gate

Provide a concise report containing:

- What a person can now do in the app.
- The exact changed areas and source commit when a commit was made.
- Actual build/test commands and results.
- Screenshots or export fixtures that demonstrate relevant behavior.
- Measured performance where required, with device/environment.
- Unresolved failures and unrun device/account gates.
- The next gate and the few decisions that truly require me.

Update `docs/NEXT_SESSION.md` before context exhaustion. Include any uncommitted work and do not discard it. Never describe an entire product as done because a single milestone compiled.

Start now by inspecting the workspace, extracting F001-F112 into the feature register, establishing the native build path, and implementing G0. Then continue through launch gates in dependency order, maintaining evidence and a safe handoff.

## Continuation prompt

Continue the original Courseleaf build. Read `CLAUDE.md`, `docs/NEXT_SESSION.md`, `docs/FEATURE_REGISTER.md`, and the relevant sections of `docs/PRODUCT_SPEC.md` and `docs/ARCHITECTURE.md`. Inspect the current branch and uncommitted changes before editing. Confirm the last genuinely verified gate and resume the next incomplete launch requirement. Preserve previous work and do not restart the project. Implement, run the meaningful verification available, update the feature register and handoff, and clearly distinguish completed work from untested or blocked work. Keep working through the authorized scope; ask only for a concrete blocking external decision.

## Release audit prompt

Audit the current Courseleaf build against G0-G6 and A01-A20 in the original specification. Inspect source, tests, fixtures, exports, and build evidence; do not rely on previous completion summaries. Look especially for data loss, false save success, mask/rotation errors, archive recovery failure, mixed-selection undo bugs, inaccurate OCR claims, unfinished entitlements, and privacy disclosures that differ from the build. Reproduce and fix concrete issues within the existing scope, rerun the affected checks, and prepare a concise release-readiness report. Separate software defects from signing/account/device gates. Do not submit a public release without my explicit authorization.
