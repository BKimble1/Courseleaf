# Goodnotes Feature Research and Original iPad App Plan

## Product assessment

Build an original iPad notebook app around dependable handwriting, PDF coursework, searchable notes, and fast study preparation. Goodnotes is a useful functional benchmark, but its current scope is much larger than a digital notebook. An initial release should deliver a complete daily note-taking workflow, with a defined path toward the remaining capabilities.

The research snapshot is September 11, 2026. The US App Store listing inspected shows Goodnotes 7.1.19, dated September 4. It includes notebooks, audio, study tools, whiteboards, typed documents, and AI. Its recent release notes also mention quick diagram creation and connector improvements.[^1]

This is a comprehensive public-documentation inventory, not a hands-on audit of every account, language, device, enterprise configuration, or experimental rollout. The catalog groups individual controls into 112 feature records. Availability is qualified where the documentation provides limits. Public documentation cannot establish Goodnotes' private architecture, recognition models, internal file specification, or actual performance on a particular iPad.

The recommended product uses the internal codename **Courseleaf**. This is a development placeholder, not a cleared App Store name. The initial audience is college students who combine handwritten work with lecture slides and worksheets. The default launch target is iPad; iPhone, Mac, and other platforms have their own later milestones.

The central recommendation is to finish and test the document engine before adding cloud services or AI. A beautiful editor that loses a page, shifts handwriting on a PDF, or exports an incomplete assignment is not ready for daily use. A realistic first release can be considerably smaller than Goodnotes while still feeling complete.

## Current product and commercial scope

Goodnotes has several distinct content experiences. A notebook combines fixed pages, handwriting, text boxes, and imported documents. A whiteboard contains expandable boards. A Text Document is a continuous block editor rather than a drawing canvas. Study Sets provide a separate flashcard workflow. These formats should not be treated as interchangeable implementations.[^24][^29][^30]

The prices below are public US reference prices, not quotes for every storefront. Goodnotes' own pages contain inconsistencies about some plan limits. The narrow, feature-specific documentation is the better basis for understanding a feature, while the live account paywall remains the way to verify an individual purchase.

| Plan | Public reference | Meaning for this project |
|---|---|---|
| Free | $0; limited documents, imports, storage, and recording | A usable free tier is an established part of this category. |
| Essential | $11.99 per year | Low-cost solo note-taking is already competitively priced. |
| Pro | $35.99 per year | Advanced collaboration and cloud features create a separate tier. |
| Special Edition | One-time Apple purchase; verify the in-app price | Perpetual local functionality is a relevant pricing model. |
| AI Pass | Approximately $10 per month; website displays $9.99 | AI has a recurring usage cost beyond notebook functionality. |
| Teams and Enterprise | Website lists Teams at $120 per seat yearly; Enterprise is custom | Organizational administration is outside a solo consumer launch. |

The pricing page supports the annual prices, AI add-on price, and organizational tiers.[^2] The plan comparison explains Special Edition, legacy purchases, trials, and plan-specific entitlements.[^3]

### Documentation conflicts and retired features

| Topic | Evidence | Treatment in this plan |
|---|---|---|
| Essential cross-platform sync | The plan comparison includes it, but the dedicated Goodnotes Cloud guide explicitly excludes Essential. | Treat full-library Goodnotes Cloud sync as Pro-only according to the dedicated guide; flag the contradiction. |
| Free document allowance | Different pages describe three total files versus three of each content type. | Do not claim a precise universal free allowance. Check the current in-app account limit. |
| Collaboration permissions | An older sharing article describes public links with broad access; current plans distinguish private links and real-time collaboration. | Keep legacy sharing behavior separate from current Pro collaboration. |
| Layers | Experimental, gradually released on iPad and Mac for Pro; not included in the Pro trial. | Include in the inventory with rollout and platform limits. |
| Calendar planner | Experimental Apple/Pro workflow with US English templates and primary Google Calendar only. | Separate it from general calendar connection. |
| Word Complete | Goodnotes says it was discontinued March 31, 2025. | Record as retired, not current parity work. |
| Workspaces | Homepage labels Workspaces as coming in 2026. | Treat as announced until delivery is independently confirmed. |

The dedicated cloud, layers, planner, and retirement articles establish these distinctions.[^31][^10][^35][^37] Workspaces remains labeled as forthcoming on the inspected homepage.[^46]

## Feature inventory

The target column describes the proposed app's roadmap, not Goodnotes' release status. **Launch** means the initial App Store release; **Personal** means the next expansion of the Apple note-taking experience; **Advanced** means recognition, math, or AI work; **Platform** means another content engine or network service; **Separate** means an independent business initiative; **Retired** means historical context only. All rows are functional benchmarks rather than instructions to copy Goodnotes' design.

### Library and document organization

Goodnotes documents folder and page operations, favorites, object controls, and deletion recovery in its organization guides. Templates and covers are managed independently of the page's annotations.[^18][^19]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F001 | Folders | Organize notebooks and other documents in nested folders. | Launch |
| F002 | Folder appearance | Change folder colors and icons. | Personal |
| F003 | Library views | Browse documents in grid or list form. | Launch |
| F004 | Item management | Rename, move, and delete documents and folders. | Launch |
| F005 | Favorites | Mark documents, folders, and pages for quick access. | Launch |
| F006 | Trash | Recover deleted documents, folders, and pages; empty trash. | Launch |
| F007 | Page order | Reorder, copy, move, and combine pages or notebooks. | Launch |
| F008 | Covers | Choose, replace, or omit a notebook cover. | Launch |
| F009 | Templates | Import and manage custom page templates and covers. | Launch |
| F010 | Paper choices | Use blank, ruled, grid, Cornell, and planner-style paper. | Launch |

### Navigation and the writing environment

Goodnotes exposes document search, a navigation sidebar, reading mode, scrolling choices, and multiple iPad windows. Its toolbar can be reordered and simplified, but the documented customization has fixed items and does not support multiple saved presets.[^6][^7]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F011 | Page navigation | Use thumbnails, bookmarks, and document outlines. | Launch |
| F012 | Imported outlines | Navigate a PDF's existing table of contents. | Launch |
| F013 | Custom outlines | Create named navigation entries within documents. | Personal |
| F014 | Canvas navigation | Zoom and scroll; choose horizontal or vertical progression. | Launch |
| F015 | Reading mode | Navigate and follow links without making ordinary edits. | Launch |
| F016 | Multiple windows | Open Goodnotes documents in separate iPad windows. | Personal |
| F017 | Toolbar layout | Hide/reorder supported tools and dock floating menus. | Personal |
| F018 | Keyboard controls | Use documented shortcuts for common actions. | Launch |

The Zoom Window magnifies a writing region and can advance automatically across a line and then to the next line. It is documented as iOS-only.[^48]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F019 | Zoom Window | Magnified writing region with resizing and auto-advance settings. | Personal |
| F020 | Quick capture | Create a QuickNote without first organizing a complete notebook. | Launch |
| F021 | Home widgets | QuickNote and recently modified favorites on Apple devices. | Personal |

The widgets are documented for iPhone, iPad, and Mac, with up to four favorite items.[^20]

### Pens and input

The Pen tool has fountain, ball, and brush styles, stroke patterns, thickness and color controls, and supported pressure/stabilization settings. Pencil is a separate graphite-style tool.[^4]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F022 | Pen styles | Fountain, ball, and brush ink behavior. | Launch subset |
| F023 | Pencil | Graphite-style sketching and writing. | Launch |
| F024 | Stroke patterns | Solid, dashed, and dotted lines. | Personal |
| F025 | Thickness presets | Save and adjust stroke widths. | Launch |
| F026 | Color controls | Presets, custom colors, ordering, and eyedropper support. | Launch subset |
| F027 | Ink response | Pressure response, tip controls, and stabilization where supported. | Personal |
| F028 | Highlighter | Translucent annotation with selectable color and width. | Launch |
| F029 | Stylus and touch | Stylus or finger drawing and palm-rejection configuration. | Launch |
| F030 | Hover preview | Preview supported Pencil strokes before contact. | Personal |
| F031 | Pencil Pro | Squeeze palette and fountain-pen response to barrel rotation. | Personal |

Pencil Pro features require compatible hardware. They should enhance an editor that also works with older Pencils and finger input.[^47]

### Erasing and selection

The eraser supports precision, segment, and whole-stroke behavior, content-type filters, page clearing, and automatic return to the previous tool. It does not erase imported PDF text or arbitrary images.[^5] Selection and handwriting editing are separate operations.[^8][^9]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F032 | Eraser variants | Erase portions, segments, or complete strokes. | Launch subset |
| F033 | Erase filters | Remove selected stroke types while preserving others. | Personal |
| F034 | Tool return | Automatically leave the eraser after using it. | Personal |
| F035 | Clear page | Remove page content without deleting the page itself. | Launch |
| F036 | Scribble to erase | Recognize a pen gesture that removes handwriting. | Personal |
| F037 | Circle to select | Use a pen gesture to invoke selection. | Personal |
| F038 | Lasso filters | Select supported content types and exclude others. | Launch |
| F039 | Object editing | Transform, recolor, copy, delete, align, or capture selected content. | Launch |
| F040 | Handwriting reflow | Change line width, word selection, alignment, and straightening. | Advanced |
| F041 | Undo and redo | Buttons and gestures undo supported editing operations. | Launch |

### Text and visual objects

Goodnotes combines typed boxes and media with ink in notebooks. Elements can contain reusable combinations of handwriting, text, images, and shapes. Collections can be edited or shared; GIPHY adds online GIF discovery and on-page animation.[^49]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F042 | Text boxes | Place and format typed content on notebook pages. | Launch |
| F043 | Full-page typing | Type continuously in a notebook's supported typing mode. | Personal |
| F044 | Images and camera | Insert photos, capture images, and manipulate placed content. | Launch |
| F045 | Elements | Save reusable selections in collections and insert them again. | Personal |
| F046 | Collection exchange | Import/export and manage collections of reusable objects. | Personal |
| F047 | Animated GIFs | Search GIPHY and insert animated content in supported canvases. | Platform |
| F048 | Object locking | Prevent supported objects from moving accidentally. | Launch |
| F049 | Object stacking | Adjust front/back placement and grouped content. | Launch |
| F050 | Sticky notes | Movable, formatted notes that collapse and contain other content. | Personal |

Sticky notes have their own editing and export behavior: expanded notes export their contents, while collapsed notes appear as icons.[^50]

### Geometry and layer controls

The Shape tool supports recognition, draw-and-hold, rounded shapes, text, and connectors. Certain diagram controls depend on a phased rollout.[^11] Layers are distinct from object stacking: the current experiment offers up to five layers with active-layer editing and visibility controls, but no layer locking, reordering, or moving existing content between layers.[^10]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F051 | Shape recognition | Convert rough strokes into regular geometry. | Launch subset |
| F052 | Draw and hold | Hold a completed stroke to straighten or regularize it. | Personal |
| F053 | Ruler | Guide straight-line drawing. | Personal |
| F054 | Connectors | Connect diagram nodes with supported routing/styles. | Personal |
| F055 | Quick diagramming | Add connected nodes from shape edge controls. | Personal |
| F056 | Layers | Separate editable content and export visible layers. | Personal |

### Search and recognition

Goodnotes searches handwriting, typed content, document/folder titles, outlines, PDFs with a text layer, and documents scanned inside Goodnotes. Its dedicated search guide states that imported PDFs do not receive subsequent OCR. Handwriting recognition languages vary by platform.[^16][^17]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F057 | Library search | Find content across notebooks and navigate to matching locations. | Launch |
| F058 | Document search | Search within one open document. | Launch |
| F059 | Handwriting conversion | Convert recognized handwriting to typed text. | Launch best effort |
| F060 | Recognition languages | Select supported document recognition languages. | Launch English |
| F061 | Handwriting spelling | Spelling suggestions, style-preserving correction, and a personal dictionary. | Advanced |
| F062 | Handwriting appearance | Reflow/restyling and beautification are reflected in current guides/releases. | Advanced |

Handwriting spellcheck has its own product documentation. It should not be confused with ordinary keyboard spellcheck.[^51] Beautification appears in the current release notes; its exact quality and account availability were not measured.[^1]

### Import and export

Apple versions accept PDFs, JPEG/PNG images, Goodnotes files/backups, study CSV/TSV, and Word/PowerPoint through conversion. Conversion may alter Office layout. Android, Windows, and web have narrower format/size limits. Files can be imported as new documents or inserted into an existing notebook.[^13]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F063 | PDF and image import | Import standalone files or add pages to a notebook. | Launch |
| F064 | Office import | Convert Word/PowerPoint into annotatable pages on iOS/iPadOS. | Platform |
| F065 | Native import | Open Goodnotes documents and supported backups. | Own format only |
| F066 | Share and drag import | Receive content from other apps, Files, or drag and drop. | Launch |
| F067 | Email import | Receive PDFs through a personal Goodnotes email address. | Platform |
| F068 | Scan documents | Capture physical pages for annotation and search. | Launch |
| F069 | PDF export | Export a page, selection of pages, or complete document. | Launch |
| F070 | Image export and printing | Share images or print notes through supported workflows. | Launch |
| F071 | Native export and backup | Preserve richer editing data in Goodnotes-specific files. | Own format at launch |
| F072 | Batch folder export | Export folders with their hierarchy inside a ZIP. | Personal |
| F073 | Cloud PDF writeback | Save a PDF back to supported connected storage. | Platform |

Exported PDF and native editing data are different products. The export guide documents page/document/folder choices and native, PDF, and image outputs.[^14] Its format comparison says editable PDFs preserve outlines and original links, while its flattened mode can include recognized handwriting but does not preserve those navigation structures. These are Goodnotes' documented behaviors, not universal limitations of flattened PDFs.[^15]

### Audio and lecture review

Audio can accompany notes, with multiple clips, timeline controls, and synchronized handwriting replay. Replay settings are documented for Apple notebook documents, not every content type.[^22]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F074 | Audio capture | Record and manage multiple clips in a document. | Personal |
| F075 | Note replay | Synchronize playback with the handwriting created during recording. | Personal |
| F076 | Replay display modes | Spotlight, progressive reveal, and static handwriting views. | Personal |
| F077 | Ongoing recording | Continue supported recording workflows while changing documents/apps. | Personal |
| F078 | Transcription | Convert live recording to searchable text on-device or in cloud. | Advanced |
| F079 | Audio enhancement | Reduce background noise during playback. | Advanced |
| F080 | Audio sharing and backup | Preserve or share recording content through supported formats. | Personal |

The transcription FAQ distinguishes hardware-dependent on-device models from metered cloud transcription. It says existing external recordings cannot currently be imported for transcription, and transcription stops after three hours even though recording may continue. Language lists and individual device eligibility need verification in the current app.[^23]

### Study and recall

Study Sets combine question/answer cards with a spaced-repetition mode, imports, and reminders. The dedicated guide labels the feature iOS-only.[^24] Tape provides a quicker reveal interaction directly on the notebook page.[^12]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F081 | Tape reveal | Cover material and tap to reveal it for recall practice. | Launch |
| F082 | Tape styling | Solid colors, patterns, custom image patterns, and marketplace designs. | Personal |
| F083 | Flashcards | Create question/answer Study Sets with supported media. | Personal |
| F084 | Spaced repetition | Schedule review and focus practice through Smart Learn. | Personal |
| F085 | Study import/export | Exchange study files and import tabular card data. | Personal |
| F086 | Time Keeper | Use the built-in timing tool while working. | Personal |

### Math and AI

Math Assist is an English-notebook, iOS-only workflow for recognizing expressions and placing computed answers into notes. Its documentation covers arithmetic, substitutions, equations, algebra, trigonometry, sums/products, functions, limits, derivatives, integrals, and a matrix-algebra section; it explicitly lists unsupported categories including differential equations, geometry, and inequalities. It is not a guarantee of arbitrary mathematical correctness.[^26]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F087 | Math conversion | Turn handwritten math into rendered, editable notation. | Advanced |
| F088 | Math Assist | Recognize equations, correct LaTeX, evaluate, and update variables. | Advanced |
| F089 | Math tutoring | Solve and Teach Me workflows with step-by-step interaction. | Advanced |
| F090 | Equation graphs | Current release notes reference generated math graphs. | Advanced validation needed |
| F091 | Note questions and quizzes | Ask about content and generate study questions. | Advanced |
| F092 | Writing assistance | Summarize, rewrite, shorten, format, and draft content. | Advanced |
| F093 | Generated visuals | Create diagrams, mind maps, timelines, and images. | Advanced |
| F094 | AI editing workflow | Work on selections or whole documents; preview/modify/insert outputs. | Advanced |
| F095 | AI usage controls | Plans and monthly credits govern cloud features. | Advanced |

Goodnotes' math tutoring guide identifies a Wolfram Alpha LLM API integration and distinguishes guided teaching from full solutions.[^27] The general AI guide documents question-answering, editing/creation modes, selectable context, and generated diagrams/images.[^25] Equation graph support is evidenced by release-note fixes rather than a complete feature specification; equivalent graphing should have its own scoped prototype.[^1]

### Whiteboards and typed documents

Whiteboards can contain multiple boards, background patterns/colors, a minimap, and collaboration. Notebook-to-whiteboard conversion is documented for iOS.[^29] Text Documents provide rearrangeable blocks, headings, lists, quotes, code, tables, links, and media, but do not support the freeform drawing toolset.[^30]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F096 | Whiteboard engine | Multiple expandable boards, navigation minimap, and canvas objects. | Platform |
| F097 | Notebook conversion | Convert a notebook into a whiteboard on supported Apple devices. | Platform |
| F098 | Text Document engine | Continuous, block-based typing with rich formatting and slash commands. | Platform |
| F099 | Tables and media blocks | Structured tables, images, video, diagrams, and block reordering. | Platform |

### Sharing and integrations

The current product spans legacy public notebook sharing and newer Pro collaboration. The older sharing guide documents revocation, a shared-document view, change indicators, and following a collaborator.[^34] Meeting AI adds event-linked notes, summaries, transcript navigation, and post-meeting document creation.[^28]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F100 | Shared documents | Share links, collaborate/comment, follow changes, and revoke access. | Platform |
| F101 | Presentations | External-screen output, laser pointer, and presentation controls. | Personal |
| F102 | Meeting workflow | Calendar-linked notes, live summaries, and generated meeting documents. | Advanced and Platform |
| F103 | Integrated planner | Show Google Calendar events in a supported planner. | Platform |
| F104 | External AI integrations | Create Goodnotes-compatible content from ChatGPT or Claude. | Platform |

The external AI integration produces documents, whiteboards, and diagrams for import into Goodnotes and uses the external assistant's model rather than Goodnotes AI credits.[^36] This does not establish an unrestricted third-party API for reading or cloning a user's whole Goodnotes library.

### Protection and the wider product ecosystem

Goodnotes separates Apple iCloud sync, its own cross-platform cloud, one-way backups, and manual archives.[^31][^32][^33] Password protection also has export, platform, and backup limits; the documented lock does not travel with exported files.[^21]

| ID | Capability | Documented behavior | Target |
|---|---|---|---|
| F105 | Apple sync | Keep supported Apple libraries synchronized through iCloud. | Personal |
| F106 | Goodnotes Cloud | Synchronize the account library across supported platform families. | Platform |
| F107 | Backup management | Automatic one-way copies, status, provider options, and manual archives. | Launch manual; Personal auto |
| F108 | Document lock | Password plus supported biometrics for notebooks/whiteboards. | Personal |
| F109 | Marketplace | Templates, covers, stickers, tape designs, and creator content. | Separate marketplace |
| F110 | Organizational tools | Education/admin, SSO, domain, billing, and enterprise controls. | Separate product |
| F111 | Workspaces | Dedicated work environments advertised as forthcoming. | Unconfirmed roadmap |
| F112 | Word Complete | Former predictive handwriting feature, discontinued in 2025. | Retired |

The launch does not require a marketplace, enterprise organization, or cloud collaboration service. Locally supplied original templates and reusable objects satisfy the initial creative workflow. Marketplace content and institutional capabilities belong to a separate expansion decision.[^2]

## Platform differences that affect the build

| Feature | Publicly documented limitation | Design consequence |
|---|---|---|
| Text Documents | No freeform ink, ruler, tape, or drawing highlighter | Implement as a separate engine if added. |
| Layers | Experimental Pro notebook feature on iPad and Mac; maximum five | Model layers explicitly, but do not inherit arbitrary competitor limits. |
| Study Sets and Time Keeper | Not available on Android/Windows/web according to cloud guide | Cross-platform parity requires more than file synchronization. |
| Zoom Window and Math Assist | Dedicated guides label them iOS-only | Prioritize native iPad interaction. |
| Word/PowerPoint import | Documented for iOS/iPadOS, with conversion fidelity limits | Start with PDFs; do not promise editable Office files. |
| Audio replay | Apple notebooks only | Separate recording from stroke-timed replay. |
| On-device transcription | Supported hardware, language model, and operating system required | Provide capability checks and a useful non-transcription fallback. |
| Password protection | Apple-only behavior; export does not retain lock; Auto Backup excludes locked items | Treat backup and export confidentiality as explicit product behavior. |
| Auto Backup | One-way process, documented for iOS/iPadOS rather than Mac | Sync and backup need different status and recovery controls. |

These limits come from the feature-specific sources cited in the inventory. The new app's platform matrix must be verified against its own implementation rather than copied from Goodnotes.

## Original product definition

### Positioning

Courseleaf is a native iPad notebook for students who work through handwritten problems and annotate course PDFs. Its product promise is that a student can capture a lecture, find the relevant work later, and turn selected material into focused review without reorganizing everything manually.

The proposed differentiator is a **Problem Page** workflow. A page can have a problem title, a source reference, optional Given and Find labels, working space, a result region, and a status such as unfinished, check again, or understood. The student decides what each region means. The feature does not need to solve equations or recognize handwriting perfectly to be useful.

A second differentiator is a course-level review queue. A student marks a page or rectangular region for review, adds an optional prompt, and opens that material later in context. Revealing a covered result and jumping back to the source page makes this useful before a full flashcard or AI system exists.

A third differentiator is transparent file ownership: a documented native archive, dependable PDF exports, visible save/backup status, and OCR indexing for scanned imported pages. These are design priorities and proposed capabilities, not claims that Goodnotes never offers comparable workflows.

### Essential screens

| Screen | Required behavior |
|---|---|
| Library | Courses/folders, notebooks, recent work, favorites, search, import, and trash. |
| Notebook editor | Large canvas, compact tools, page navigation, text/images/shapes, reading mode, and save status. |
| Problem Page inspector | Edit problem metadata, source reference, result region, and review status. |
| Review queue | Open due/manual review items, reveal answers, mark reviewed, and return to source. |
| Search | Search titles, typed text, PDF text, and recognized text; distinguish indexing state. |
| Export and backup | Select scope and format, show progress, save/share, and surface errors. |
| Settings | Input preference, paper defaults, appearance, storage, backup, accessibility, support, and purchase restore. |

Use an original visual system: restrained neutral surfaces, readable type, one clear accent, and original notebook covers. Keep the editor focused on the page. Place infrequent options in contextual menus. Support portrait, landscape, keyboard-visible layouts, split windows, left-handed use, and adjustable text sizes around the canvas.

### First release requirements

The initial release must include folders and notebooks; reusable original paper templates; quick capture; Pencil and finger input; pen, pencil, and highlighter; supported pixel and stroke erasing; lasso selection for ink and supported objects; undo/redo; text boxes; images; basic shapes; object locking; page operations; bookmarks; PDF import; scanning; PDF/image/native export; local search; review tape; Problem Pages; and manual backup/restore.

Recognition begins with typed/PDF text and a measured, best-effort OCR pipeline. English handwriting search/conversion is a launch objective subject to an actual handwriting evaluation. If quality is inadequate, the release must describe the limitation and keep original ink intact. Never silently label an unvalidated raster OCR experiment as handwriting parity.

The first release can work without an app account, cloud AI, or continuous internet. Apple sync, recordings, spaced repetition, advanced gestures, and additional clients follow after the data engine is stable. The app should not display empty premium feature screens for unfinished work.

### Scope of each common interaction

Creating a notebook takes a title and paper choice, with sensible defaults and immediate writing. Import accepts one or more PDFs/images and lets the student choose a new notebook or an insertion location. Newly imported files are copied into the app's managed storage before the external access grant ends.

Writing and erasing act on editable ink, never on the underlying PDF text. Lasso selection exposes only actions that work for every selected object, and every committed transform is undoable. Imported source pages stay visually distinct from editable additions in the object model even when they appear together on screen.

Export gives the student a reliable PDF for submission and a native archive for future editing. PDFs preserve readable content, page order, and page size. A native archive restores actual editable objects and ink. Tape masking offers a deliberate export choice so covered answers do not unexpectedly appear or disappear.

When something fails, the app must keep the last valid document, explain the failure, and offer a safe retry or a copy. Running out of disk space is not a reason to show a successful save. A canceled import is not a reason to create half of a notebook.

## Technical architecture

### Recommended stack

| Area | Recommendation | Reason and limit |
|---|---|---|
| App shell | Swift and SwiftUI, with UIKit editor components | Native iPad behavior and direct framework access. |
| Ink | PencilKit behind an InkEngine adapter | Strong starting point; specialized gestures and semantic editing remain app work. |
| PDF | PDFKit and Core Graphics | Preserve source PDFs and render annotations explicitly. |
| Source of truth | Versioned document packages with immutable revision assets | Enables recovery, portable backups, and deliberate conflict handling. |
| Catalog and search | SQLite metadata/search cache, rebuildable from packages | Search failures must not damage notebook content. |
| Text and scans | PDF text extraction; Vision/VisionKit after SDK validation | OCR accuracy and language availability require tests. |
| Audio later | AVFoundation with an app-owned recording timeline | Recording and replay need durable timestamps and interruption handling. |
| Apple sync later | CloudKit with explicit revision/conflict logic | Cloud transport is not automatic content merging. |
| Purchases | StoreKit 2 if using an in-app unlock | Use verified transactions and current product data. |
| AI later | Provider-independent backend gateway | Keep secrets off-device and bound recurring costs. |

Apple's PencilKit material documents a responsive drawing canvas and public access to strokes, paths, transforms, and masks.[^39][^40] PDFKit's overlay protocol is explicitly intended for interactive views such as PencilKit over PDF pages; exporting overlay content is still the app's responsibility.[^41] Newer Pencil features must be selected through supported APIs rather than assumed from the presence of a tool picker.[^42]

### Start with an engineering prototype

Before implementing the full interface, build a small iPad harness with a blank page, a rotated PDF page, a dense ink page, text/image overlays, lasso movement, save/reopen, and export. Test it on a physical iPad with an Apple Pencil. The prototype decides whether the planned public APIs can meet the selection, erasing, coordinate, and performance requirements.

PencilKit is not a turnkey Goodnotes engine. Its built-in selection is primarily about its own drawing content. A unified lasso that selects ink, images, text, shapes, and tape needs application-level hit testing and commands. Its drawing data also does not provide a complete notebook schema, library, recognition engine, conflict resolver, or revenue system.

Keep the initial ink adapter narrow. Store the original PencilKit data for fidelity, isolate decoding and transformations, and preserve stroke masks when applying recolor or movement. Do not flatten each stroke into a bitmap merely to simplify editing. If an operation cannot be implemented correctly with public APIs, record it as a specific gap and propose a revised implementation instead of using private APIs.

### Document model and storage

| Entity | Essential fields |
|---|---|
| Document | Stable ID, schema version, type, title, language, folder ID, ordered page IDs, revision head. |
| Page | Stable ID, width/height in points, background/template/source reference, rotation, ordered object IDs, revision ID. |
| Source asset | Stable ID, content hash, media type, file path, original PDF page index when applicable. |
| Ink layer | Stable ID, PencilKit data reference, layer order, visibility, revision metadata. |
| Canvas object | Stable ID, type, transform, bounds, z-order, lock flag, content reference, optional group ID. |
| Problem metadata | Title, source link, Given/Find labels, result region, status, course association. |
| Review item | Stable ID, source page/region, optional prompt, reveal state, review history. |
| Search record | Page ID, revision ID, extracted text, language, bounding boxes, confidence, indexing status. |
| Revision | Stable ID, parent revision IDs, sequence, changed assets, checksums, timestamp, schema. |
| Tombstone | Deleted entity ID, revision metadata, deletion time, restore information. |
| Recording later | Clip ID, file segments, monotonic timeline, pause/interruption mapping, page/event associations. |

A document package should contain a small manifest, immutable source assets, per-page revision content, and optional previews. The SQLite catalog indexes packages and can be reconstructed. It must not become a second competing source of document truth. Keep thumbnails and OCR caches disposable; preserve original content and revision history.

Use a single writer per open document. Commit immutable content files first, validate their references and checksums, and atomically replace the manifest last. Retain a last-known-good manifest. After a crash, ignore unreferenced partial output and recover a valid revision. Garbage collection must respect undo history, recoverable trash, exports in progress, and outstanding sync revisions.

Use short, measured save coalescing to avoid excessive disk writes. The proposed target is to persist completed edits within one second under normal conditions, with an explicit flush when changing pages or leaving the editor. Measure this target. A force termination can interrupt an uncommitted edit; the interface must not claim it was saved before durable commit finishes.

The native archive uses an original extension and documented schema. Validate version, path names, asset sizes, archive expansion limits, missing references, and checksums before import. Restore as a copy by default. A newer unsupported schema must produce a clear error or safe read-only recovery, not an empty notebook.

### Coordinate system and rendering

Define page coordinates in PDF points with an app-standard origin and orientation. Use one tested mapping among source PDF boxes, page coordinates, visible canvas coordinates, and export coordinates. Handle MediaBox/CropBox differences and 0, 90, 180, and 270 degree rotations explicitly.

An overlay must align after zooming, scrolling, window resizing, and reopening. Only the visible page and a small number of neighbors should have active heavyweight canvases. Cache thumbnails and rendered backgrounds with bounded memory. Run export, recognition, and indexing outside the live drawing path.

Use a deterministic compositing order for the background, images, highlighter, ink, typed objects, shapes, and tape. Preserve user stacking where supported. A single global highlighter bitmap that hides text or ignores erasing is not an acceptable shortcut. The prototype must establish how the chosen ink engine handles blending and selection.

### PDF import and export contract

Keep the original PDF bytes as an immutable asset. Work with page references rather than rasterizing the entire document at import. Capture encrypted/unsupported/malformed-file errors, allow cancellation, and validate the entire import before presenting it as finished.

Offer a reliable presentation PDF first: preserve the source page's visible content and composite the app's annotations accurately. Preserve source text and navigation when the implementation supports them; test this rather than promising it from a screenshot. High-resolution rasterization of an ink region can be a documented export fallback, but rasterizing every source page would harm searchability, size, and print quality.

Add interoperable editable PDF annotations only with a written supported-object list and round-trip tests in independent viewers. A PDF that displays annotations is not automatically editable in the same way as the native notebook. Native archives are the authoritative format for restoring editing behavior, review metadata, and later audio.

Do not implement an undocumented Goodnotes-file decoder as a launch dependency. For migration, export existing Goodnotes notes as PDFs and retain separate original backups. Existing flattened handwriting will be visible but usually not recoverable as independent editable strokes. New ink added in the new app remains editable. This limitation should be explained before import, not discovered after deleting the originals.

### Recognition and search

Extract typed text and real PDF text first. Schedule recognition only for changed pages or explicitly requested imports. Store bounding boxes and the source revision so a search result can highlight the right area and stale results can be invalidated safely.

Render ink or scanned regions for an initial on-device OCR evaluation. Use a student-created test corpus covering neat print, cursive, small writing, mixed equations, and photographed pages. Measure recognition error and successful search queries separately. Text OCR, handwriting recognition, mathematical layout parsing, and semantic retrieval are four different capabilities.

Low-confidence recognition must not replace the original ink automatically. Conversion should show an editable preview and insert a new text object only when accepted. Later specialist handwriting/math SDKs require an actual license review, supported-language evaluation, and cost assessment. They are not implied by a Claude or Goodnotes subscription.

### Sync and backup

The local release must already have complete manual backup/restore. Cloud sync is a later product capability, not the only recovery mechanism. Apple's sync-engine sample is a reference for transport/state handling, while this app must define its own document conflict rules.[^43]

For initial Apple sync, synchronize immutable revisions and assets with stable IDs. Concurrent edits to different pages can be incorporated independently. Concurrent changes to the same page produce a visible conflict copy unless a tested merge algorithm can preserve both. Never resolve notebook conflicts by blindly replacing the entire document with whichever upload arrived last.

Test account changes, iCloud quota exhaustion, offline edits, deletion while offline, duplicated delivery, app reinstall, and schema upgrades. Keep local work usable while cloud service is unavailable. Do not claim instant or guaranteed background synchronization; show queued, syncing, up-to-date, and failed states separately from local save status.

Automatic backups should write recoverable, versioned snapshots to a user-chosen destination and show the last successful completion. Background scheduling is best effort. A backup is successful only when its archive validates and can be restored, not merely when an upload request was started.

### Audio and AI expansion

Audio recording needs segmented durable files, interruption handling, visible recording state, and a timeline that remains correct across pauses, page changes, and route changes. Store an application recording time base rather than relying only on wall-clock time. Replay should reflect when ink was originally created; moving old ink later must not silently change the lecture moment it represents.

Test native speech capabilities on the target SDK and hardware before selecting them. An audio file that can be recorded is not proof that it can be transcribed offline in the desired language. Always keep recording useful when transcription is unavailable.

The AI backend should use server-held credentials, authenticated requests, usage limits, request-size caps, budget limits, and retry/idempotency controls. The student chooses the document or selection sent for processing. Ground note answers in page references and distinguish the source text from generated explanations. Imported notes are untrusted content, not instructions to the backend or model.

Generated edits must be previewed and undoable. Math recognition must expose the interpreted expression before evaluation. Validate supported calculations through a deterministic engine where possible; do not present an unconstrained language-model answer as a verified calculation. Building a complete computer-algebra system is not a side task inside the notebook launch.

### Privacy and purchase behavior

Use device file protection and minimize collection. Diagnostic reports should exclude note text, images, audio, and account credentials by default. A later app lock needs a defined threat model, including search results, previews, widgets, exports, and cloud copies; hiding a thumbnail is not encryption.

For a paid unlock, store entitlements from verified StoreKit transactions. Handle cancellation, pending purchases, refunds/revocations, offline use, and restore. Display localized product prices from StoreKit rather than hardcoding marketing prices. A lapse or purchase error must never delete notes; preserve reading and export access as a product policy. Apple's purchase documentation is the implementation reference.[^53]

## Delivery roadmap

The estimates below are planning allowances for focused engineering days by one developer assisted by coding tools. They are not measured Claude execution times. They exclude external review queues and may expand substantially if the ink prototype fails, the developer is learning native graphics, or hardware is unavailable.

| Gate | Work | Exit evidence | Allowance |
|---|---|---|---|
| G0 | Environment audit and ink/PDF feasibility | Physical-device prototype, API limitations, measured alignment and save/reopen behavior. | 3 to 5 days |
| G1 | Storage and notebook core | Versioned package, library, pages, original templates, atomic saves, trash, restore. | 7 to 12 days |
| G2 | Complete editor | Ink, erasing, mixed selection, objects, undo, navigation, accessible controls. | 10 to 15 days |
| G3 | Document interchange | PDF/image import, scan, share import, PDF/image/native exports, migration guidance. | 8 to 12 days |
| G4 | Student workflow and search | Problem Pages, review queue/tape, indexed search, OCR evaluation. | 5 to 8 days |
| G5 | Reliability and device beta | Crash recovery, stress fixtures, performance evidence, real class use. | 10 to 15 days |
| G6 | Release preparation | Purchase verification if used, metadata, privacy, screenshots, signed archive. | 5 to 8 days |

Together, these allowances are 48 to 75 focused engineering days, roughly 10 to 15 full-time weeks. A part-time college schedule could turn that into approximately four to eight months or longer. A small prototype may appear much sooner, but that is not equivalent to a dependable replacement for a semester's notes.

### Personal feature expansion

After launch, prioritize Apple sync and an iPhone reading/search experience; audio recording and replay; reusable elements; sticky notes; layers; improved gestures; Zoom Window; widgets; and flashcards. Implement one complete user workflow at a time. A rough allowance is another 30 to 60 focused engineering days, subject especially to sync and recording complexity.

A Mac app should be separately reviewed for keyboard, trackpad, windows, typography, and large libraries. An iPad binary running on a Mac is not proof of a finished Mac experience. Other platforms need explicit formats and rendering compatibility, not merely an account login.

### Advanced feature expansion

Add improved handwriting recognition, conversion, spelling, reflow, math notation, graphing, and optional AI in separate prototypes. Each prototype needs a quality dataset, licensing decision, unsupported-case behavior, and cost model. Only features that clear those gates should enter the customer-facing roadmap.

For math, begin with editable typeset notation and a small, explicit set of typed calculations. Handwritten symbolic algebra and calculus come later. For AI, begin with summaries and question-answering over a selected notebook, then add reviewed study generation. Automatic document editing and generated diagrams require object-level validation and undo.

### Additional engines and services

Whiteboards, block-based documents, live collaboration, Android/Windows/web clients, calendar integrations, and a marketplace are separate substantial projects. The data model should leave room for them, but the first app must not carry half-built versions of all of them.

A full product comparable in breadth to today's Goodnotes is better viewed as an ongoing team-scale program. No credible one-shot Claude prompt can guarantee exact feature parity, recognition quality, long-term reliability, or App Store acceptance. The prompt supplied with this plan establishes execution order and proof of completion rather than making that guarantee.

## Acceptance criteria

These are proposed product gates. They must be measured on the actual implementation and supported device matrix. Performance thresholds are initial targets to calibrate during G0, not claims about Goodnotes or about unbuilt software.

| Test | Passing behavior |
|---|---|
| A01 Blank notebook | Create, write, close, terminate, relaunch, and reopen with committed ink intact. |
| A02 Dense drawing | Pan/zoom and write on a page with 10,000 test strokes without a sustained input stall. |
| A03 Drawing responsiveness | On the baseline test iPad, maintain usable 60 Hz interaction with no repeated app-induced main-thread stalls over 100 ms during normal writing. |
| A04 PDF alignment | Annotations remain aligned at 0/90/180/270 degrees and multiple zoom levels, including nonzero crop origins. |
| A05 Export alignment | Export matches page-space positions within one PDF point for geometric fixtures. |
| A06 Long PDF | Open a 300-page mixed PDF without allocating an active canvas for every page. |
| A07 Save failure | Simulated disk-full/write failure retains the last valid revision and reports unsaved changes. |
| A08 Interruption recovery | Termination during content write or manifest replacement recovers a valid document. |
| A09 Mixed selection | Move ink/text/image/shape selections together, undo once, and recover exact prior state. |
| A10 Partial erasing | Recolor, move, reopen, and export partially erased ink without resurrecting erased regions. |
| A11 Page operations | Copy/move/delete/restore/reorder uses stable IDs and never affects a neighboring page accidentally. |
| A12 Text and links | Export keeps intended text readable/searchable and tested links functional where advertised. |
| A13 Native archive | Export/import restores editable ink and objects, page metadata, and review items. |
| A14 Invalid archive | Reject traversal, oversized expansion, missing assets, unsupported schemas, and corrupt checksums safely. |
| A15 OCR and search | Published test corpus and error/search results; stale index entries are removed after edits. |
| A16 Permissions | Camera denied, limited photo access, no Pencil, and no network each leave core notes usable. |
| A17 Layout and access | Portrait/landscape, keyboard, large text, VoiceOver controls, and split width remain usable. |
| A18 Purchases | Success, canceled, pending, revoked, offline, and restore states are verified if monetization ships. |
| A19 Beta use | Complete several real lectures and assignment exports on-device with no unresolved data-loss or corruption issue. |
| A20 Release evidence | Build/test reports, real screenshots, known limitations, and exact source commit accompany the archive. |

Maintain a small fixture collection: original PDFs with text, scanned PDFs, rotated/cropped pages, large images, editable objects, partially erased strokes, long notebooks, and malformed imports. Tests should verify observable data and rendering behavior, not merely mirror internal implementation branches.

Later gates add two-device offline conflicts, cloud quota failure, audio interruptions, replay timing, review scheduling across time zones, AI quota errors, and real collaborative revocation. Unit tests alone do not validate Apple Pencil latency or cloud behavior.

## Costs and release decisions

The low-cost launch avoids hosted accounts, generative AI, server storage, and paid recognition SDKs. Its principal resources are development time, access to a Mac/Xcode build environment, and an actual iPad/Pencil for testing. Existing Apple Developer membership may already cover publishing through the same account; signing and commercial agreements still need to be configured for the new app.

A reasonable pricing experiment is a useful free allowance with a one-time local-feature unlock, or a paid download with a clear demo. For example, a $14.99 to $24.99 unlock is a hypothesis to test, not a proven winning price. Goodnotes' low annual price means price alone is weak differentiation. Keeping a student's work organized and exportable is the stronger product argument.

Do not include unlimited cloud AI in a cheap lifetime purchase. Before adding it, estimate active users multiplied by transcription minutes, text/image requests, storage, and bandwidth, then add monitoring and support. Measure actual provider costs, set per-account quotas and a service budget cap, and evaluate an optional recurring plan only after the feature earns repeat use.

### App Store requirements

Apple's guidelines prohibit copycat presentation and unauthorized branding; require complete, working functionality; and require appropriate handling of personal data. They also explicitly require disclosure and permission before sharing personal data with third-party AI. These points shape the product and release gates; they do not guarantee approval.[^38] Account creation brings an in-app account-deletion requirement, described in Apple's dedicated guidance.[^52]

Use an original name, icon, covers, marketing text, interface, and bundled content. Do not ship Goodnotes assets or imply an affiliation. Review the rights for every font, icon, code dependency, sample PDF, and future recognition model. A differently colored copy of the interface is insufficient product differentiation.

Before release, prepare the real support and privacy URLs, current age-rating answers, screenshots from the implemented app, review notes, and any purchase products. Ensure privacy disclosures describe the actual build and every included SDK. Apple's privacy guidance covers the information supplied in App Store Connect.[^45]

The final human-controlled step is selecting the public name, approving any paid services, signing with the owner's account, and authorizing App Store submission. Coding work, tests, draft metadata, and unsigned or otherwise authorized archives should be finished before those final account-dependent steps are requested.

## How to use the Claude build prompt

Place this Markdown specification and the accompanying **Claude_Code_Build_Prompt.md** in the project workspace. Open Claude Code in the intended app repository and provide the full build prompt. The prompt is written for Claude Code; the word ultra is treated as the operator's choice of the strongest suitable reasoning setting available in their installed tool, not as a separate verified product name.

The recommended workflow follows Anthropic's guidance to provide concrete verification, inspect the project before implementing, and preserve concise project instructions across sessions.[^44] The supplied prompt adds notebook-specific milestones, failure cases, and evidence requirements.

Run on a Mac with Xcode for the shortest feedback loop. A Windows/Linux agent can produce source and portable logic tests, but it cannot truthfully certify the native iPad build without a Mac build runner and actual build results. A physical iPad/Pencil remains necessary for input testing.

The first session should establish the repository, write the feature register, build the feasibility harness, and continue into the launch milestones as capacity permits. It must preserve a concise handoff before context is exhausted. On later sessions, use the continuation prompt included in the companion file so the agent resumes from verified state.

Keep all 112 feature records in the project register, including deferred and retired entries. Mark implementation and validation separately. A planned item is not implemented, a compiling item is not device-verified, and a screenshot is not proof of safe persistence.

## Sources

Goodnotes sources are official product/support documentation unless otherwise indicated. Undated pages were accessed September 11, 2026; they describe the public state available at that time and can change. The App Store date is identified above. Apple and Anthropic references support implementation and delivery guidance. Conflicting documentation is described in the report rather than silently reconciled.

[^1]: Goodnotes Limited / Apple. [Goodnotes AI Notes Docs PDF and version history](https://apps.apple.com/us/app/goodnotes-ai-notes-docs-pdf/id1444383602). Version 7.1.19 dated September 4, 2026; accessed September 11, 2026.
[^2]: Goodnotes. [Plans and pricing](https://www.goodnotes.com/pricing). Undated; accessed September 11, 2026.
[^3]: Goodnotes. [Compare Goodnotes Plans and Features](https://support.goodnotes.com/hc/en-us/articles/13808767840015-Compare-Goodnotes-Plans-and-Features). Undated; accessed September 11, 2026.
[^4]: Goodnotes. [Write and customize ink with the Pen tool](https://support.goodnotes.com/hc/en-us/articles/7353756785679-Write-and-customize-ink-with-the-Pen-tool). Undated; accessed September 11, 2026.
[^5]: Goodnotes. [Erase handwriting and page content with the Eraser tool](https://support.goodnotes.com/hc/en-us/articles/7353718249231-Erase-handwriting-and-page-content-with-the-Eraser-tool). Undated; accessed September 11, 2026.
[^6]: Goodnotes. [Taking Notes and Annotating Documents](https://support.goodnotes.com/hc/en-us/sections/7352640439055-Taking-Notes-Annotating-Documents). Feature index; accessed September 11, 2026.
[^7]: Goodnotes. [Customize the toolbar](https://support.goodnotes.com/hc/en-us/articles/8900755183631-Customize-the-toolbar). Undated; accessed September 11, 2026.
[^8]: Goodnotes. [Select move and edit content on the page](https://support.goodnotes.com/hc/en-us/articles/7353695644175-Select-move-and-edit-content-on-the-page). Undated; accessed September 11, 2026.
[^9]: Goodnotes. [Edit and reflow handwriting with the Lasso tool](https://support.goodnotes.com/hc/en-us/articles/10779441732111-Edit-and-reflow-handwriting-with-the-Lasso-tool). Undated; accessed September 11, 2026.
[^10]: Goodnotes. [Organize content with layers](https://support.goodnotes.com/hc/en-us/articles/16536297803535-Organize-content-with-layers). Experimental feature guide; accessed September 11, 2026.
[^11]: Goodnotes. [Draw shapes and build diagrams](https://support.goodnotes.com/hc/en-us/articles/13682939148943-Draw-shapes-and-build-diagrams-in-Goodnotes). Undated; accessed September 11, 2026.
[^12]: Goodnotes. [Use the Tape Tool to hide and reveal content](https://support.goodnotes.com/hc/en-us/articles/9489290046607-Use-the-Tape-Tool-to-hide-and-reveal-content). Undated; accessed September 11, 2026.
[^13]: Goodnotes. [Import files into Goodnotes](https://support.goodnotes.com/hc/en-us/articles/7353717816463-Import-files-into-Goodnotes). Undated; accessed September 11, 2026.
[^14]: Goodnotes. [Export documents or pages](https://support.goodnotes.com/hc/en-us/articles/7353742824975-Export-documents-or-pages). Undated; accessed September 11, 2026.
[^15]: Goodnotes. [Differences between Editable and Flattened PDF Formats](https://support.goodnotes.com/hc/en-us/articles/8537070839183-Differences-between-Editable-and-Flattened-PDF-Formats). Undated; accessed September 11, 2026.
[^16]: Goodnotes. [How to Search Your Notes](https://support.goodnotes.com/hc/en-us/articles/7353743594127-How-to-Search-Your-Notes). Undated; accessed September 11, 2026.
[^17]: Goodnotes. [Handwriting recognition and search languages](https://support.goodnotes.com/hc/en-us/articles/7353727932047-What-languages-does-Goodnotes-support-for-handwriting-recognition-and-search). Undated; accessed September 11, 2026.
[^18]: Goodnotes. [Organizing Documents](https://support.goodnotes.com/hc/en-us/sections/7352625352847-Organizing-Documents). Feature index; accessed September 11, 2026.
[^19]: Goodnotes. [Templates and Notebook Covers](https://support.goodnotes.com/hc/en-us/sections/7352641307663-Templates-Notebook-Covers). Feature index; accessed September 11, 2026.
[^20]: Goodnotes. [Use Goodnotes widgets on iPhone iPad and Mac](https://support.goodnotes.com/hc/en-us/articles/15492667891471-Use-Goodnotes-widgets-on-iPhone-iPad-and-Mac). Undated; accessed September 11, 2026.
[^21]: Goodnotes. [Lock notebooks and whiteboards with Password Protection](https://support.goodnotes.com/hc/en-us/articles/9585471154447-Lock-notebooks-and-whiteboards-with-Password-Protection). Undated; accessed September 11, 2026.
[^22]: Goodnotes. [Add Audio Recordings to your documents](https://support.goodnotes.com/hc/en-us/articles/7352688559631-Add-Audio-Recordings-to-your-documents). Undated; accessed September 11, 2026.
[^23]: Goodnotes. [Audio Transcription FAQs](https://support.goodnotes.com/hc/en-us/articles/10234247292303-Audio-Transcription-FAQs-in-Goodnotes). Undated; accessed September 11, 2026.
[^24]: Goodnotes. [Getting Started with Study Sets and Smart Learn](https://support.goodnotes.com/hc/en-us/articles/7353756529551-Getting-Started-with-Study-Sets-and-Smart-Learn). Undated; accessed September 11, 2026.
[^25]: Goodnotes. [A guide to Goodnotes AI](https://support.goodnotes.com/hc/en-us/articles/10779112528399-A-guide-to-Goodnotes-AI). Undated; accessed September 11, 2026.
[^26]: Goodnotes. [How to use Math Assist](https://support.goodnotes.com/hc/en-us/articles/10779567357199-How-to-use-Math-Assist). Undated; accessed September 11, 2026.
[^27]: Goodnotes. [Goodnotes AI for Math](https://support.goodnotes.com/hc/en-us/articles/13683534670223-Goodnotes-AI-for-Math). Undated; accessed September 11, 2026.
[^28]: Goodnotes. [Goodnotes AI for Meetings](https://support.goodnotes.com/hc/en-us/articles/13684043610255-Goodnotes-AI-for-Meetings). Undated; accessed September 11, 2026.
[^29]: Goodnotes. [Whiteboard](https://support.goodnotes.com/hc/en-us/articles/13693350308751-Whiteboard). Undated; accessed September 11, 2026.
[^30]: Goodnotes. [Text Document](https://support.goodnotes.com/hc/en-us/articles/13692184123279-Text-Document). Undated; accessed September 11, 2026.
[^31]: Goodnotes. [Sync your library across all platforms with Goodnotes Cloud](https://support.goodnotes.com/hc/en-us/articles/10277366719759-Sync-your-Goodnotes-library-across-all-platforms-with-Goodnotes-Cloud). Undated; accessed September 11, 2026.
[^32]: Goodnotes. [How to Set Up Auto Backup](https://support.goodnotes.com/hc/en-us/articles/7352786555279-How-to-Set-Up-Auto-Backup-in-Goodnotes). Undated; accessed September 11, 2026.
[^33]: Goodnotes. [Back up and restore your library manually](https://support.goodnotes.com/hc/en-us/articles/7353694866831-Back-up-and-restore-your-library-manually). Undated; accessed September 11, 2026.
[^34]: Goodnotes. [Share a document for collaboration](https://support.goodnotes.com/hc/en-us/articles/7353695997839-Share-a-document-for-collaboration). Legacy sharing guidance; accessed September 11, 2026.
[^35]: Goodnotes. [Sync Your Calendar with the Goodnotes Planner](https://support.goodnotes.com/hc/en-us/articles/17074653805583-Sync-Your-Calendar-with-the-Goodnotes-Planner). Experimental feature guide; accessed September 11, 2026.
[^36]: Goodnotes. [Use Goodnotes in ChatGPT and Claude](https://support.goodnotes.com/hc/en-us/articles/15790373823887-Use-Goodnotes-in-ChatGPT-and-Claude). Undated; accessed September 11, 2026.
[^37]: Goodnotes. [Sunsetting Word Complete](https://support.goodnotes.com/hc/en-us/articles/11917208851215-Sunsetting-Word-Complete-Frequently-Asked-Questions). Retirement effective March 31, 2025; accessed September 11, 2026.
[^38]: Apple. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/). Sections 2.1, 3.1, 4.1, 5.1, and 5.2; accessed September 11, 2026.
[^39]: Apple. [Introducing PencilKit](https://developer.apple.com/videos/play/wwdc2019/221/). WWDC 2019; accessed September 11, 2026.
[^40]: Apple. [Inspect modify and construct PencilKit drawings](https://developer.apple.com/videos/play/wwdc2020/10148/). WWDC 2020; accessed September 11, 2026.
[^41]: Apple. [What is new in PDFKit](https://developer.apple.com/videos/play/wwdc2022/10089/). WWDC 2022; accessed September 11, 2026.
[^42]: Apple. [Squeeze the most out of Apple Pencil](https://developer.apple.com/videos/play/wwdc2024/10214/). WWDC 2024; accessed September 11, 2026.
[^43]: Apple. [CloudKit Sync Engine sample](https://github.com/apple/sample-cloudkit-sync-engine). Official sample repository; accessed September 11, 2026.
[^44]: Anthropic. [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices). Undated; accessed September 11, 2026.
[^45]: Apple. [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/). Undated; accessed September 11, 2026.
[^46]: Goodnotes. [Product homepage](https://www.goodnotes.com/). Workspaces announcement; accessed September 11, 2026.
[^47]: Goodnotes. [Utilize the new features of Apple Pencil Pro](https://support.goodnotes.com/hc/en-us/articles/9757771783823-Utilize-the-new-features-of-Apple-Pencil-Pro). Undated; accessed September 11, 2026.
[^48]: Goodnotes. [Write with the Zoom Window](https://support.goodnotes.com/hc/en-us/articles/7353756826383-Write-with-the-Zoom-Window). Undated; accessed September 11, 2026.
[^49]: Goodnotes. [Elements Tool](https://support.goodnotes.com/hc/en-us/articles/7353727577359-Elements-Tool-Enrich-your-Notes). Undated; accessed September 11, 2026.
[^50]: Goodnotes. [Add sticky notes to your notes](https://support.goodnotes.com/hc/en-us/articles/16348150581647-Add-sticky-notes-to-your-notes). Undated; accessed September 11, 2026.
[^51]: Goodnotes. [Spellcheck your handwriting](https://support.goodnotes.com/hc/en-us/articles/14500614035471-Spellcheck-your-handwriting). Undated; accessed September 11, 2026.
[^52]: Apple. [Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/). Undated; accessed September 11, 2026.
[^53]: Apple. [In App Purchase](https://developer.apple.com/in-app-purchase/). Undated; accessed September 11, 2026.
