import Foundation
import UIKit
import PDFKit
import DocumentCore
import Editing

@MainActor
protocol PageNavigatorDelegate: AnyObject {
    func navigator(_ navigator: PageNavigatorViewController, didSelectPageIndex index: Int)
    func navigator(_ navigator: PageNavigatorViewController, movePage id: PageID, to index: Int)
    func navigator(_ navigator: PageNavigatorViewController, insertPageAfter index: Int, template: PaperTemplate?)
    func navigator(_ navigator: PageNavigatorViewController, duplicatePageAt index: Int)
    func navigator(_ navigator: PageNavigatorViewController, deletePageAt index: Int)
    func navigator(_ navigator: PageNavigatorViewController, restorePage id: PageID)
    func navigator(_ navigator: PageNavigatorViewController, toggleBookmarkAt index: Int)
    func navigatorDidRequestClose(_ navigator: PageNavigatorViewController)
}

/// Sidebar/sheet with three tabs: page thumbnails (drag to reorder, context
/// menu for insert/duplicate/delete/bookmark, deleted pages with restore),
/// bookmarks, and the PDF outline (PDFKit `outlineRoot`) mapped to page indices.
final class PageNavigatorViewController: UIViewController, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate {
    weak var delegate: PageNavigatorDelegate?
    private let snapshotProvider: () -> DocumentSnapshot
    private let thumbnails: ThumbnailCache
    private let loader: PageContentLoader

    private enum Tab: Int { case pages, bookmarks, outline }
    private enum Section: Hashable { case pages, deleted }
    private enum Item: Hashable { case page(PageID), deleted(PageID) }

    private let segmented = UISegmentedControl(items: ["Pages", "Bookmarks", "Outline"])
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let bookmarksTable = UITableView(frame: .zero, style: .insetGrouped)
    private let outlineTable = UITableView(frame: .zero, style: .insetGrouped)
    private var bookmarkedIndices: [Int] = []
    private var outlineEntries: [OutlineEntry] = []
    private var outlineTask: Task<Void, Never>?
    private(set) var currentPageIndex = 0

    struct OutlineEntry: Hashable {
        var title: String
        var depth: Int
        var pageIndex: Int?
    }

    init(snapshotProvider: @escaping () -> DocumentSnapshot, thumbnails: ThumbnailCache, loader: PageContentLoader) {
        self.snapshotProvider = snapshotProvider
        self.thumbnails = thumbnails
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
        title = "Pages"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; self.delegate?.navigatorDidRequestClose(self)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.navigator(self, insertPageAfter: self.snapshotProvider().document.pageIDs.count - 1, template: nil)
        })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Add Page at End"

        segmented.selectedSegmentIndex = 0
        segmented.addAction(UIAction { [weak self] _ in self?.showSelectedTab() }, for: .valueChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmented)

        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        configuration.headerMode = .supplementary
        configuration.showsSeparators = false
        _ = configuration
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeGridLayout())
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityLabel = "Page thumbnails"
        view.addSubview(collectionView)

        let cellRegistration = UICollectionView.CellRegistration<PageThumbnailCell, Item> { [weak self] cell, indexPath, item in
            guard let self else { return }
            let snapshot = self.snapshotProvider()
            switch item {
            case .page(let id):
                guard let page = snapshot.pages[id], let index = snapshot.pageIndex(id) else { return }
                cell.configure(page: page, pageNumber: index + 1, isCurrent: index == self.currentPageIndex, isDeleted: false, thumbnails: self.thumbnails)
            case .deleted(let id):
                guard let deleted = snapshot.document.deletedPages.first(where: { $0.id == id }) else { return }
                cell.configure(page: deleted.page, pageNumber: deleted.originalIndex + 1, isCurrent: false, isDeleted: true, thumbnails: self.thumbnails)
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.groupedHeader()
            let section = self.dataSource.snapshot().sectionIdentifiers[indexPath.section]
            content.text = section == .pages ? "Pages" : "Recently Deleted"
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
        dataSource.reorderingHandlers.canReorderItem = { item in if case .page = item { return true } else { return false } }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let before = transaction.initialSnapshot.itemIdentifiers(inSection: .pages)
            let after = transaction.finalSnapshot.itemIdentifiers(inSection: .pages)
            guard let (moved, to) = Self.singleMove(from: before, to: after), case .page(let id) = moved else { return }
            self.delegate?.navigator(self, movePage: id, to: to)
        }

        for table in [bookmarksTable, outlineTable] {
            table.dataSource = self
            table.delegate = self
            table.translatesAutoresizingMaskIntoConstraints = false
            table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            table.isHidden = true
            view.addSubview(table)
        }
        bookmarksTable.accessibilityLabel = "Bookmarks"
        outlineTable.accessibilityLabel = "Outline"

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
        for content in [collectionView!, bookmarksTable, outlineTable] as [UIView] {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        reload()
    }

    private func makeGridLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(1, Int(width / 150))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .estimated(200)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(200)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 12, trailing: 8)
            let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(32)),
                                                                     elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    /// The single item that moved between two orders, and its new index.
    static func singleMove<T: Hashable>(from before: [T], to after: [T]) -> (T, Int)? {
        guard before.count == after.count, before != after else { return nil }
        for (i, candidate) in before.enumerated() where after[i] != candidate || i == before.count - 1 {
            var withoutBefore = before; withoutBefore.remove(at: i)
            if let j = after.firstIndex(of: candidate) {
                var withoutAfter = after; withoutAfter.remove(at: j)
                if withoutBefore == withoutAfter { return (candidate, j) }
            }
        }
        return nil
    }

    // MARK: Reload

    func reload() {
        guard isViewLoaded else { return }
        let snapshot = snapshotProvider()
        var diff = NSDiffableDataSourceSnapshot<Section, Item>()
        diff.appendSections([.pages])
        diff.appendItems(snapshot.document.pageIDs.map(Item.page), toSection: .pages)
        if !snapshot.document.deletedPages.isEmpty {
            diff.appendSections([.deleted])
            diff.appendItems(snapshot.document.deletedPages.map { Item.deleted($0.id) }, toSection: .deleted)
        }
        // Reconfigure every visible item so thumbnails follow edits.
        diff.reconfigureItems(diff.itemIdentifiers)
        dataSource.apply(diff, animatingDifferences: false)
        bookmarkedIndices = snapshot.orderedPages.enumerated().filter { $0.element.isBookmarked }.map(\.offset)
        bookmarksTable.reloadData()
        reloadOutline(snapshot: snapshot)
    }

    func setCurrentPageIndex(_ index: Int, scroll: Bool) {
        let previous = currentPageIndex
        currentPageIndex = index
        guard isViewLoaded else { return }
        let ids = snapshotProvider().document.pageIDs
        var diff = dataSource.snapshot()
        var toReconfigure: [Item] = []
        if ids.indices.contains(previous) { toReconfigure.append(.page(ids[previous])) }
        if ids.indices.contains(index) { toReconfigure.append(.page(ids[index])) }
        let existing = Set(diff.itemIdentifiers)
        diff.reconfigureItems(toReconfigure.filter { existing.contains($0) })
        dataSource.apply(diff, animatingDifferences: false)
        if scroll, ids.indices.contains(index), let indexPath = dataSource.indexPath(for: .page(ids[index])) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
    }

    private func showSelectedTab() {
        let tab = Tab(rawValue: segmented.selectedSegmentIndex) ?? .pages
        collectionView.isHidden = tab != .pages
        bookmarksTable.isHidden = tab != .bookmarks
        outlineTable.isHidden = tab != .outline
    }

    // MARK: Outline

    private func reloadOutline(snapshot: DocumentSnapshot) {
        outlineTask?.cancel()
        let pages = snapshot.orderedPages
        // Distinct PDF assets in page order; each contributes its outline once.
        var seen = Set<AssetID>()
        var assets: [AssetID] = []
        for page in pages { if case .pdf(let src) = page.background, seen.insert(src.assetID).inserted { assets.append(src.assetID) } }
        guard !assets.isEmpty else { outlineEntries = []; outlineTable.reloadData(); return }
        outlineTask = Task { [weak self] in
            guard let self else { return }
            var entries: [OutlineEntry] = []
            for assetID in assets {
                guard let document = await self.loader.pdfDocument(for: assetID), let root = document.outlineRoot else { continue }
                var indexByPDFPage: [Int: Int] = [:]
                for (i, page) in pages.enumerated() {
                    if case .pdf(let src) = page.background, src.assetID == assetID, indexByPDFPage[src.pageIndex] == nil { indexByPDFPage[src.pageIndex] = i }
                }
                Self.flatten(root, depth: 0, document: document, pageIndexMap: indexByPDFPage, into: &entries)
            }
            guard !Task.isCancelled else { return }
            self.outlineEntries = entries
            self.outlineTable.reloadData()
        }
    }

    private static func flatten(_ outline: PDFOutline, depth: Int, document: PDFDocument, pageIndexMap: [Int: Int], into entries: inout [OutlineEntry]) {
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            var pageIndex: Int?
            if let page = child.destination?.page {
                let pdfIndex = document.index(for: page)
                pageIndex = pageIndexMap[pdfIndex]
            }
            entries.append(OutlineEntry(title: child.label ?? "Untitled", depth: depth, pageIndex: pageIndex))
            if depth < 8 { flatten(child, depth: depth + 1, document: document, pageIndexMap: pageIndexMap, into: &entries) }
        }
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .page(let id):
            if let index = snapshotProvider().pageIndex(id) { delegate?.navigator(self, didSelectPageIndex: index) }
        case .deleted(let id):
            delegate?.navigator(self, restorePage: id)
        }
        collectionView.deselectItem(at: indexPath, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let snapshot = snapshotProvider()
        switch item {
        case .deleted(let id):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [UIAction(title: "Restore", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                    guard let self else { return }; self.delegate?.navigator(self, restorePage: id)
                }])
            }
        case .page(let id):
            guard let index = snapshot.pageIndex(id), let page = snapshot.pages[id] else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let insertItems: [UIMenuElement] = [
                    UIAction(title: "Default Paper", image: UIImage(systemName: "doc")) { [weak self] _ in
                        guard let self else { return }; self.delegate?.navigator(self, insertPageAfter: index, template: nil)
                    },
                ] + PaperKind.allCases.map { kind in
                    UIAction(title: kind.rawValue.capitalized) { [weak self] _ in
                        guard let self else { return }; self.delegate?.navigator(self, insertPageAfter: index, template: .preset(kind))
                    }
                }
                let canDelete = snapshot.document.pageIDs.count > 1
                return UIMenu(children: [
                    UIMenu(title: "Insert Page After", image: UIImage(systemName: "plus"), children: insertItems),
                    UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                        guard let self else { return }; self.delegate?.navigator(self, duplicatePageAt: index)
                    },
                    UIAction(title: page.isBookmarked ? "Remove Bookmark" : "Bookmark", image: UIImage(systemName: page.isBookmarked ? "bookmark.slash" : "bookmark")) { [weak self] _ in
                        guard let self else { return }; self.delegate?.navigator(self, toggleBookmarkAt: index)
                    },
                    UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: canDelete ? .destructive : [.destructive, .disabled]) { [weak self] _ in
                        guard let self else { return }; self.delegate?.navigator(self, deletePageAt: index)
                    },
                ])
            }
        }
    }

    // MARK: Tables (bookmarks, outline)

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableView === bookmarksTable ? max(bookmarkedIndices.count, 1) : max(outlineEntries.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.selectionStyle = .default
        if tableView === bookmarksTable {
            if bookmarkedIndices.isEmpty {
                content.text = "No bookmarks"
                content.secondaryText = "Use the bookmark button to mark a page."
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            } else {
                let index = bookmarkedIndices[indexPath.row]
                let snapshot = snapshotProvider()
                content.text = "Page \(index + 1)"
                if let page = snapshot.orderedPages[safe: index], let problem = page.problem { content.secondaryText = problem.title }
                content.image = UIImage(systemName: "bookmark.fill")
                cell.accessoryType = .disclosureIndicator
            }
        } else {
            if outlineEntries.isEmpty {
                content.text = "No outline"
                content.secondaryText = "Imported PDFs with a table of contents show it here."
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            } else {
                let entry = outlineEntries[indexPath.row]
                content.text = entry.title
                content.secondaryText = entry.pageIndex.map { "Page \($0 + 1)" } ?? "Not in this notebook"
                content.directionalLayoutMargins.leading = CGFloat(16 + entry.depth * 16)
                cell.selectionStyle = entry.pageIndex == nil ? .none : .default
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tableView === bookmarksTable {
            guard bookmarkedIndices.indices.contains(indexPath.row) else { return }
            delegate?.navigator(self, didSelectPageIndex: bookmarkedIndices[indexPath.row])
        } else {
            guard outlineEntries.indices.contains(indexPath.row), let index = outlineEntries[indexPath.row].pageIndex else { return }
            delegate?.navigator(self, didSelectPageIndex: index)
        }
    }
}

/// Thumbnail + page number + bookmark badge.
final class PageThumbnailCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let label = UILabel()
    private let bookmark = UIImageView(image: UIImage(systemName: "bookmark.fill"))
    private var requestedKey: String?
    private var aspect: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        imageView.layer.borderWidth = 1
        imageView.layer.borderColor = UIColor.separator.cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        bookmark.tintColor = .systemOrange
        bookmark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        contentView.addSubview(label)
        contentView.addSubview(bookmark)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bookmark.topAnchor.constraint(equalTo: imageView.topAnchor, constant: -2),
            bookmark.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -8),
            bookmark.widthAnchor.constraint(equalToConstant: 16),
            bookmark.heightAnchor.constraint(equalToConstant: 22),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(page: Page, pageNumber: Int, isCurrent: Bool, isDeleted: Bool, thumbnails: ThumbnailCache) {
        label.text = isDeleted ? "Was page \(pageNumber)" : "\(pageNumber)"
        bookmark.isHidden = !page.isBookmarked
        imageView.layer.borderColor = isCurrent ? UIColor.tintColor.cgColor : UIColor.separator.cgColor
        imageView.layer.borderWidth = isCurrent ? 3 : 1
        imageView.alpha = isDeleted ? 0.5 : 1
        aspect?.isActive = false
        aspect = imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: max(0.2, min(5, page.size.height / max(page.size.width, 1))))
        aspect?.isActive = true
        accessibilityLabel = (isDeleted ? "Deleted page \(pageNumber)" : "Page \(pageNumber)") + (page.isBookmarked ? ", bookmarked" : "") + (isCurrent ? ", current" : "")
        accessibilityHint = isDeleted ? "Double tap to restore" : "Double tap to show"
        let size = CGSize(width: 160, height: max(1, 160 * page.size.height / max(page.size.width, 1)))
        let key = ThumbnailCache.key(for: page, size: size)
        if let cached = thumbnails.cachedImage(for: page, size: size) { imageView.image = cached; requestedKey = key; return }
        if requestedKey == key { return }
        requestedKey = key
        imageView.image = nil
        thumbnails.requestImage(for: page, size: size) { [weak self] image in
            guard let self, self.requestedKey == key, let image else { return }
            self.imageView.image = image
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
