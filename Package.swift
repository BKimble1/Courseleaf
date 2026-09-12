// swift-tools-version: 5.10
// Courseleaf core package. Platform-independent document, storage, archive,
// catalog, geometry and editing logic. Builds and tests on Linux and Apple
// platforms; the iPad app in App/ depends on it through App/project.yml.
import PackageDescription

let package = Package(
    name: "CourseleafCore",
    platforms: [
        .iOS("18.0"),
        .macOS("14.0"),
    ],
    products: [
        .library(name: "DocumentCore", targets: ["DocumentCore"]),
        .library(name: "PageGeometry", targets: ["PageGeometry"]),
        .library(name: "Editing", targets: ["Editing"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Archive", targets: ["Archive"]),
        .library(name: "Catalog", targets: ["Catalog"]),
        .library(name: "Fixtures", targets: ["Fixtures"]),
        .library(name: "Workspace", targets: ["Workspace"]),
        .executable(name: "fixturegen", targets: ["FixtureGen"]),
    ],
    targets: [
        // Model types, identifiers, geometry primitives, hashing, ink abstraction, shared service types.
        .target(name: "DocumentCore"),
        // PDF page boxes, rotation, page <-> canvas <-> export transforms, paper template geometry.
        .target(name: "PageGeometry", dependencies: ["DocumentCore"]),
        // In-memory document editing: commands, undo grouping, selection, Problem Pages, review rules.
        .target(name: "Editing", dependencies: ["DocumentCore", "PageGeometry"]),
        // Managed library and document packages on disk: atomic commits, revisions, trash, recovery, GC.
        .target(name: "Persistence", dependencies: ["DocumentCore"]),
        // Native archive container (.courseleaf) export/import with validation. Depends only on the model;
        // Workspace wires it to Persistence.
        .target(name: "Archive", dependencies: ["DocumentCore"]),
        // Platform SQLite exposed to Swift. A plain C target (not `.systemLibrary`)
        // because Xcode's local-package integration does not create a build target
        // for system libraries, which breaks the iOS app build. The header ships in
        // the Apple SDKs and in libsqlite3-dev on Linux; the library is linked below.
        .target(name: "CSQLite", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Rebuildable SQLite catalog and full-text search index; review queue queries.
        .target(name: "Catalog", dependencies: ["DocumentCore", "CSQLite"]),
        // Deterministic fixtures: minimal PDF writer/inspector, image header inspector, dense ink, malformed inputs.
        .target(name: "Fixtures", dependencies: ["DocumentCore", "PageGeometry"]),
        // App-facing façade: library service, document sessions (editor + save scheduling + indexing),
        // import/export/backup coordination, search and review queue services.
        .target(name: "Workspace", dependencies: ["DocumentCore", "PageGeometry", "Editing", "Persistence", "Archive", "Catalog"]),
        // Command-line fixture generator (writes Fixtures/).
        .executableTarget(name: "FixtureGen", dependencies: ["Fixtures"]),

        .testTarget(name: "DocumentCoreTests", dependencies: ["DocumentCore"]),
        .testTarget(name: "PageGeometryTests", dependencies: ["PageGeometry", "Fixtures"]),
        .testTarget(name: "EditingTests", dependencies: ["Editing", "Fixtures"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Fixtures"]),
        .testTarget(name: "ArchiveTests", dependencies: ["Archive", "Fixtures"]),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog", "Fixtures"]),
        .testTarget(name: "FixturesTests", dependencies: ["Fixtures"]),
        .testTarget(name: "WorkspaceTests", dependencies: ["Workspace", "Fixtures"]),
    ],
    swiftLanguageVersions: [.v5]
)
