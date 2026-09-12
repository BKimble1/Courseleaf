# Next session

Resume point for the Courseleaf build. Update this file before ending a session or
when context is nearly exhausted; keep it short and exact.

## State (2026-09-12)

- **Repository:** `quickwrite` (`/home/user/quickwrite` in the remote session), branch `main`.
- **Last commit on main:** `3414e27` "Use the iOS destination in the XcodeGen spec…".
- **Uncommitted work:** the launch modules are being written in parallel by
  module agents (Persistence, Archive, Catalog, PageGeometry, Editing, Workspace,
  Fixtures) plus these docs; the orchestrator commits. Do not discard untracked
  files under `Sources/`, `Tests/`, `Fixtures/` or `docs/`.
- **Active gate:** G1 (storage and notebook core) and G2 (editor) in progress; G0
  (feasibility harness on a physical iPad) is **open** because no device is
  available in this environment. Portable logic is being built ahead of the
  device gate on the documented architecture.
- **Last genuinely verified gate:** none. No `docs/VALIDATION.md` row has evidence.

## Commands

```bash
export PATH=/opt/swift-root/usr/bin:$PATH        # Linux session toolchain (Swift 6.2.4)
swift build
swift test --parallel                             # all portable tests
swift test --filter PersistenceTests              # one module
swift build --scratch-path .build-<name> --target <Target>   # private scratch path per agent
Scripts/test-linux.sh
Scripts/generate-fixtures.sh
# macOS with Xcode 16+ only:
Scripts/build-ios.sh                               # xcodegen + simulator build/test
Scripts/archive-ios.sh                             # unsigned archive
```

## Blockers

- **No Mac, no Xcode, no iOS SDK, no simulator in this session.** App code under
  `App/` cannot be compiled here; it is written against public APIs and compiled by
  CI job `app-ios-simulator` (`.github/workflows/courseleaf.yml`), which is the only
  Xcode compile evidence. Check the latest run before claiming the app builds.
- **No physical iPad/Pencil.** Every `device` row in `docs/VALIDATION.md` and the
  performance targets stay pending until someone runs them on hardware.
- **Account-owner decisions outstanding:** public name, bundle ID, team/signing,
  pricing mode (`docs/RELEASE_CHECKLIST.md` #2–#5, #15).

## Next actions

1. Land the parallel module work; run `swift test --parallel`; record the result
   line and commit in `docs/VALIDATION.md` → Portable test runs.
2. Write `EditingTests` (grouped undo A09, page operations A11, review rules) and
   `WorkspaceTests` for `LibraryService`/`DocumentSession` end to end.
3. Implement `App/` screens against `Sources/Workspace/WorkspaceAPI.swift` and push
   so CI produces the first simulator compile evidence; add `CourseleafTests` for
   A05 (real PDF export), A06 (canvas count) and A10 (PencilKit masks).
4. Move `docs/FEATURE_REGISTER.md` statuses from `in progress` only with evidence.
5. When a Mac and iPad are available: run G0 harness checks, then the device rows.

## Decisions that need the owner

- Public name and bundle identifier.
- Whether a one-time local unlock ships (and what it gates), or the app is free/paid.
- Baseline iPad model for performance measurements.
