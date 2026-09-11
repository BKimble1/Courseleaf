// swift-tools-version: 5.10
// Courseleaf core package. Platform-independent document, storage, archive,
// catalog, geometry and editing logic. Builds and tests on Linux and Apple
// platforms; the iPad app in App/ depends on it through project.yml.
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
    ],
    targets: [
        // Model types, identifiers, geometry primitives, hashing, ink abstraction.
        .target(name: "DocumentCore"),
        // PDF page boxes, rotation, page <-> canvas <-> export transforms, paper templates.
        .target(name: "PageGeometry", dependencies: ["DocumentCore"]),
        // In-memory document editing: commands, undo grouping, selection, Problem Pages, review queue logic.
        .target(name: "Editing", dependencies: ["DocumentCore", "PageGeometry"]),
        // Managed library and document packages on disk: atomic commits, revisions, trash, recovery, GC.
        .target(name: "Persistence", dependencies: ["DocumentCore"]),
        // Native archive container (.courseleaf) export/import with validation; full library backup/restore.
        .target(name: "Archive", dependencies: ["DocumentCore", "Persistence"]),
        // System SQLite (libsqlite3 on Linux, the SDK's sqlite3 on Apple platforms).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3",
                       providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]),
        // Rebuildable SQLite catalog and full-text search index; review queue queries.
        .target(name: "Catalog", dependencies: ["DocumentCore", "Persistence", "CSQLite"]),
        // Deterministic fixtures: minimal PDF writer (rotated pages, CropBox origins, long documents), dense ink.
        .target(name: "Fixtures", dependencies: ["DocumentCore", "PageGeometry"]),

        .testTarget(name: "DocumentCoreTests", dependencies: ["DocumentCore"]),
        .testTarget(name: "PageGeometryTests", dependencies: ["PageGeometry", "Fixtures"]),
        .testTarget(name: "EditingTests", dependencies: ["Editing", "Fixtures"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Fixtures"]),
        .testTarget(name: "ArchiveTests", dependencies: ["Archive", "Persistence", "Fixtures"]),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog", "Persistence", "Fixtures"]),
        .testTarget(name: "FixturesTests", dependencies: ["Fixtures"]),
    ],
    swiftLanguageVersions: [.v5]
)
