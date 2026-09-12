# Next session

Resume point for the Courseleaf build. Update this file before ending a session or
when context is nearly exhausted; keep it short and exact.

## State (2026-09-12)

- **Repository:** `quickwrite` (`/home/user/quickwrite` in the remote session), branch `main`.
- **Last commit on main:** `3b105a5` "Implement the core modules: persistence,
  archive, catalog, geometry, fixtures and editing".
- **Verified at that commit (Linux only):** `swift test` → `Executed 203 tests,
  with 0 failures` (recorded in `docs/VALIDATION.md` → Portable test runs).
  DocumentCore, PageGeometry, Editing, Persistence, Archive, Catalog and Fixtures
  are complete for launch scope at the package level.
- **In progress / uncommitted (parallel agents, orchestrator commits):**
  `Sources/Workspace` (`LibraryService`, `DocumentSession`; only
  `WorkspaceAPI.swift` is committed), `Tests/WorkspaceTests`, and every screen
  under `App/Courseleaf/` (Library, Editor, ProblemInspector, Review, Search,
  Export, Settings, Onboarding, InkEngine, Interchange; only `Entitlements/`,
  `Resources/` and `project.yml` are committed). Do not discard untracked files
  under `Sources/`, `Tests/`, `App/`, `Fixtures/` or `docs/`.
- **Active gate:** G1 (library and storage) and G2 (editor) at the app layer; G3
  and G4 portable parts exist (Archive, Catalog, review rules). G0 (feasibility
  harness on a physical iPad) is **open**: no device is available here, so
  portable logic was built ahead of it on the documented architecture.
- **Last genuinely verified gate:** none. Every `docs/VALIDATION.md` A-row is
  `pending`; portable evidence is recorded per row where it exists.

## Commands

```bash
export PATH=/opt/swift-root/usr/bin:$PATH        # Linux session toolchain (Swift 6.2.4)
swift build
swift test --parallel                             # all portable tests (203 at 3b105a5)
swift test --filter PersistenceTests              # one module
swift build --scratch-path .build-<name> --target <Target>   # private scratch path per agent
swift test  --scratch-path .build-<name> --filter <TargetTests>
Scripts/test-linux.sh
Scripts/generate-fixtures.sh
# macOS with Xcode 16+ only:
Scripts/build-ios.sh                               # xcodegen + simulator build/test
Scripts/archive-ios.sh                             # unsigned archive
```

## Blockers

- **No Mac, no Xcode, no iOS SDK, no simulator in this session.** Code under
  `App/` cannot be compiled here; it is written against public APIs and compiled
  only by CI job `app-ios-simulator` (`.github/workflows/courseleaf.yml`), which is
  the sole Xcode compile evidence. Check the latest Actions run before claiming
  the app builds; no run has been inspected from this session.
- **No physical iPad/Pencil.** Every `device` row in `docs/VALIDATION.md` and all
  performance targets stay pending until someone runs them on hardware.
- **Account-owner decisions outstanding:** public name, bundle ID, team/signing,
  pricing mode and baseline iPad model (`docs/RELEASE_CHECKLIST.md` #2–#5, #15).

## Next actions

1. Land `Sources/Workspace` (`LibraryService`, `DocumentSession`) with
   `WorkspaceTests` that drive Persistence + Catalog + Archive end to end
   (import → edit → save → search → backup → restore); rerun `swift test` and add
   the result line and commit to `docs/VALIDATION.md`.
2. Land the `App/` screens against `Sources/Workspace/WorkspaceAPI.swift` and push
   so CI produces the first simulator compile evidence; add `CourseleafTests` for
   A05 (real PDF export read back with PDFKit), A06 (`PKCanvasView` count on
   `Fixtures/long-300-mixed.pdf`) and A10 (PencilKit mask preservation).
3. Move `docs/FEATURE_REGISTER.md` rows from `in progress` only when the app part
   exists and the evidence is recorded; update the Counts section and this file.
4. When a Mac and iPad are available: run the G0 harness checks first, then the
   `device` rows (A01–A03, A07, A08, A16, A17, A19) and the performance table.
5. Release prep (`docs/RELEASE_CHECKLIST.md`): icon, onboarding, privacy manifest
   audit, screenshots from the implemented app, then the owner steps.

## Decisions that need the owner

- Public name and bundle identifier.
- Whether a one-time local unlock ships (and what it gates), or the app is free/paid.
- Baseline iPad model for performance measurements.
