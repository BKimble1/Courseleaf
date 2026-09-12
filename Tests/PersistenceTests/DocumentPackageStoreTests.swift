import XCTest
import DocumentCore
@testable import Persistence

final class DocumentPackageStoreTests: XCTestCase {
    let now = Support.now

    // MARK: A01 create, commit, reopen

    func testCreateCommitReopenRoundTripsAndWritesOnlyChangedPages() async throws {
        let dir = try tempDirectory()
        let packageURL = dir.appendingPathComponent("doc.courseleafdoc")
        let (snapshot, assets) = Support.makeSnapshot()
        let clock = ManualClock(start: now)
        let fs = FaultInjectingFileSystem()
        let store = DocumentPackageStore(packageURL: packageURL, fileSystem: fs, clock: clock)
        let receipt = try await store.create(snapshot: snapshot, assets: assets)
        XCTAssertFalse(receipt.isNoOp)
        XCTAssertEqual(Set(receipt.pagesWritten), Set(snapshot.document.pageIDs))
        XCTAssertEqual(Set(receipt.assetsWritten), Set(assets.map(\.asset.id)))

        // Files on disk follow docs/FORMAT.md.
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.lkg.json").path))
        XCTAssertEqual(Support.files(in: packageURL.appendingPathComponent("pages")).count, 3)
        for pending in assets {
            let url = packageURL.appendingPathComponent(pending.asset.relativePath)
            XCTAssertEqual(try Data(contentsOf: url), pending.data, pending.asset.relativePath)
        }
        let manifestText = String(decoding: try Data(contentsOf: packageURL.appendingPathComponent("manifest.json")), as: UTF8.self)
        XCTAssertTrue(manifestText.contains("\"formatVersion\" : 1"))
        XCTAssertTrue(manifestText.contains("\"pageFiles\""))
        XCTAssertTrue(manifestText.contains("\"pages/\(snapshot.document.pageIDs[0])-"))

        // Reopen equals the committed snapshot exactly (revision assigned by the store included).
        let (_, opened) = try await DocumentPackageStore.open(packageURL, clock: clock)
        XCTAssertEqual(opened.snapshot, receipt.snapshot)
        XCTAssertEqual(opened.report.manifestSource, .manifest)
        XCTAssertTrue(opened.report.isClean, "\(opened.report)")
        XCTAssertEqual(opened.snapshot.pages[snapshot.document.pageIDs[0]]?.objects.first?.content, .text(TextContent(text: "Newton's second law")))

        // A second commit touching one page writes only that page and never rewrites an existing asset.
        fs.resetCounters()
        var edited = receipt.snapshot
        var changes = Support.editPage(&edited, index: 1, text: "F = ma")
        changes.newAssets = assets   // same digests offered again
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: packageURL.appendingPathComponent(assets[0].asset.relativePath).path)[.systemFileNumber] as? UInt64
        let receipt2 = try await store.commit(snapshot: edited, changes: changes)
        XCTAssertEqual(receipt2.pagesWritten, [snapshot.document.pageIDs[1]])
        XCTAssertEqual(Set(receipt2.assetsReused), Set(assets.map(\.asset.id)))
        XCTAssertTrue(receipt2.assetsWritten.isEmpty)
        XCTAssertEqual(Support.files(in: packageURL.appendingPathComponent("pages")).count, 4)
        let writes = fs.mutatingOperations.filter { $0.kind == .write || $0.kind == .replaceItem }
        XCTAssertFalse(writes.contains { $0.path.contains("/assets/") }, "assets were rewritten: \(writes)")
        XCTAssertEqual(writes.filter { $0.kind == .replaceItem && $0.path.contains("/pages/") }.count, 1)
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: packageURL.appendingPathComponent(assets[0].asset.relativePath).path)[.systemFileNumber] as? UInt64
        XCTAssertEqual(inodeBefore, inodeAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.lkg.json").path))
        XCTAssertEqual(receipt2.snapshot.headRevision?.parentIDs, [receipt.revisionID])

        // Commit order: assets -> pages -> revision -> manifest (tmp) -> lkg -> rename -> directory sync.
        let ops = fs.mutatingOperations
        let pageWrite = ops.firstIndex { $0.kind == .replaceItem && $0.path.contains("/pages/") }!
        let revisionWrite = ops.firstIndex { $0.kind == .replaceItem && $0.path.contains("/revisions/") }!
        let lkg = ops.firstIndex { $0.kind == .replaceItem && $0.path.hasSuffix("manifest.lkg.json") }!
        let rename = ops.firstIndex { $0.kind == .replaceItem && $0.path.hasSuffix("/manifest.json") }!
        let sync = ops.lastIndex { $0.kind == .syncDirectory }!
        XCTAssertLessThan(pageWrite, revisionWrite)
        XCTAssertLessThan(revisionWrite, lkg)
        XCTAssertLessThan(lkg, rename)
        XCTAssertLessThan(rename, sync)
        XCTAssertEqual(sync, ops.count - 1)

        let (_, reopened) = try await DocumentPackageStore.open(packageURL, clock: clock)
        XCTAssertEqual(reopened.snapshot, receipt2.snapshot)
        XCTAssertEqual(reopened.snapshot.revisions.count, 3)   // Created + create commit + edit
        let imageData = try await store.assetData(assets[1].asset.id)
        XCTAssertEqual(imageData, assets[1].data)
        let imageURL = await store.assetURL(assets[1].asset.id)
        XCTAssertEqual(imageURL?.lastPathComponent, "\(assets[1].asset.sha256).png")
        let unknownData = try await store.assetData(AssetID())
        XCTAssertNil(unknownData)
    }

    func testNoOpCommitWritesNothing() async throws {
        let dir = try tempDirectory()
        let (snapshot, assets) = Support.makeSnapshot()
        let fs = FaultInjectingFileSystem()
        let store = DocumentPackageStore(packageURL: dir.appendingPathComponent("d.courseleafdoc"), fileSystem: fs, clock: ManualClock(start: now))
        let receipt = try await store.create(snapshot: snapshot, assets: assets)
        fs.resetCounters()
        let again = try await store.commit(snapshot: receipt.snapshot, changes: .empty)
        XCTAssertTrue(again.isNoOp)
        XCTAssertEqual(fs.mutatingOperationCount, 0)
        XCTAssertEqual(again.snapshot, receipt.snapshot)
    }

    func testCommitRefusesInconsistentSnapshotAndBadAssetDigest() async throws {
        let dir = try tempDirectory()
        let (snapshot, assets) = Support.makeSnapshot()
        let store = DocumentPackageStore(packageURL: dir.appendingPathComponent("d.courseleafdoc"), clock: ManualClock(start: now))
        let receipt = try await store.create(snapshot: snapshot, assets: assets)
        var broken = receipt.snapshot
        broken.document.pageIDs.append(PageID())
        do { _ = try await store.commit(snapshot: broken, changes: ChangeSet(documentChanged: true)); XCTFail("expected failure") }
        catch let error as PersistenceError { if case .invalidSnapshot = error {} else { XCTFail("\(error)") } }
        var lying = PendingAsset.make(data: Data("x".utf8), mediaType: .png, now: now)
        lying.asset.sha256 = String(repeating: "0", count: 64)
        do { _ = try await store.commit(snapshot: receipt.snapshot, changes: ChangeSet(newAssets: [lying])); XCTFail("expected failure") }
        catch let error as PersistenceError { if case .assetDigestMismatch = error {} else { XCTFail("\(error)") } }
        let (_, reopened) = try await DocumentPackageStore.open(store.packageURL)
        XCTAssertEqual(reopened.snapshot, receipt.snapshot)
    }

    // MARK: A07 / A08 fault injection

    /// Builds a fresh package in pre-commit state and returns the edit to apply.
    private func prepareScenario() async throws -> (packageURL: URL, pre: DocumentSnapshot, edited: DocumentSnapshot, changes: ChangeSet) {
        let dir = try tempDirectory("Fault")
        let packageURL = dir.appendingPathComponent("doc.courseleafdoc")
        let (snapshot, assets) = Support.makeSnapshot()
        let store = DocumentPackageStore(packageURL: packageURL, clock: ManualClock(start: now))
        let receipt = try await store.create(snapshot: snapshot, assets: assets)
        // Make a second commit so a real lkg exists before the scenario runs.
        var v2 = receipt.snapshot
        let receipt2 = try await store.commit(snapshot: v2, changes: Support.editPage(&v2, index: 2, text: "v2"))
        var edited = receipt2.snapshot
        var changes = Support.editPage(&edited, index: 1, text: "F = ma")
        let newInk = PendingAsset.make(data: Support.inkData("ink-2"), mediaType: .inkDrawing, now: now)
        edited.assets[newInk.asset.id] = newInk.asset
        edited.pages[edited.document.pageIDs[0]]!.inkLayers[0].dataAssetID = newInk.asset.id
        changes.changedPageIDs.insert(edited.document.pageIDs[0])
        changes.newAssets = [newInk]
        edited.document.title = "Physics 1 (edited)"
        changes.documentChanged = true
        return (packageURL, receipt2.snapshot, edited, changes)
    }

    /// Counts the mutating steps of the scenario commit and locates the manifest rename.
    /// The scenario is deterministic in shape (same files, same order), only its identifiers differ per run.
    private func countCommitSteps() async throws -> (steps: Int, renameStep: Int) {
        let s = try await prepareScenario()
        let fs = FaultInjectingFileSystem()
        let store = DocumentPackageStore(packageURL: s.packageURL, fileSystem: fs, clock: ManualClock(start: now))
        _ = try await store.open()
        fs.resetCounters()
        let receipt = try await store.commit(snapshot: s.edited, changes: s.changes)
        let ops = fs.mutatingOperations
        let rename = ops.firstIndex { $0.kind == .replaceItem && $0.path.hasSuffix("/manifest.json") }!
        XCTAssertGreaterThan(ops.count, 12)
        XCTAssertEqual(ops.last?.kind, .syncDirectory)
        // The post-commit content is the edited snapshot (the store only assigns revision ids).
        XCTAssertEqual(Support.normalized(receipt.snapshot), Support.normalized(s.edited))
        return (ops.count, rename)
    }

    func testA07EveryFailingStepLeavesPreviousManifestReadable() async throws {
        let (steps, renameStep) = try await countCommitSteps()
        let errors: [PersistenceError] = [.diskFull, .writeFailed(path: "x", underlying: "EIO")]
        for step in 0..<steps {
            let injected = errors[step % errors.count]
            let s = try await prepareScenario()
            let fs = FaultInjectingFileSystem()
            let store = DocumentPackageStore(packageURL: s.packageURL, fileSystem: fs, clock: ManualClock(start: now))
            _ = try await store.open()
            fs.resetCounters()
            fs.failStep(step, with: injected)
            do {
                _ = try await store.commit(snapshot: s.edited, changes: s.changes)
                XCTFail("step \(step): commit should have failed")
            } catch let error as PersistenceError {
                XCTAssertEqual(error, injected, "step \(step)")
            }
            XCTAssertEqual(fs.mutatingOperations[step].applied, false)
            // Readers see the previous content for every step up to the manifest rename.
            let (_, reopened) = try await DocumentPackageStore.open(s.packageURL)
            let content = Support.normalized(reopened.snapshot)
            let post = Support.normalized(s.edited)
            if step <= renameStep {
                XCTAssertEqual(content, Support.normalized(s.pre), "step \(step) (\(fs.mutatingOperations[step]))")
                XCTAssertEqual(reopened.snapshot.document.revisionHead, s.pre.document.revisionHead, "step \(step)")
            } else {
                XCTAssertEqual(content, post, "step \(step): after the rename only the directory sync remains")
            }
            XCTAssertEqual(reopened.report.manifestSource, .manifest, "step \(step)")
            XCTAssertTrue(reopened.report.recoveredPages.isEmpty, "step \(step)")
            XCTAssertTrue(reopened.report.validationIssues.isEmpty, "step \(step): \(reopened.report.validationIssues)")
            // The store itself is usable again: a retry after the fault succeeds and lands the edit.
            fs.clearFaults()
            let retry = try await store.commit(snapshot: s.edited, changes: s.changes)
            let (_, afterRetry) = try await DocumentPackageStore.open(s.packageURL)
            XCTAssertEqual(afterRetry.snapshot, retry.snapshot, "step \(step)")
            XCTAssertEqual(Support.normalized(afterRetry.snapshot), post, "step \(step)")
        }
    }

    func testA08CrashAtEveryStepReopensToPreOrPostState() async throws {
        let (steps, renameStep) = try await countCommitSteps()
        for step in 0..<steps {
            let s = try await prepareScenario()
            let fs = FaultInjectingFileSystem()
            let store = DocumentPackageStore(packageURL: s.packageURL, fileSystem: fs, clock: ManualClock(start: now))
            _ = try await store.open()
            fs.resetCounters()
            fs.crash(atStep: step)
            do {
                _ = try await store.commit(snapshot: s.edited, changes: s.changes)
                XCTFail("step \(step): commit should have crashed")
            } catch let crash as SimulatedCrash {
                XCTAssertEqual(crash.step, step)
            }
            XCTAssertTrue(fs.hasCrashed)
            XCTAssertTrue(fs.mutatingOperations.dropFirst(step).allSatisfy { !$0.applied }, "nothing may be applied after the crash")

            // A new process opens the package with a plain file system.
            let (_, reopened) = try await DocumentPackageStore.open(s.packageURL)
            let content = Support.normalized(reopened.snapshot)
            let pre = Support.normalized(s.pre), after = Support.normalized(s.edited)
            XCTAssertNotEqual(pre, after)
            XCTAssertTrue(content == pre || content == after, "step \(step): state is neither pre nor post")
            if step <= renameStep {
                XCTAssertEqual(content, pre, "step \(step)")
            } else {
                XCTAssertEqual(content, after, "step \(step)")
            }
            XCTAssertEqual(reopened.report.manifestSource, .manifest, "step \(step)")
            XCTAssertFalse(reopened.report.usedFallback, "step \(step)")
            XCTAssertTrue(reopened.report.validationIssues.isEmpty, "step \(step)")
            XCTAssertTrue(reopened.report.missingAssets.isEmpty, "step \(step)")
            // The lkg manifest, when present, is itself a valid earlier state.
            let lkgURL = s.packageURL.appendingPathComponent("manifest.lkg.json")
            if FileManager.default.fileExists(atPath: lkgURL.path) {
                XCTAssertNoThrow(try PackageManifest.decode(Data(contentsOf: lkgURL)), "step \(step)")
            }
        }
    }

    // MARK: Recovery

    func testInvalidManifestFallsBackToLastKnownGood() async throws {
        let dir = try tempDirectory()
        let packageURL = dir.appendingPathComponent("doc.courseleafdoc")
        let (snapshot, assets) = Support.makeSnapshot()
        let store = DocumentPackageStore(packageURL: packageURL, clock: ManualClock(start: now))
        let first = try await store.create(snapshot: snapshot, assets: assets)
        var v2 = first.snapshot
        _ = try await store.commit(snapshot: v2, changes: Support.editPage(&v2, index: 0, text: "second"))
        try Data("{ this is not json".utf8).write(to: packageURL.appendingPathComponent("manifest.json"))

        let (_, opened) = try await DocumentPackageStore.open(packageURL)
        XCTAssertEqual(opened.report.manifestSource, .lkgManifest)
        XCTAssertTrue(opened.report.usedFallback)
        XCTAssertNotNil(opened.report.rejectedManifestReason)
        XCTAssertEqual(Support.normalized(opened.snapshot), Support.normalized(first.snapshot))
        XCTAssertEqual(opened.snapshot.document.revisionHead, first.revisionID)

        // Both unreadable -> corruptManifest, never an empty document.
        try Data("null".utf8).write(to: packageURL.appendingPathComponent("manifest.lkg.json"))
        do { _ = try await DocumentPackageStore.open(packageURL); XCTFail("expected corruptManifest") }
        catch let error as PersistenceError { if case .corruptManifest = error {} else { XCTFail("\(error)") } }
    }

    func testMissingCurrentPageFileIsRecoveredFromEarlierRevision() async throws {
        let dir = try tempDirectory()
        let packageURL = dir.appendingPathComponent("doc.courseleafdoc")
        let (snapshot, assets) = Support.makeSnapshot()
        let store = DocumentPackageStore(packageURL: packageURL, clock: ManualClock(start: now))
        let first = try await store.create(snapshot: snapshot, assets: assets)
        let pageID = snapshot.document.pageIDs[1]
        var v2 = first.snapshot
        let second = try await store.commit(snapshot: v2, changes: Support.editPage(&v2, index: 1, text: "newer"))
        let currentFile = packageURL.appendingPathComponent(PackageLayout.pageFile(pageID: pageID, revisionID: second.revisionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentFile.path))
        try FileManager.default.removeItem(at: currentFile)

        let (_, opened) = try await DocumentPackageStore.open(packageURL)
        XCTAssertEqual(opened.report.manifestSource, .manifest)
        XCTAssertEqual(opened.report.recoveredPages, [pageID: first.revisionID])
        XCTAssertEqual(opened.report.unreadablePageFiles[pageID], PackageLayout.pageFile(pageID: pageID, revisionID: second.revisionID))
        XCTAssertEqual(opened.snapshot.pages[pageID], first.snapshot.pages[pageID])
        XCTAssertEqual(opened.snapshot.pages[pageID]?.objects.count, 2)
        // A corrupt (digest mismatch) current file is treated the same way.
        try Data("{}".utf8).write(to: currentFile)
        let (_, opened2) = try await DocumentPackageStore.open(packageURL)
        XCTAssertEqual(opened2.report.recoveredPages, [pageID: first.revisionID])

        // With no earlier file at all the open fails with a specific error rather than an empty page.
        try FileManager.default.removeItem(at: packageURL.appendingPathComponent(PackageLayout.pageFile(pageID: pageID, revisionID: first.revisionID)))
        do { _ = try await DocumentPackageStore.open(packageURL); XCTFail("expected missingPageFile") }
        catch let error as PersistenceError { XCTAssertEqual(error, .missingPageFile(pageID: pageID)) }
    }

    func testUnsupportedSchemaIsAnErrorNotAnEmptyDocument() async throws {
        let dir = try tempDirectory()
        let packageURL = dir.appendingPathComponent("doc.courseleafdoc")
        let (snapshot, assets) = Support.makeSnapshot()
        let store = DocumentPackageStore(packageURL: packageURL, clock: ManualClock(start: now))
        var v2 = (try await store.create(snapshot: snapshot, assets: assets)).snapshot
        _ = try await store.commit(snapshot: v2, changes: Support.editPage(&v2, index: 0, text: "x"))
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let text = String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\" : 1"))
        try Data(text.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 2").utf8).write(to: manifestURL)
        do { _ = try await DocumentPackageStore.open(packageURL); XCTFail("expected unsupportedSchema") }
        catch let error as PersistenceError { XCTAssertEqual(error, .unsupportedSchema(version: 2)) }
        // The lkg (version 1) must not be used silently either.
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.lkg.json").path))
        XCTAssertThrowsError(try DocumentPackageStore.readManifest(at: packageURL, fileSystem: LocalFileSystem()))
        var manifest = PackageManifest(document: snapshot.document, pageFiles: [:], assets: [:], committedAt: now)
        manifest.formatVersion = 2
        XCTAssertThrowsError(try SchemaMigrator.migrate(manifest))
        manifest.formatVersion = 1
        XCTAssertEqual(try SchemaMigrator.migrate(manifest).formatVersion, 1)
    }

    func testMissingAssetIsReportedOnOpenAndOnRead() async throws {
        let dir = try tempDirectory()
        let (snapshot, assets) = Support.makeSnapshot()
        let store = DocumentPackageStore(packageURL: dir.appendingPathComponent("d.courseleafdoc"), clock: ManualClock(start: now))
        _ = try await store.create(snapshot: snapshot, assets: assets)
        try FileManager.default.removeItem(at: store.packageURL.appendingPathComponent(assets[1].asset.relativePath))
        let (reopened, result) = try await DocumentPackageStore.open(store.packageURL)
        XCTAssertEqual(result.report.missingAssets, [assets[1].asset.id])
        do { _ = try await reopened.assetData(assets[1].asset.id); XCTFail("expected missingAsset") }
        catch let error as PersistenceError { XCTAssertEqual(error, .missingAsset(id: assets[1].asset.id)) }
        let url = await reopened.assetURL(assets[1].asset.id)
        XCTAssertNil(url)
        // A commit that still references it is refused.
        do { _ = try await reopened.commit(snapshot: result.snapshot, changes: ChangeSet(documentChanged: true)); XCTFail("expected missingAsset") }
        catch let error as PersistenceError { XCTAssertEqual(error, .missingAsset(id: assets[1].asset.id)) }
    }

    // MARK: Garbage collection

    func testGarbageCollectionKeepsReferencedPinnedAndTrashRemovesOrphans() async throws {
        let dir = try tempDirectory()
        let packageURL = dir.appendingPathComponent("doc.courseleafdoc")
        let (snapshot, assets) = Support.makeSnapshot()
        let inkV1 = assets[0], image = assets[1]
        let store = DocumentPackageStore(packageURL: packageURL, clock: ManualClock(start: now), retainedRevisionCount: 2)
        var snap = (try await store.create(snapshot: snapshot, assets: assets)).snapshot
        let p0 = snap.document.pageIDs[0], p1 = snap.document.pageIDs[1], p2 = snap.document.pageIDs[2]

        // Replace the ink blob and drop the old record from the table (as an editor pruning its table would).
        let inkV2 = PendingAsset.make(data: Support.inkData("ink-v2"), mediaType: .inkDrawing, now: now)
        snap.assets[inkV2.asset.id] = inkV2.asset
        snap.assets[inkV1.asset.id] = nil
        snap.pages[p0]!.inkLayers[0].dataAssetID = inkV2.asset.id
        snap = (try await store.commit(snapshot: snap, changes: ChangeSet(changedPageIDs: [p0], newAssets: [inkV2]))).snapshot
        // Delete page 1, the page holding the image (trash inside the document): its content moves to
        // deletedPages, so from now on the image asset is referenced by the trash only.
        let deletedPage = snap.pages[p1]!
        XCTAssertEqual(deletedPage.referencedAssetIDs, [image.asset.id])
        snap.pages[p1] = nil
        snap.document.pageIDs.removeAll { $0 == p1 }
        snap.document.deletedPages = [DeletedPage(page: deletedPage, originalIndex: 1, deletedAt: now)]
        let deletedPageFile = PackageLayout.pageFile(pageID: p1, revisionID: deletedPage.revisionID)
        snap = (try await store.commit(snapshot: snap, changes: ChangeSet(documentChanged: true))).snapshot
        XCTAssertEqual(snap.document.pageIDs, [p0, p2])
        // Several more commits on the remaining second page (p2) so early page files fall out of the retained window.
        var page1Files: [String] = []
        for i in 0..<5 {
            let r = try await store.commit(snapshot: snap, changes: Support.editPage(&snap, index: 1, text: "edit \(i)"))
            snap = r.snapshot
            XCTAssertEqual(r.pagesWritten, [p2])
            page1Files.append(PackageLayout.pageFile(pageID: p2, revisionID: r.revisionID))
        }
        // Orphans planted by hand: an asset nobody references, a page file of an unknown revision, a leftover tmp file.
        let orphanAsset = PendingAsset.make(data: Data("orphan".utf8), mediaType: .png, now: now)
        let orphanURL = packageURL.appendingPathComponent(orphanAsset.asset.relativePath)
        try FileManager.default.createDirectory(at: orphanURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try orphanAsset.data.write(to: orphanURL)
        let strayPage = packageURL.appendingPathComponent(PackageLayout.pageFile(pageID: p2, revisionID: RevisionID()))
        try Data("{}".utf8).write(to: strayPage)
        try Data("tmp".utf8).write(to: packageURL.appendingPathComponent("tmp/leftover.json"))

        let inkV1URL = packageURL.appendingPathComponent(inkV1.asset.relativePath)
        let inkV2URL = packageURL.appendingPathComponent(inkV2.asset.relativePath)
        let imageURL = packageURL.appendingPathComponent(image.asset.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkV1URL.path))

        // First pass pins the old ink (as an undo stack would): it must survive.
        let pinned = try await store.collectGarbage(pinnedAssetIDs: [inkV1.asset.id], pinnedAssets: [inkV1.asset])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkV1URL.path), "pinned asset removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkV2URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path), "asset referenced by a deleted (trashed) page removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayPage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("tmp/leftover.json").path))
        XCTAssertTrue(pinned.removedFiles.contains(orphanAsset.asset.relativePath))
        XCTAssertGreaterThan(pinned.reclaimedBytes, 0)
        // Retained window: newest two revisions + both manifest heads; older page-1 files are gone, newest kept.
        let pagesDir = packageURL.appendingPathComponent("pages")
        let remaining = Support.files(in: pagesDir)
        XCTAssertTrue(remaining.contains((page1Files.last! as NSString).lastPathComponent))
        XCTAssertTrue(remaining.contains((page1Files[3] as NSString).lastPathComponent), "lkg manifest's page file must be kept")
        XCTAssertFalse(remaining.contains((page1Files[0] as NSString).lastPathComponent))
        XCTAssertFalse(remaining.contains((deletedPageFile as NSString).lastPathComponent), "page file of a trashed page is unreferenced once it leaves the retained window")
        // Revisions outside the retained set are gone too, but the head chain still opens.
        XCTAssertEqual(Support.files(in: packageURL.appendingPathComponent("revisions")).count, pinned.retainedRevisionIDs.count)

        // Second pass without the pin removes the old ink; everything referenced stays.
        _ = try await store.collectGarbage()
        XCTAssertFalse(FileManager.default.fileExists(atPath: inkV1URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkV2URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        let (reopenedStore, reopened) = try await DocumentPackageStore.open(packageURL)
        XCTAssertTrue(reopened.report.isClean, "\(reopened.report)")
        XCTAssertEqual(Support.normalized(reopened.snapshot), Support.normalized(snap))
        XCTAssertEqual(reopened.snapshot.document.deletedPages.first?.page.referencedAssetIDs, [image.asset.id])
        let imageData = try await reopenedStore.assetData(image.asset.id)
        XCTAssertEqual(imageData, image.data)
    }

    // MARK: Concurrency

    func testConcurrentCommitsAreSerializedIntoOneRevisionChain() async throws {
        let dir = try tempDirectory()
        let (snapshot, assets) = Support.makeSnapshot(pageCount: 6)
        let store = DocumentPackageStore(packageURL: dir.appendingPathComponent("d.courseleafdoc"), clock: ManualClock(start: now))
        let base = (try await store.create(snapshot: snapshot, assets: assets)).snapshot
        let receipts: [CommitReceipt] = try await withThrowingTaskGroup(of: CommitReceipt.self) { group in
            for i in 0..<6 {
                group.addTask {
                    var copy = base
                    let changes = Support.editPage(&copy, index: i, text: "task \(i)")
                    copy.document.title = "title \(i)"
                    return try await store.commit(snapshot: copy, changes: changes)
                }
            }
            var out: [CommitReceipt] = []
            for try await r in group { out.append(r) }
            return out
        }
        let ordered = receipts.sorted { $0.snapshot.headRevision!.sequence < $1.snapshot.headRevision!.sequence }
        XCTAssertEqual(ordered.map { $0.snapshot.headRevision!.sequence }, Array(3...8))
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertEqual(b.snapshot.headRevision?.parentIDs, [a.revisionID], "commits must form one linear chain")
        }
        let (_, reopened) = try await DocumentPackageStore.open(store.packageURL)
        XCTAssertTrue(reopened.report.isClean, "\(reopened.report)")
        XCTAssertEqual(reopened.snapshot, ordered.last!.snapshot)
        XCTAssertEqual(reopened.snapshot.revisions.count, 8)
    }
}
