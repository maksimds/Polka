import Combine
import Foundation

/// The shelf's contents, newest first.
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

    private let persistence: ShelfPersistence
    private let now: () -> Date

    init(persistence: ShelfPersistence = InMemoryShelfPersistence(),
         now: @escaping () -> Date = { Date() }) {
        self.persistence = persistence
        self.now = now
        do {
            items = try persistence.load().sorted { $0.sortOrder < $1.sortOrder }
        } catch {
            Log.storage.error("Could not load the shelf: \(error.localizedDescription, privacy: .public)")
            items = []
        }
    }

    /// Adds new items to the front, in the order given. Anything already on the shelf
    /// is left where it is and reported in the result, so the UI can say so.
    @discardableResult
    func add(_ drafts: [ShelfItem.Draft]) -> AddResult {
        var seen = Set(items.map(\.source.dedupeKey))
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
                                      storageMode: .reference,
                                      createdAt: date,
                                      expiresAt: nil,
                                      sortOrder: 0))
        }

        if !newItems.isEmpty {
            commit(newItems + items)
        }
        return AddResult(added: Array(items.prefix(newItems.count)), duplicates: duplicates)
    }

    /// Removes the shelf entry only. The original file is never touched.
    @discardableResult
    func remove(id: ShelfItem.ID) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        commit(items.filter { $0.id != id })
        return true
    }

    /// Makes an item temporary: it is removed `lifetime` seconds from now.
    func makeTemporary(id: ShelfItem.ID, lifetime: TimeInterval) {
        let expiresAt = now().addingTimeInterval(lifetime)
        update(id) { $0.expiresAt = expiresAt }
    }

    func makePermanent(id: ShelfItem.ID) {
        update(id) { $0.expiresAt = nil }
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

    /// Publishes a new list, keeping each item's `sortOrder` equal to its position.
    private func commit(_ newItems: [ShelfItem]) {
        items = newItems.enumerated().map { index, item in
            var item = item
            item.sortOrder = index
            return item
        }
        do {
            try persistence.save(items)
        } catch {
            Log.storage.error("Could not save the shelf: \(error.localizedDescription, privacy: .public)")
        }
    }
}
