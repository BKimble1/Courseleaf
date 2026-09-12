# Release checklist

Remaining steps between the current repository state and an App Store submission.
**Owner** is `developer` (can be done in a coding session, with a Mac where noted)
or `account owner` (needs the Apple Developer account, App Store Connect, a signing
identity or a product decision). Nothing here authorizes a public submission; the
account owner takes the final step explicitly.

Status values: `not started`, `in progress`, `ready` (developer work done, waiting
on an owner step), `done`, `blocked (reason)`.

| # | Step | Owner | Status | Notes |
|---|---|---|---|---|
| 1 | Finish and verify launch gates G0–G6 (`docs/FEATURE_REGISTER.md`, `docs/VALIDATION.md` A01–A20) | developer | in progress | At `3b105a5` the core package passes 203 portable tests; Workspace and every `App/` screen are unwritten. Device gates A02, A03, A16 (no Pencil), A17, A19 need a physical iPad |
| 2 | Choose the public product name (Courseleaf is a codename) and check trademark/App Store name availability | account owner | not started | Name feeds `CFBundleDisplayName`, metadata, support page and privacy policy |
| 3 | Bundle identifier and exported type identifier | account owner | not started | Placeholders `dev.courseleaf.app`, `dev.courseleaf.archive` in `App/project.yml`; change together and update the `.courseleaf` UTI if the name changes |
| 4 | Team ID and signing (Automatic signing, distribution certificate, provisioning) | account owner | not started | `DEVELOPMENT_TEAM` is empty in `App/project.yml`; never invented by the developer |
| 5 | App Store Connect app record (name, primary language, SKU, bundle ID) | account owner | not started | Requires steps 2–4 |
| 6 | App privacy answers in App Store Connect | account owner (from developer draft) | ready when 1 is done | Draft answer: **Data Not Collected**. No analytics, no accounts, no network. Re-verify against the final build's frameworks before answering |
| 7 | Privacy manifest / required-reason APIs check | developer | not started | Audit the final build for required-reason API use (file timestamps, disk space, user defaults, system boot time). `StorageReport.availableBytes` uses disk-space APIs: declare the reason in `PrivacyInfo.xcprivacy`. Confirm no third-party SDKs |
| 8 | Privacy policy published at a real URL | account owner | not started | Text: `docs/PRIVACY_POLICY_DRAFT.md`; fill the contact placeholder |
| 9 | Support URL published | account owner | not started | Text: `docs/SUPPORT_DRAFT.md` |
| 10 | Original app icon, accent colour, launch screen, covers | developer | not started | Original artwork only; `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` expects the asset catalog in `App/Courseleaf/Resources` |
| 11 | Onboarding (first-run: paper choice, Pencil-only setting, how to file quick notes) | developer | not started | Must not present unfinished features |
| 12 | Screenshots from the implemented app (12.9" and 11" iPad, portrait and landscape) | developer (Mac + simulator or device) | blocked (no Mac in session) | Only real screens; no mock-ups |
| 13 | App Store metadata (description, keywords, subtitle, what's new, category, age rating) | account owner (from developer draft) | ready when 1 is done | Draft: `docs/APP_STORE_METADATA_DRAFT.md`; no unimplemented claims |
| 14 | Review notes for App Review (how to test import, review queue, no login) | developer | not started | Include a sample PDF and the steps in `APP_STORE_METADATA_DRAFT.md` |
| 15 | Pricing decision: free, paid, or optional local unlock | account owner | not started | See `PRODUCT_SPEC.md` §5. If nothing is configured, no purchase UI ships |
| 16 | StoreKit product creation and localized pricing (only if the unlock ships) | account owner | not started | Non-consumable product ID; matching `.storekit` test configuration stays out of production |
| 17 | Purchase verification on device (A18: success, cancel, pending, revoked, offline, restore) | developer + account owner (sandbox tester) | blocked (depends on 15–16) | Skipped entirely if no product ships |
| 18 | Export compliance | account owner | ready | `ITSAppUsesNonExemptEncryption = false` already set; no custom encryption |
| 19 | Third-party licences | developer | done (none) | No third-party packages; system SQLite and Apple frameworks only. Re-check if a dependency is added |
| 20 | Device validation gate: long writing session, lecture annotation, export, backup/restore, permission denials, low disk (A19) | developer with iPad + Pencil | blocked (no iPad in session) | Record device, OS, commit and metrics in `docs/VALIDATION.md` |
| 21 | Release build: `Scripts/archive-ios.sh` (unsigned archive) then a signed archive with the owner's team in Xcode | developer (Mac) then account owner | blocked (no Mac in session) | Record `xcodebuild -version`, SDK and the source commit in `VALIDATION.md` |
| 22 | Upload to App Store Connect, TestFlight round, submit for review | account owner | not started | Explicit authorization required; do not submit from a coding session |
| 23 | Post-submission: tag the commit, archive the `.xcarchive` and dSYMs, update `docs/NEXT_SESSION.md` | developer | not started | |
| 24 | CI green on the release commit: `core-linux` and `app-ios-simulator` (`.github/workflows/courseleaf.yml`) | developer | not started | `core-linux` equivalent passes locally at `3b105a5`; `app-ios-simulator` cannot pass until `App/` screens exist. Record both run URLs in `VALIDATION.md` A20; no CI run has been inspected from this session |

## Definition of "ready to submit"

All of: every A01–A20 row in `docs/VALIDATION.md` is `passed` or has an accepted,
documented limitation; no open data-loss defect; screenshots and metadata come from
the shipped build; privacy answers match the final binary; the signed archive was
built from a tagged commit.
