import Foundation

/// Where the shelf is kept between changes.
/// M2 keeps it in memory; the JSON file from M3 goes behind this same protocol.
protocol ShelfPersistence {
    func load() throws -> [ShelfItem]
    func save(_ items: [ShelfItem]) throws
}

final class InMemoryShelfPersistence: ShelfPersistence {
    private var stored: [ShelfItem]

    init(items: [ShelfItem] = []) {
        stored = items
    }

    func load() -> [ShelfItem] {
        stored
    }

    func save(_ items: [ShelfItem]) {
        stored = items
    }
}
