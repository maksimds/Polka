import Combine
import Foundation

/// The shelf's contents, in the order they're shown. Unsorted, new items arrive at
/// the front and the user can move items anywhere. Sorted (`sort`), the shelf stays
/// in that order through every change, like a Finder window with "Sort By" set.
/// No window or AppKit code lives here, so the logic can be tested on its own.
@MainActor
final class ShelfStore: ObservableObject {
    /// What happened to a batch of drafts passed to `add`.
    struct AddResult: Equatable {
        let added: [ShelfItem]
        /// Drafts that were skipped because the shelf already has that file or link.
        let duplicates: [ShelfItem.Draft]
    }

    @Published private(set) var items: [ShelfItem]
    /// File items whose original can't be found right now (FR-15). They stay on the
    /// shelf and come back if the file does.
    @Published private(set) var missingItemIDs: Set<ShelfItem.ID> = []
    /// File items whose copy is being made right now. Not saved.
    @Published private(set) var copyingItemIDs: Set<ShelfItem.ID> = []
    /// Documents being converted to PDF right now. Not saved.
    @Published private(set) var convertingItemIDs: Set<ShelfItem.ID> = []
    /// The order the shelf keeps. Saved by whoever changes it (in UserDefaults), not here.
    @Published private(set) var sort: ShelfSort
    /// True when a saved shelf existed but couldn't be read, so `items` may be
    /// missing things that are still on disk, such as their copies.
    private(set) var loadFailed = false

    private let persistence: ShelfPersistence
    private let now: () -> Date

    init(persistence: ShelfPersistence = InMemoryShelfPersistence(),
         sort: ShelfSort = .none,
         now: @escaping () -> Date = { Date() }) {
        self.persistence = persistence
        self.sort = sort
        self.now = now
        do {
            // Sorted again in case the choice changed while Polka wasn't running. The
            // new order is saved with the next change.
            let saved = try persistence.load().sorted { $0.sortOrder < $1.sortOrder }
            items = Self.numbered(sort.arranged(saved))
        } catch {
            Log.storage.error("Could not load the shelf: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
            items = []
            loadFailed = true
        }
    }

    /// Adds new items to the front, in the order given, or right after the item
    /// `after` (a PDF lands next to the document it was made from), or to their sorted
    /// spots if the shelf is sorted. Anything already on the shelf is left where it is
    /// and reported in the result, so the UI can say so.
    @discardableResult
    func add(_ drafts: [ShelfItem.Draft], after neighborID: ShelfItem.ID? = nil) -> AddResult {
        var seen = Set(items.flatMap(\.dedupeKeys))
        var newItems: [ShelfItem] = []
        var duplicates: [ShelfItem.Draft] = []
        let date = now()

        for draft in drafts {
            guard seen.insert(draft.source.dedupeKey).inserted else {
                duplicates.append(draft)
                continue
            }
            newItems.append(ShelfItem(id: UUID(),
                                      kind: draft.kind,
                                      title: draft.title,
                                      source: draft.source,
                                      storageMode: draft.storageMode,
                                      createdAt: date,
                                      expiresAt: nil,
                                      sortOrder: 0))
        }

        guard !newItems.isEmpty else { return AddResult(added: [], duplicates: duplicates) }
        // The front, unless the neighbor is still on the shelf.
        let index = neighborID.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        var newList = items
        newList.insert(contentsOf: newItems, at: index)
        commit(newList)
        // Looked up again for their final places: sorted, they may not be at the front.
        let added = newItems.compactMap { new in items.first { $0.id == new.id } }
        return AddResult(added: added, duplicates: duplicates)
    }

    /// Removes the shelf entry only. The original file is never touched.
    @discardableResult
    func remove(id: ShelfItem.ID) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        commit(items.filter { $0.id != id })
        return true
    }

    /// Removes several shelf entries at once, with one save. The original files are
    /// never touched.
    func remove(ids: Set<ShelfItem.ID>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        commit(items.filter { !ids.contains($0.id) })
    }

    /// Moves items to a new place on the shelf, side by side and in the order they
    /// were in, with the first of them at `index` (see `moving(_:to:)`). Saves only
    /// if the order really changed. A sorted shelf keeps its order, so nothing moves.
    func move(_ ids: Set<ShelfItem.ID>, to index: Int) {
        guard sort == .none else { return }
        let newItems = items.moving(ids, to: index)
        guard newItems.map(\.id) != items.map(\.id) else { return }
        commit(newItems)
    }

    /// Changes the order the shelf keeps, and sorts it now. Back on `none`, the tiles
    /// stay where the last sort put them, as in Finder, and can be moved from there.
    /// Saves only if the order really changed.
    func setSort(_ newSort: ShelfSort) {
        guard newSort != sort else { return }
        sort = newSort
        let arranged = newSort.arranged(items)
        guard arranged.map(\.id) != items.map(\.id) else { return }
        commit(arranged)
    }

    /// Makes an item temporary: it is removed `lifetime` seconds from now.
    func makeTemporary(id: ShelfItem.ID, lifetime: TimeInterval) {
        let expiresAt = now().addingTimeInterval(lifetime)
        update(id) { $0.expiresAt = expiresAt }
    }

    func makePermanent(id: ShelfItem.ID) {
        update(id) { $0.expiresAt = nil }
    }

    /// "Rename": gives the tile a name of its own. The file and the link stay as they
    /// are. An empty name, or the automatic one, goes back to the automatic name, which
    /// then follows the file or the site again. Line breaks pasted in become spaces,
    /// since a tile's name is one line. Saves only if the name really changed.
    func rename(id: ShelfItem.ID, to name: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let cleaned = name.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let customName = cleaned.isEmpty || cleaned == item.title ? nil : cleaned
        guard customName != item.customName else { return }
        update(id) { $0.customName = customName }
    }

    /// Removes temporary items whose time is up and returns them.
    @discardableResult
    func removeExpired() -> [ShelfItem] {
        let date = now()
        let expired = items.filter { $0.isExpired(at: date) }
        guard !expired.isEmpty else { return [] }
        commit(items.filter { !$0.isExpired(at: date) })
        return expired
    }

    /// Records what a link's preview fetch found. A site name the page declares
    /// replaces the one taken from the address.
    func applyLinkPreview(id: ShelfItem.ID, siteName: String?, iconFileName: String?) {
        let fetchedAt = now()
        let trimmed = siteName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let declaredName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        update(id) { item in
            guard case .link(let url) = item.source else { return }
            item.title = LinkNaming.title(for: url, siteName: declaredName)
            item.linkPreview = ShelfItem.LinkPreview(fetchedAt: fetchedAt,
                                                     siteName: declaredName,
                                                     iconFileName: iconFileName)
        }
    }

    // MARK: - Copies

    func setCopying(_ id: ShelfItem.ID, _ isCopying: Bool) {
        if isCopying {
            copyingItemIDs.insert(id)
        } else {
            copyingItemIDs.remove(id)
        }
    }

    func setConverting(_ id: ShelfItem.ID, _ isConverting: Bool) {
        if isConverting {
            convertingItemIDs.insert(id)
        } else {
            convertingItemIDs.remove(id)
        }
    }

    /// Points a file item at Polka's copy instead of its original, and remembers the
    /// original so the item can go back to it. Returns false if the item is gone or
    /// is already a copy, in which case the new copy isn't used.
    @discardableResult
    func useCopy(id: ShelfItem.ID, at copy: URL) -> Bool {
        guard let item = items.first(where: { $0.id == id }),
              item.storageMode == .reference,
              case .file(let path, let bookmark) = item.source else { return false }
        update(id) { item in
            item.original = ShelfItem.Original(path: path, bookmark: bookmark)
            item.source = .file(path: copy.standardizedFileURL.path, bookmark: FileReference.bookmark(for: copy))
            item.storageMode = .copy
        }
        missingItemIDs.remove(id)
        return true
    }

    /// Points a kept copy back at its original, following it if it moved. Returns
    /// false, and keeps the copy, if the original can't be found.
    @discardableResult
    func useOriginal(id: ShelfItem.ID) -> Bool {
        guard let item = items.first(where: { $0.id == id }),
              item.storageMode == .copy,
              let original = item.original else { return false }
        var path = original.path
        var bookmark = original.bookmark
        switch FileReference.locate(path: path, bookmark: bookmark) {
        case .missing:
            return false
        case .unchanged:
            break
        case .updated(let newPath, let newBookmark):
            path = newPath
            bookmark = newBookmark
        }
        update(id) { item in
            item.source = .file(path: path, bookmark: bookmark)
            item.title = URL(fileURLWithPath: path).lastPathComponent
            item.storageMode = .reference
            item.original = nil
        }
        missingItemIDs.remove(id)
        return true
    }

    // MARK: - References

    /// Checks every file item against the disk. A moved or renamed file is followed
    /// through its bookmark, and one that is gone or in the Trash is marked missing.
    func refreshReferences() {
        var newItems = items
        var missing = Set<ShelfItem.ID>()
        var changed = false
        for index in newItems.indices {
            guard case .file(let path, let bookmark) = newItems[index].source else { continue }
            switch FileReference.locate(path: path, bookmark: bookmark) {
            case .unchanged:
                break
            case .updated(let newPath, let newBookmark):
                newItems[index].source = .file(path: newPath, bookmark: newBookmark)
                newItems[index].title = URL(fileURLWithPath: newPath).lastPathComponent
                changed = true
            case .missing:
                missing.insert(newItems[index].id)
            }
            // A kept copy's original is followed too, so the item can still go back to
            // it and so dropping it again is still caught as a duplicate.
            if let original = newItems[index].original,
               case .updated(let newPath, let newBookmark) = FileReference.locate(path: original.path,
                                                                                  bookmark: original.bookmark) {
                newItems[index].original = ShelfItem.Original(path: newPath, bookmark: newBookmark)
                changed = true
            }
        }
        if changed { commit(newItems) }
        if missing != missingItemIDs { missingItemIDs = missing }
    }

    private func update(_ id: ShelfItem.ID, _ change: (inout ShelfItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var newItems = items
        change(&newItems[index])
        commit(newItems)
    }

    /// Publishes a new list, sorted if the shelf is, and keeping each item's
    /// `sortOrder` equal to its position. Every change comes through here, so a
    /// sorted shelf stays sorted whatever changed: a new item, a renamed file, or a
    /// link whose site name just arrived.
    private func commit(_ newItems: [ShelfItem]) {
        items = Self.numbered(sort.arranged(newItems))
        do {
            try persistence.save(items)
        } catch {
            Log.storage.error("Could not save the shelf: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func numbered(_ items: [ShelfItem]) -> [ShelfItem] {
        items.enumerated().map { index, item in
            var item = item
            item.sortOrder = index
            return item
        }
    }
}
