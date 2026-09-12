# Next session

Resume point for the Courseleaf build. Update this file before ending a session
or when context is nearly exhausted; keep it short and exact.

## State (2026-09-12, premium-editor release)

- **Repository:** `BKimble1/Courseleaf`. Release work is on
  `claude/courseleaf-premium-editor-uz9wxa`; `main` is the previously shipped
  state.
- **Identity:** app `com.idlery.courseleaf`, tests `com.idlery.courseleaf.tests`,
  UI tests `com.idlery.courseleaf.uitests`, exported UTI
  `com.idlery.courseleaf.archive` (`.courseleaf`), team `7GNFT94A9L`, App Store
  Connect Apple ID `6811381700`, SKU `courseleaf-ios-001`. Version 1.0.0; the
  build number is chosen from App Store Connect at release time.
- **TestFlight has shipped.** Build 1.0.0 (1) reached VALID and was assigned to
  the internal group **Courseleaf Testing Group**. Earlier handoff notes in this
  file said otherwise and were stale; Apple's state and the installed build are
  the authority, not this document.
- **Secrets are in place:** `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_PRIVATE_KEY_BASE64`. The distribution identity is cached under
  `courseleaf-signing-identity-v1` and is **reused, never re-minted** — Apple
  caps a team at three distribution certificates.

## What this release changed

See `docs/FEATURE_COVERAGE.md` for the whole picture and
`docs/VALIDATION.md` → *Premium-editor release* for what is proved and what is
not. In short: stale ink commits, undo boundaries and unreadable-ink handling
were fixed; the toolbar moved to a persistent top row with one-tap colours,
widths and favourites; scribble-to-erase and draw-and-hold shipped behind
settings; search and review deep links now reach a region; review renders the
work. A UI-test target exists and attaches screenshots.

## Standing constraints

1. **No Mac, no Xcode, no iOS SDK in a coding session.** Everything under `App/`
   is compiled only by CI. Check the latest Actions run before claiming the app
   builds. A local Swift toolchain is also unavailable: `download.swift.org` and
   both container registries' blob hosts are blocked by the session's egress
   proxy, so even the portable package is compiled only by CI.
2. **No physical iPad or Apple Pencil.** Every `device` row in
   `docs/VALIDATION.md` and every performance target stays pending. The
   checklist to hand someone who has one is `docs/DEVICE_CHECKLIST.md`.
3. **Harness trust.** Both jobs now guard themselves: the macOS job through
   `Scripts/check-test-results.sh`, the Linux job through `swift test`'s xUnit
   report. A green job means something *because* of those guards — three
   false-green defects have been found in this project's own harness, all
   recorded in `docs/VALIDATION.md`.

## Commands

```bash
swift build && swift test --parallel          # only where a Swift toolchain exists
Scripts/test-linux.sh
Scripts/generate-fixtures.sh
# macOS with Xcode 16+ only:
Scripts/build-ios.sh                          # xcodegen + simulator build/test (unit + UI)
Scripts/check-test-results.sh Build/CourseleafTests.xcresult
# macOS + App Store Connect API key:
Scripts/release-ios.sh
Scripts/upload-testflight.sh Build/export/Courseleaf.ipa
python3 Scripts/asc.py set-notes --build-id <id> --file docs/release/WHAT_TO_TEST.md
```

Release: run the **TestFlight** workflow (`workflow_dispatch`) with
`marketing_version: 1.0.0`. `dry_run: true` builds and signs without uploading;
`dry_run: false` uploads, waits for VALID, sets What to Test, and assigns the
build to the internal group. If an upload succeeds but assignment fails, use
**TestFlight assignment** (`testflight-assign.yml`) — it talks only to App Store
Connect, builds nothing, and cannot change what shipped. Never rebuild to retry
an assignment.

## Next actions

1. **Run `docs/DEVICE_CHECKLIST.md` on a real iPad.** This is the largest gap by
   far, and the two new gestures are the part most likely to be wrong in the
   hand rather than on paper.
2. Measure the three performance workloads named in `docs/VALIDATION.md`
   (dense page, image-heavy notebook, 300-page PDF) on that iPad and record
   hardware, OS build, fixture and method.
3. From `docs/FEATURE_COVERAGE.md`, the P1 items closest to daily use: a
   persistent thumbnail sidebar instead of a modal for page operations; Files
   "Open in" and drag-and-drop; export cancellation and temporary-file cleanup;
   handwriting conversion as a command, not just as a search index.
4. Before any public submission: real support and privacy URLs. Settings now
   says plainly that both are unpublished rather than linking to
   `example.invalid`, which is honest but not shippable to the App Store.

## Decisions that need the owner

- Whether a one-time local unlock ships (and what it gates), or the app is free.
- Baseline iPad model for the performance measurements.
- Public support and privacy URLs.
- Whether scribble-to-erase should default to on once it has been used on
  hardware. It ships off.
