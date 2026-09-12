# Next session

Resume point for the Courseleaf build. Update this file before ending a session or
when context is nearly exhausted; keep it short and exact.

## State (2026-09-12)

- **Repository:** `BKimble1/QuickWrite` (`/home/user/quickwrite` in the remote
  session), branch `main`. The app lives here, not in Project-Jarvis.
- **Last commit on main:** `2de9721` "Complete the iPad app: editor coordinator,
  library, review, search, export and settings".
- **Verified on Linux (session and CI):** `swift test --parallel` →
  `Executed 219 tests, with 0 failures`. The CI `core-linux` job has passed on
  every pushed commit. Fixtures regenerate byte-identically.
- **Verified with the Apple toolchain (CI, Xcode 26.3, iOS 26.2 SDK):** the whole
  core package compiles for macOS and every module compiles for
  `arm64-apple-ios-simulator`.
- **Not yet verified:** the app target has not finished compiling for the
  simulator, so none of the 58 simulator test functions under
  `App/CourseleafTests` has ever run. There is no physical iPad or Apple Pencil
  in this environment, so G0's device evidence gate and every `device` row in
  `docs/VALIDATION.md` remain open.
- **Working tree:** clean at `2de9721` apart from documentation updates in
  progress. Nothing is stashed.
- **Active gate:** G5 verification of what is already built. G1–G4 code exists for
  launch scope; G6 material is drafted (`docs/RELEASE_CHECKLIST.md`,
  `docs/APP_STORE_METADATA_DRAFT.md`, `docs/PRIVACY_POLICY_DRAFT.md`) but no
  archive has been produced.
- **Last genuinely verified gate:** none end to end. The portable document engine
  (storage, archive, catalog, geometry, editing, workspace) is unit-tested; the
  iPad app is written and partly compiled but unproven.

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

1. Read the newest `app-ios-simulator` job log (it now prints a deduplicated
   `error:` list and repeats it in the job summary) and fix the app-target
   compile errors until the simulator build succeeds.
2. Get `CourseleafTests` running on an iPad simulator and record the result in
   `docs/VALIDATION.md`; move the `sim` rows off `pending` only for tests that
   actually passed.
3. Write the remaining interchange test that is still missing: OCR evaluation
   (A15) with a character and word error-rate table. The export alignment, tape
   policy and text-searchability tests now exist in
   `App/CourseleafTests/InterchangeExportTests.swift` but have not run.
4. On a Mac with a physical iPad and Apple Pencil, run the G0 feasibility checks
   and the A02/A03/A06/A19 device gates, and record hardware, OS build and method.
5. Only then: `Scripts/archive-ios.sh`, the release checklist, and the
   account-dependent steps the owner must perform.

## Decisions that need the owner

- Public name and bundle identifier.
- Whether a one-time local unlock ships (and what it gates), or the app is free/paid.
- Baseline iPad model for performance measurements.
