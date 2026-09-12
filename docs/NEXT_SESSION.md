# Next session

Resume point for the Courseleaf build. Update this file before ending a session or
when context is nearly exhausted; keep it short and exact.

## State (2026-09-12)

- **Repository:** `BKimble1/QuickWrite` (`/home/user/quickwrite` in the remote
  session), branch `main`. The app lives here, not in Project-Jarvis.
- **Last commit on main:** `7627793`.
- **Linux:** `swift test --parallel` → `Executed 219 tests, with 0 failures`.
  Green in CI (`core-linux`) on every pushed commit. Fixtures regenerate
  byte-identically.
- **iPad simulator (CI `app-ios-simulator`, Xcode 26.3, iOS 26.2):** the app
  builds and `CourseleafTests` runs — **63 tests, 0 failures** at `7627793`
  (run 34694155083). This covers the PencilKit ink engine, page layout and
  pooling, tool state, in-notebook search, the app shell and library view model,
  the PDF/image inspectors, PDF export alignment and tape policy, and the OCR
  evaluation.
- **Device: still nothing.** There is no physical iPad or Apple Pencil in this
  environment. G0's device gate and A02, A03, A06, A16, A17 and A19 are open.
- **Harness trust:** the simulator job fails if zero tests run, after two
  false-green defects were found and fixed (see `docs/VALIDATION.md`). Treat a
  green job as meaningful only because of that guard.
- **Active gate:** G5. G1–G4 code exists for launch scope and is now exercised on
  both Linux and the simulator. G6 material is drafted; no archive exists.

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

1. Update `docs/FEATURE_REGISTER.md`: 47 rows still say "in progress" with
   evidence text claiming the Workspace facade and App screens are unwritten.
   They exist, compile and are tested. Re-assign each row honestly against the
   legend, naming the test that earns the status.
2. Broaden the simulator suite where a launch claim has no test yet: mixed
   selection undo through the editor (A09 end to end), the 300-page document
   opening with at most three live canvases (A06 at simulator level), and a
   native archive round trip driven through `LibraryService`.
3. On a Mac with a physical iPad and Apple Pencil: the G0 feasibility checks and
   the A02, A03, A06, A16, A17 and A19 device gates, recording hardware, OS
   build, fixture and method.
4. Only then `Scripts/archive-ios.sh`, the release checklist, and the
   account-dependent steps the owner must perform.

## Decisions that need the owner

- Public name and bundle identifier.
- Whether a one-time local unlock ships (and what it gates), or the app is free/paid.
- Baseline iPad model for performance measurements.
