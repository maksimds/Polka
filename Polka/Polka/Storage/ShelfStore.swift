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
