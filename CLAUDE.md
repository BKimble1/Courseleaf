# Courseleaf (working in this repository)

Courseleaf is an original native iPad notebook app for handwriting, PDF
coursework and a student Problem Page / review workflow. "Courseleaf" is an
internal codename, not a cleared public name. Never use Goodnotes' name,
assets, covers or code; implement familiar capabilities with original code.

## Layout

- `Package.swift`, `Sources/`, `Tests/` — the **CourseleafCore** Swift package
  (DocumentCore, PageGeometry, Editing, Persistence, Archive, Catalog, Fixtures).
  Builds and tests on Linux and Apple platforms. All document logic lives here.
- `App/` — the iPadOS app (SwiftUI shell, UIKit editor, PencilKit/PDFKit/Vision/
  StoreKit adapters). `App/project.yml` generates `App/Courseleaf.xcodeproj`
  with XcodeGen; the project file is not committed.
- `docs/` — contract and evidence documents. Read `docs/ARCHITECTURE.md` and
  `docs/FORMAT.md` before changing storage, geometry or editing code.
  `docs/NEXT_SESSION.md` is the resume point.
- `Fixtures/` — generated deterministic fixtures (`Scripts/generate-fixtures.sh`).

## Commands

```bash
# Linux or macOS: core package
swift build
swift test --parallel                      # all portable tests
swift test --filter PersistenceTests       # one module

# macOS with Xcode 16+: iPad app (see docs/BUILD_AND_TEST.md)
brew install xcodegen
Scripts/build-ios.sh                       # generate project, build + test on an iPad simulator
Scripts/archive-ios.sh                     # unsigned release archive (signing is manual)

# Linux toolchain used in remote sessions: /opt/swift-root/usr/bin (Swift 6.2.4)
```

## Architecture constraints

- One page coordinate system: PDF points, origin top-left of the visible
  (cropped, rotated) page. Every stored geometry is in page space.
- Document packages are the source of truth; SQLite catalog and previews are
  rebuildable/disposable. Never make the catalog a second copy of a document.
- Assets are immutable and content-addressed (SHA-256). Original PDFs/images
  are never modified.
- No app-wide mutable singleton; stores are actors injected from `AppEnvironment`.
- PencilKit only through `PencilKitInkEngine` and public API. Stroke transforms
  and recoloring must preserve erase masks.
- Nothing heavy (serialization, hashing, OCR, export) runs in the drawing path.
- Add a dependency only after checking licence and platform support; prefer none.

## Data-safety rules

- Commit order: assets → page files → revision → verify references → atomic
  manifest replace, keeping `manifest.lkg.json`. Never report "saved" before
  the rename and directory sync complete.
- Write failures, disk exhaustion and interrupted commits must leave the last
  valid revision readable. Failed import/restore must never touch the library.
- Validate archives (paths, sizes, expansion ratio, checksums, schema) before
  trusting any entry. Restore as a copy by default.
- Deleted pages/documents go to recoverable trash; garbage collection respects
  trash, undo history, retained revisions and in-flight exports.

## Verification expectations

- Every module change comes with tests that check externally observable
  behaviour (files on disk, exported coordinates, restored content), not
  internal branches. Do not weaken or skip a test to go green.
- Record outcomes honestly using the statuses in `docs/VALIDATION.md`:
  implemented, unit-tested, simulator-tested, device-tested, blocked.
  A Linux `swift test` pass is not a native build; do not claim it is.
- Update `docs/FEATURE_REGISTER.md` and `docs/NEXT_SESSION.md` when status changes.
