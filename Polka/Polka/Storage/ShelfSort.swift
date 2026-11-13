import Foundation

/// How the shelf keeps its tiles in order, like Finder's "Sort By". `none` is the
/// order you arrange by hand. Any other choice keeps the shelf sorted: new items land
/// in their sorted spot, and tiles can't be moved by hand until it's back on `none`.
/// Kind and File Type also show the tiles in titled groups (`groups(of:)`). Pinned
/// items come first in every order.
enum ShelfSort: String, CaseIterable {
    case none
    case name
    case kind
    case fileType
    case dateAdded

    /// The name in the "Sort By" menu, in Finder's words.
    var title: String {
        switch self {
        case .none: return "None"
        case .name: return "Name"
        case .kind: return "Kind"
        case .fileType: return "File Type"
        case .dateAdded: return "Date Added"
        }
    }

    /// True for the orders whose tiles show in titled groups: Kind and File Type.
    var showsGroups: Bool {
        groupingKey != nil
    }

    /// The groups `items` fall into, in order, each one a run of neighbors, each
    /// starting a new row. Pinned items come first, as a group with no title, so they
    /// have the first row to themselves. Then, in an order with groups (Kind, File
    /// Type), each titled group; in one without, the rest as one untitled group, but
    /// only after pinned items, since a plain grid needs no groups at all. Expects the
    /// items already in this order (`arranged`), so each title comes up once.
    func groups(of items: [ShelfItem]) -> [ShelfGroup] {
        let pinnedCount = items.prefix { $0.isPinned }.count
        var groups = pinnedCount > 0 ? [ShelfGroup(title: nil, count: pinnedCount)] : []
        let rest = items.dropFirst(pinnedCount)
        guard let groupingKey else {
            if !groups.isEmpty, !rest.isEmpty {
                groups.append(ShelfGroup(title: nil, count: rest.count))
            }
            return groups
        }
        var titled: [ShelfGroup] = []
        for item in rest {
            let title = groupingKey(item).title
            if titled.last?.title == title {
                titled[titled.count - 1].count += 1
            } else {
                titled.append(ShelfGroup(title: title, count: 1))
            }
        }
        return groups + titled
    }

    /// The items in this order, pinned ones first (FR-21), each part sorted on its own.
    /// Items that tie keep the order they came in, so a shelf that's already sorted
    /// never shuffles. `none` only brings the pinned ones forward.
    func arranged(_ items: [ShelfItem]) -> [ShelfItem] {
        sorted(items.filter(\.isPinned)) + sorted(items.filter { !$0.isPinned })
    }

    private func sorted(_ items: [ShelfItem]) -> [ShelfItem] {
        guard self != .none else { return items }
        return items.enumerated()
            .sorted { a, b in
                switch compare(a.element, b.element) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.offset < b.offset
                }
            }
            .map(\.element)
    }

    private func compare(_ a: ShelfItem, _ b: ShelfItem) -> ComparisonResult {
        if let groupingKey {
            // Group by group, then A to Z by name within each.
            let groupA = groupingKey(a)
            let groupB = groupingKey(b)
            if groupA.rank != groupB.rank {
                return groupA.rank < groupB.rank ? .orderedAscending : .orderedDescending
            }
            let titles = groupA.title.localizedStandardCompare(groupB.title)
            if titles != .orderedSame { return titles }
            return Self.compareNames(a, b)
        }
        switch self {
        case .name:
            return Self.compareNames(a, b)
        case .dateAdded:
            // Newest first, which is also where new items arrive on an unsorted shelf.
            if a.createdAt == b.createdAt { return .orderedSame }
            return a.createdAt > b.createdAt ? .orderedAscending : .orderedDescending
        case .none, .kind, .fileType:
            return .orderedSame
        }
    }

    /// Which group an item is in, for the orders that have groups: where the group
    /// goes (lower first) and its title. Groups of the same rank go A to Z by title.
    private var groupingKey: ((ShelfItem) -> (rank: Int, title: String))? {
        switch self {
        case .kind:
            // Folders first, as in Finder, then files, then links, then text.
            return { item in
                switch item.kind {
                case .folder: return (0, "Folders")
                case .file: return (1, "Files")
                case .link: return (2, "Links")
                case .text: return (3, "Text")
                }
            }
        case .fileType:
            // Folders first, then a group per extension from A to Z, then files with
            // no extension, then links, then text. "pdf" and "PDF" are one group.
            return { item in
                switch item.kind {
                case .folder:
                    return (0, "Folders")
                case .file:
                    let fileExtension = item.url.pathExtension
                    return fileExtension.isEmpty ? (2, "Other") : (1, fileExtension.uppercased())
                case .link:
                    return (3, "Links")
                case .text:
                    return (4, "Text")
                }
            }
        case .none, .name, .dateAdded:
            return nil
        }
    }

    /// The tile's name, a given one included, compared the way Finder compares names:
    /// case doesn't count, and numbers count as numbers, so "file2" comes before "file10".
    private static func compareNames(_ a: ShelfItem, _ b: ShelfItem) -> ComparisonResult {
        a.displayName.localizedStandardCompare(b.displayName)
    }
}

/// One group of tiles, such as "Folders" or "PDF" in a grouped order: a run of
/// `count` neighbors on the shelf, starting a new row.
struct ShelfGroup: Equatable {
    /// Nil for a group shown without a title: the pinned tiles, and the rest of a
    /// shelf whose order has no groups.
    let title: String?
    var count: Int
}
