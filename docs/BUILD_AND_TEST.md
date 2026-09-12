# Build and test

## Environments

| Environment | What it can verify | Status |
|---|---|---|
| Linux (remote session), Swift 6.2.4 at `/opt/swift-root` | `swift build`, `swift test` for the core package (all persistence, archive, catalog, geometry, editing logic) | available; used for every commit |
| GitHub Actions `ubuntu-24.04` + `swift:6.2-noble` container | same as above, on push | `.github/workflows/courseleaf.yml` job `core-linux` |
| GitHub Actions `macos-15` (Xcode 26.3, iOS 26.2 SDK, iPad simulators) | app compiles; XCTest bundle runs on an iPad simulator (PencilKit/PDFKit/Vision code paths that do not need a real Pencil) | job `app-ios-simulator`; results recorded in `docs/VALIDATION.md` |
| Mac with Xcode + physical iPad/Pencil | latency, palm rejection, Pencil-only input, long writing sessions, archive for App Store | **not available in this session**; explicitly open gate |

Toolchain facts recorded 2026-09-11 (Linux session):

```
$ swift --version
Swift version 6.2.4 (swift-6.2.4-RELEASE)
Target: x86_64-unknown-linux-gnu
$ pkg-config --modversion sqlite3
3.45.1            (FTS5 available)
$ xcodebuild -version
command not found  (no Xcode, no iOS SDK, no simulator on Linux)
```

The Linux toolchain was extracted from the official `swift:6.2-noble`
container image layers (pulled through `mirror.gcr.io` because
`download.swift.org` is not reachable from the session). It is only needed
for local iteration; CI installs its own.

Observed on the CI macOS runner (2026-09-12): Xcode 26.3 (build 17C529),
`-sdk iphonesimulator26.2`, and iPad Pro / Air / mini / base simulators.
The runner selects the newest installed Xcode automatically.

### SQLite

`Sources/CSQLite` is a plain C target with an umbrella header that includes
`<sqlite3.h>`, plus `linkedLibrary("sqlite3")`. It is deliberately **not** a
`.systemLibrary` target: Xcode's local-package integration does not create a
build target for system libraries, so the app build failed with "The workspace
has a reference to a missing target with GUID 'PACKAGE-TARGET:CSQLite'". The
header ships in the Apple SDKs and in `libsqlite3-dev` on Linux.

## Commands

Core package (Linux or macOS):

```bash
swift build
swift test --parallel
swift test --filter PersistenceTests/InterruptedCommitTests
Scripts/test-linux.sh          # build + full test run with a summary
Scripts/generate-fixtures.sh   # regenerate Fixtures/ from the Fixtures module
```

iPad app (macOS, Xcode 16 or newer, XcodeGen 2.40+):

```bash
brew install xcodegen
Scripts/build-ios.sh           # xcodegen generate; build; run CourseleafTests on the first available iPad simulator
Scripts/archive-ios.sh         # xcodebuild archive with signing disabled (unsigned .xcarchive for inspection)
```

`Scripts/build-ios.sh` accepts `DESTINATION='platform=iOS Simulator,name=iPad Pro 13-inch (M4)'`
to pin a simulator; by default it picks the first available iPad.

## Continuous integration

`.github/workflows/courseleaf.yml` runs on every push:

1. `core-linux`: `swift test --parallel` in the `swift:6.2-noble` container.
2. `app-ios-simulator`: prints `xcodebuild -version` and available SDKs and
   simulators, installs XcodeGen, builds the core package with the Apple
   toolchain, generates the project, builds the app for an iPad simulator with
   code signing disabled, runs `CourseleafTests`, and uploads the `.xcresult`
   bundle as an artifact. On failure it prints a deduplicated list of
   `error:` lines from the raw `xcodebuild` log and repeats it in the job
   summary, because `xcbeautify` drops file and line information.

A green `core-linux` job means the portable logic passed. A green
`app-ios-simulator` job means the app compiled with the Apple SDK and the
simulator tests passed. Neither is device evidence.
