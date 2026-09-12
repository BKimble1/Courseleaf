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
| 3 | Bundle identifier and exported type identifier | account owner | done | `com.idlery.courseleaf` (app), `com.idlery.courseleaf.tests` (test bundle), `com.idlery.courseleaf.archive` (exported UTI, extension `.courseleaf`). Set together in `App/project.yml` and the four Swift constants that must agree with it |
| 4 | Team ID and signing (Automatic signing, distribution certificate, provisioning) | account owner | ready | `DEVELOPMENT_TEAM = 7GNFT94A9L` in `App/project.yml` and `Scripts/export-options.plist`. Signing style is automatic; `Scripts/release-ios.sh` passes the App Store Connect API key to `-allowProvisioningUpdates` so Xcode fetches (or creates) the distribution certificate and App Store profile on the runner. Waiting on the repository secrets below |
| 5 | App Store Connect app record (name, primary language, SKU, bundle ID) | account owner | done (per owner) | Courseleaf, SKU `courseleaf-ios-001`, Apple ID `6811381700`. `Scripts/asc.py verify-app` checks the record against these identifiers on every release run and **never creates one** |
| 6 | App privacy answers in App Store Connect | account owner (from developer draft) | ready when 1 is done | Draft answer: **Data Not Collected**. No analytics, no accounts, no network. Re-verify against the final build's frameworks before answering |
| 7 | Privacy manifest / required-reason APIs check | developer | not started | Audit the final build for required-reason API use (file timestamps, disk space, user defaults, system boot time). `StorageReport.availableBytes` uses disk-space APIs: declare the reason in `PrivacyInfo.xcprivacy`. Confirm no third-party SDKs |
| 8 | Privacy policy published at a real URL | account owner | not started | Text: `docs/PRIVACY_POLICY_DRAFT.md`; fill the contact placeholder |
| 9 | Support URL published | account owner | not started | Text: `docs/SUPPORT_DRAFT.md` |
| 10 | Original app icon, accent colour, launch screen, covers | developer | in progress | App icon done: the owner's artwork lives at `Design/app-icon-source.png`; `Scripts/install-appicon.py` normalizes it into `AppIcon.appiconset` as an opaque 1024×1024 RGB PNG with no alpha and square corners (iOS applies the mask). Re-run the script after changing the source. Accent colour, launch screen and covers still to do |
| 11 | Onboarding (first-run: paper choice, Pencil-only setting, how to file quick notes) | developer | not started | Must not present unfinished features |
| 12 | Screenshots from the implemented app (12.9" and 11" iPad, portrait and landscape) | developer (Mac + simulator or device) | blocked (no Mac in session) | Only real screens; no mock-ups |
| 13 | App Store metadata (description, keywords, subtitle, what's new, category, age rating) | account owner (from developer draft) | ready when 1 is done | Draft: `docs/APP_STORE_METADATA_DRAFT.md`; no unimplemented claims |
| 14 | Review notes for App Review (how to test import, review queue, no login) | developer | not started | Include a sample PDF and the steps in `APP_STORE_METADATA_DRAFT.md` |
| 15 | Pricing decision: free, paid, or optional local unlock | account owner | not started | See `PRODUCT_SPEC.md` §5. If nothing is configured, no purchase UI ships |
| 16 | StoreKit product creation and localized pricing (only if the unlock ships) | account owner | not started | Non-consumable product ID; matching `.storekit` test configuration stays out of production |
| 17 | Purchase verification on device (A18: success, cancel, pending, revoked, offline, restore) | developer + account owner (sandbox tester) | blocked (depends on 15–16) | Skipped entirely if no product ships |
| 18 | Export compliance | developer | done | `ITSAppUsesNonExemptEncryption = false`, asserted in the archive and the IPA by `Scripts/bundle-checks.sh`. Determined from the code, not assumed: the app opens no network connections, and its only `CryptoKit` use is `SHA256` over asset bytes in `EditorAssets.swift` — a digest, not a cipher. The remaining "encrypted" matches in the tree are about *rejecting* encrypted PDFs and ZIP entries. No `SecKey`, `AES`, `CommonCrypto` or TLS of its own; only Apple's OS-level encryption applies, which is exempt |
| 19 | Third-party licences | developer | done (none) | No third-party packages; system SQLite and Apple frameworks only. Re-check if a dependency is added |
| 20 | Device validation gate: long writing session, lecture annotation, export, backup/restore, permission denials, low disk (A19) | developer with iPad + Pencil | blocked (no iPad in session) | Record device, OS, commit and metrics in `docs/VALIDATION.md` |
| 21 | Release build: signed Release archive for a device | developer | ready | `Scripts/release-ios.sh` archives `generic/platform=iOS` (never a simulator), then `Scripts/inspect-archive.sh` and `Scripts/inspect-ipa.sh` assert bundle ID, version, build number, `DTPlatformName = iphoneos`, device family, icon, permission strings, export compliance, distribution certificate, team, `get-task-allow`, and an App Store provisioning profile. Runs in the `TestFlight` workflow; blocked only on the secrets below |
| 22 | Upload to TestFlight internal testing | developer (authorized) | ready | `.github/workflows/testflight.yml`, manual dispatch. Uploads, waits for processing to reach `VALID`, adds the build to the **Personal Testing** internal group. **Submitting for public App Store review is a separate, explicit action in App Store Connect and is not automated here** |
| 23 | Post-submission: tag the commit, archive the `.xcarchive` and dSYMs, update `docs/NEXT_SESSION.md` | developer | not started | |
| 24 | CI green on the release commit: `core-linux` and `app-ios-simulator` (`.github/workflows/courseleaf.yml`) | developer | not started | `core-linux` equivalent passes locally at `3b105a5`; `app-ios-simulator` cannot pass until `App/` screens exist. Record both run URLs in `VALIDATION.md` A20; no CI run has been inspected from this session |

## Definition of "ready to submit"

All of: every A01–A20 row in `docs/VALIDATION.md` is `passed` or has an accepted,
documented limitation; no open data-loss defect; screenshots and metadata come from
the shipped build; privacy answers match the final binary; the signed archive was
built from a tagged commit.


## Supplying the signing credentials

The release pipeline runs on a GitHub Actions macOS runner, because that is the
only machine in this project with an Apple SDK. It needs three repository
secrets. Add them at **Settings → Secrets and variables → Actions → New
repository secret**; a coding session cannot write them, and should not.

| Secret name | Value | Encoding |
|---|---|---|
| `ASC_KEY_ID` | The App Store Connect API key ID (10 characters) | raw text |
| `ASC_ISSUER_ID` | The issuer ID (a UUID) from Users and Access → Integrations → App Store Connect API | raw text |
| `ASC_PRIVATE_KEY_BASE64` | The `AuthKey_<KEYID>.p8` file's contents | **base64 of the whole file** |

Produce the third value without opening the key or pasting it anywhere but the
secret field:

```sh
base64 -i ~/Downloads/AuthKey_<KEYID>.p8 | pbcopy   # macOS
base64 -w0 AuthKey_<KEYID>.p8                       # Linux
```

Base64 rather than raw PEM because a secret that must survive newlines exactly
is a secret that eventually does not. The workflow decodes it to
`~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8` with mode 600 — outside the
workspace, so no artifact upload can pick it up — and checks that it decoded to
a PEM private key before using it.

The key's role must be **Admin** or **App Manager**. A Developer-role key can
authenticate but cannot create the distribution certificate or the App Store
provisioning profile, and the archive step will fail on signing rather than on
authentication. API authentication succeeding is not evidence that distribution
signing works.

### If automatic signing cannot issue a certificate

Automatic signing creates a distribution certificate only if the team has a free
slot (the limit is three) and the key has the role above. If the archive fails
with a certificate error, export the existing distribution certificate **and its
private key** from a Mac that already has it (Keychain Access → My Certificates →
select the `Apple Distribution` certificate → Export → `.p12`), then add two more
secrets and set `IMPORT_P12=1` — never revoke the existing certificate to force a
new one, as that invalidates every build signed with it.

| Secret name | Value | Encoding |
|---|---|---|
| `DIST_CERT_P12_BASE64` | The exported `.p12` | base64 of the file |
| `DIST_CERT_P12_PASSWORD` | The password chosen during export | raw text |

## Running a TestFlight build

1. Actions → **TestFlight** → Run workflow.
2. `marketing_version` — the `CFBundleShortVersionString` to ship. The build
   number is chosen by the workflow: it asks App Store Connect for every build
   already uploaded under that version and takes the next unused integer.
3. `dry_run` — build, sign and verify without uploading. Use it the first time
   the credentials are in place, to prove signing works before anything reaches
   App Store Connect.

The run fails, rather than uploading, if: a secret is missing, the app record
does not match `com.idlery.courseleaf` / Apple ID `6811381700`, Xcode or the iOS
SDK is older than Apple accepts, any test fails, zero tests execute, or any
archive or IPA assertion fails.
