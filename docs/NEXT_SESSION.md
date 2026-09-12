# Next session

Resume point for the Courseleaf build. Update this file before ending a session or
when context is nearly exhausted; keep it short and exact.

## State (2026-09-12)

- **Repository:** `BKimble1/Courseleaf` (renamed from `QuickWrite`;
  `/home/user/quickwrite` in the remote session), branch `main`.
- **Last commit on main:** `9d683f4` (CI green: [run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941)).
- **Identity:** app `com.idlery.courseleaf`, tests `com.idlery.courseleaf.tests`,
  exported UTI `com.idlery.courseleaf.archive` (`.courseleaf`), team
  `7GNFT94A9L`, App Store Connect Apple ID `6811381700`, SKU
  `courseleaf-ios-001`. Version 1.0.0; the build number is chosen from App
  Store Connect at release time.
- **Linux:** `swift test --parallel` → 222 tests, 0 failures. Green in CI
  (`core-linux`) on every pushed commit. Fixtures regenerate byte-identically.
- **iPad simulator (CI `app-ios-simulator`, Xcode 26.3, iOS 26.2):**
  **69 tests, 0 failures** at `9d683f4` ([run 34712297941](https://github.com/BKimble1/Courseleaf/actions/runs/34712297941)). Covers the
  PencilKit ink engine, page layout and pooling, tool state, in-notebook and
  library search, the app shell and library view model, the PDF and image
  inspectors, PDF export alignment and tape policy, OCR evaluation, and — new
  — end-to-end undo through the editor view controller, image export, printing
  and the review queue.
- **Device: still nothing.** There is no physical iPad or Apple Pencil in this
  environment. G0's device gate and A02, A03, A06, A16, A17 and A19 are open,
  and every performance target is unmeasured.
- **Harness trust:** both workflows call `Scripts/check-test-results.sh`, which
  fails on a missing bundle, on zero executed tests and on any failure. Two
  false-green defects were found and fixed earlier (`docs/VALIDATION.md`); treat
  a green job as meaningful because of that guard, not despite it.
- **Active gate:** G6. The release path exists end to end but has never run:
  see the blocker below.

## Blockers

1. **The TestFlight workflow needs three repository secrets, which a coding
   session cannot write.** The GitHub Actions secrets API is refused by this
   session's egress proxy ("Access to this GitHub Actions path is not permitted
   through this proxy"), and `api.appstoreconnect.apple.com` is refused at
   CONNECT (403). So every Apple call has to happen on the macOS runner, and the
   owner has to add the secrets. Names, values and encodings are in
   `docs/RELEASE_CHECKLIST.md` → *Supplying the signing credentials*. Nothing
   about the build is waiting on code.
2. **No Mac, no Xcode, no iOS SDK, no simulator in this session.** Code under
   `App/` is compiled only by CI. Check the latest Actions run before claiming
   the app builds.
3. **No physical iPad or Pencil.** Every `device` row in `docs/VALIDATION.md`
   and every performance target stays pending until someone runs them on
   hardware.

## Commands

```bash
export PATH=/opt/swift-root/usr/bin:$PATH        # Linux session toolchain (Swift 6.2.4)
swift build
swift test --parallel                             # all portable tests
swift test --filter PersistenceTests              # one module
Scripts/test-linux.sh
Scripts/generate-fixtures.sh
# macOS with Xcode 16+ only:
Scripts/build-ios.sh                              # xcodegen + simulator build/test
Scripts/check-test-results.sh Build/CourseleafTests.xcresult
Scripts/install-appicon.py                        # icon from Design/app-icon-source.png
# macOS + App Store Connect API key (see RELEASE_CHECKLIST):
Scripts/release-ios.sh                            # signed device archive + IPA + assertions
Scripts/upload-testflight.sh Build/export/Courseleaf.ipa
```

## Next actions

1. Owner: add `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_BASE64`, then run
   the **TestFlight** workflow with `dry_run: true` once to prove distribution
   signing works, and again with `dry_run: false` to upload.
2. Whatever the dry run reports about signing — most likely a missing
   distribution certificate or an API key without the Admin/App Manager role —
   fix per `docs/RELEASE_CHECKLIST.md`, never by revoking an existing
   certificate.
3. On a Mac with a physical iPad and Apple Pencil: the G0 feasibility checks and
   the A02, A03, A06, A16, A17 and A19 device gates, recording hardware, OS
   build, fixture and method in `docs/VALIDATION.md`.
4. Replace the two placeholder links in `App/Courseleaf/Settings/SettingsView.swift`
   (`https://example.invalid/...`) with the real support and privacy URLs before
   any public submission. Harmless for internal testing; a rejection for review.
5. Remaining launch work is in `docs/RELEASE_CHECKLIST.md`: accent colour,
   launch screen, covers, onboarding, screenshots, privacy manifest audit,
   metadata, review notes.

## Decisions that need the owner

- Whether a one-time local unlock ships (and what it gates), or the app is free.
- Baseline iPad model for the performance measurements.
- Public support and privacy URLs.
