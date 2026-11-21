import Combine
import Foundation

/// The shelf's contents, in the order they're shown. Unsorted, new items arrive at
/// the front, right after any pinned ones, and the user can move items anywhere in
/// their part of the shelf. Sorted (`sort`), the shelf stays in that order through
/// every change, like a Finder window with "Sort By" set. Pinned items always come
/// first (`ShelfSort.arranged`).
///
/// Shelf folders (FR-26) are items too, and so are the tiles in them, all in one
/// list: each tile says which folder it's in (`ShelfItem.folderID`), and the tiles of
/// one place, the shelf or a folder, keep their order among themselves (`items(in:)`).
/// Each place has its own sort (`sort(in:)`: the shelf's is a setting, a folder's is
/// saved with it) and its own pinned row, and is arranged on its own, in the slots
/// its tiles have in the list (`arranged(_:)`).
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
    /// Shelf folders being compressed right now ("Compress", FR-26). Not saved.
    @Published private(set) var compressingItemIDs: Set<ShelfItem.ID> = []
    /// The order the shelf itself keeps. Saved by whoever changes it (in UserDefaults),
    /// not here. Each shelf folder keeps its own (`sort(in:)`).
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
            items = Self.numbered(Self.arranged(Self.tidied(saved), shelfSort: sort))
        } catch {
            Log.storage.error("Could not load the shelf: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
            items = []
            loadFailed = true
        }
    }

    /// The tiles in one place, in order: the shelf itself (nil) or a shelf folder.
    func items(in folderID: ShelfItem.ID?) -> [ShelfItem] {
        items.filter { $0.folderID == folderID }
    }

    /// The shelf folder with this id, if there is one.
    func folder(_ id: ShelfItem.ID?) -> ShelfItem? {
        guard let id else { return nil }
        return items.first { $0.id == id && $0.isShelfFolder }
    }

    /// Adds new items to the front of the shelf or of the shelf folder `folderID`,
    /// after any pinned ones, in the order given, or right after the item `after`, in
    /// its place (a PDF lands next to the document it was made from), or to their
    /// sorted spots if the shelf is sorted. Anything already on the shelf, in any
    /// folder, is left where it is and reported in the result, so the UI can say so.
    @discardableResult
    func add(_ drafts: [ShelfItem.Draft],
             after neighborID: ShelfItem.ID? = nil,
             in folderID: ShelfItem.ID? = nil) -> AddResult {
        let neighbor = neighborID.flatMap { id in items.first { $0.id == id } }
        // A folder that's gone (removed meanwhile) means the shelf itself.
        let place = neighbor.map(\.folderID) ?? folder(folderID)?.id
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
                                      expiresAt: draft.lifetime.map { date.addingTimeInterval($0) },
                                      sortOrder: 0,
                                      origin: draft.origin,
                                      receivedFrom: draft.receivedFrom,
                                      folderID: place))
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
        remove(ids: [id])
        return true
    }

    /// Removes several shelf entries at once, with one save. The original files are
    /// never touched. A shelf folder's tiles aren't removed with it: they go back onto
    /// the shelf where the folder was (`removing(_:from:)`).
    func remove(ids: Set<ShelfItem.ID>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        commit(Self.removing(ids, from: items))
    }

    /// Moves items to a new place among the tiles of the shelf or of the shelf folder
    /// `folderID`, side by side and in the order they were in, with the first of them
    /// at `index`, counted among that place's tiles (see `moving(_:to:)`). Saves only
    /// if the order really changed. A sorted shelf keeps its order, so nothing moves.
    func move(_ ids: Set<ShelfItem.ID>, to index: Int, in folderID: ShelfItem.ID? = nil) {
        guard sort(in: folderID) == .none else { return }
        let place = items(in: folderID)
        let reordered = place.moving(ids, to: index)
        guard reordered.map(\.id) != place.map(\.id) else { return }
        commit(Self.replacing(folderID, with: reordered, in: items))
    }

    // MARK: - Shelf folders

    /// What a new shelf folder is called, as Finder calls a new folder, and with a
    /// number after it while one has that name already.
    nonisolated static let newFolderName = "Untitled Folder"

    /// "New Folder" (FR-26): an empty shelf folder at the front of the shelf, after
    /// any pinned tiles, or in its sorted spot. Folders are only ever on the shelf
    /// itself, never in another folder.
    @discardableResult
    func createFolder() -> ShelfItem {
        let name = Self.freeFolderName(among: items.filter(\.isShelfFolder).map(\.displayName))
        let folder = ShelfItem(id: UUID(),
                               kind: .shelfFolder,
                               title: name,
                               source: .shelfFolder,
                               storageMode: .reference,
                               createdAt: now(),
                               expiresAt: nil,
                               sortOrder: 0)
        var newItems = items
        newItems.insert(folder, at: 0)
        commit(newItems)
        return items.first { $0.id == folder.id } ?? folder
    }

    /// "Untitled Folder", or "Untitled Folder 2", 3 and so on, the first that no folder
    /// in `names` has. Case doesn't count, as in Finder.
    static func freeFolderName(among names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(newFolderName.lowercased()) else { return newFolderName }
        var number = 2
        while taken.contains("\(newFolderName) \(number)".lowercased()) {
            number += 1
        }
        return "\(newFolderName) \(number)"
    }

    /// How many tiles each shelf folder holds, by folder.
    var folderItemCounts: [ShelfItem.ID: Int] {
        var counts: [ShelfItem.ID: Int] = [:]
        for item in items {
            if let folderID = item.folderID { counts[folderID, default: 0] += 1 }
        }
        return counts
    }

    /// "Move To" (FR-26): tiles go into the shelf folder `folderID`, or back onto the
    /// shelf with nil. They arrive where new items do, at the front after the pinned
    /// tiles, or in their sorted spots, and side by side in the order they were in.
    /// They lose their pins, since a pin holds a tile in the first row of the place
    /// it's in. A folder never goes into a folder, and tiles already there stay where
    /// they are. Returns what moved.
    @discardableResult
    func move(_ ids: Set<ShelfItem.ID>, toFolder folderID: ShelfItem.ID?) -> [ShelfItem.ID] {
        if folderID != nil, folder(folderID) == nil { return [] }
        let moving = items.filter { item in
            ids.contains(item.id) && item.folderID != folderID && !(folderID != nil && item.isShelfFolder)
        }
        guard !moving.isEmpty else { return [] }
        let movingIDs = Set(moving.map(\.id))
        let arrived = moving.map { item -> ShelfItem in
            var item = item
            item.folderID = folderID
            item.pinned = nil
            return item
        }
        var newItems = items.filter { !movingIDs.contains($0.id) }
        // The front: pinned tiles come first again in `commit`.
        newItems.insert(contentsOf: arrived, at: 0)
        commit(newItems)
        return moving.map(\.id)
    }

    /// The order one place keeps: the shelf's own (`sort`) for nil, or a shelf
    /// folder's, which it keeps apart from the shelf's.
    func sort(in folderID: ShelfItem.ID?) -> ShelfSort {
        guard let folderID else { return sort }
        return folder(folderID)?.folderSort ?? .none
    }

    /// Changes the order the shelf itself keeps, or with `folderID` the order that
    /// shelf folder keeps, and sorts that place now; every other place keeps its own.
    /// Back on `none`, the tiles stay where the last sort put them, as in Finder, and
    /// can be moved from there. The shelf's choice is saved by the caller; a folder's
    /// goes into shelf.json with it.
    func setSort(_ newSort: ShelfSort, in folderID: ShelfItem.ID? = nil) {
        guard newSort != sort(in: folderID) else { return }
        guard let folderID else {
            sort = newSort
            let arranged = Self.arranged(items, shelfSort: newSort)
            guard arranged.map(\.id) != items.map(\.id) else { return }
            commit(arranged)
            return
        }
        update(folderID) { folder in
            guard folder.isShelfFolder else { return }
            folder.sortBy = newSort == .none ? nil : newSort.rawValue
        }
    }

    // MARK: - Pinning

    /// The most items the shelf pins: one row's worth, as the grid has five columns
    /// (FR-21).
    static let maxPinned = 5

    /// Every pinned item, in every place.
    var pinnedCount: Int {
        items.filter(\.isPinned).count
    }

    /// The pinned tiles of one place, the shelf or a shelf folder, each of which has a
    /// first row of its own.
    func pinnedCount(in folderID: ShelfItem.ID?) -> Int {
        items.filter { $0.isPinned && $0.folderID == folderID }.count
    }

    /// Pins an item to the first row of its place, the shelf or its folder. Unsorted,
    /// it goes to the end of that row; sorted, to its sorted spot there. Returns false,
    /// and pins nothing, when `maxPinned` items are pinned there already.
    @discardableResult
    func pin(id: ShelfItem.ID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return true }
        guard !items[index].isPinned else { return true }
        let folderID = items[index].folderID
        guard pinnedCount(in: folderID) < Self.maxPinned else { return false }
        var place = items(in: folderID)
        guard let spot = place.firstIndex(where: { $0.id == id }) else { return true }
        var item = place.remove(at: spot)
        item.pinned = true
        // A place's pinned tiles come first in it.
        place.insert(item, at: place.filter(\.isPinned).count)
        commit(Self.replacing(folderID, with: place, in: items))
        return true
    }

    /// Takes an item off the first row of its place. Unsorted, it becomes the first
    /// item after the pinned ones, where a new item would arrive; sorted, it goes to its
    /// sorted spot.
    func unpin(id: ShelfItem.ID) {
        guard let item = items.first(where: { $0.id == id }), item.isPinned else { return }
        var place = items(in: item.folderID)
        guard let spot = place.firstIndex(where: { $0.id == id }) else { return }
        var unpinned = place.remove(at: spot)
        unpinned.pinned = nil
        place.insert(unpinned, at: place.filter(\.isPinned).count)
        commit(Self.replacing(item.folderID, with: place, in: items))
    }

    /// Makes an item temporary: it is removed `lifetime` seconds from now. A shelf
    /// folder never expires.
    func makeTemporary(id: ShelfItem.ID, lifetime: TimeInterval) {
        let expiresAt = now().addingTimeInterval(lifetime)
        update(id) { item in
            guard !item.isShelfFolder else { return }
            item.expiresAt = expiresAt
        }
    }

    func makePermanent(id: ShelfItem.ID) {
        update(id) { $0.expiresAt = nil }
    }

    /// "Rename": gives the tile a name of its own. The file and the link stay as they
    /// are. An empty name, or the automatic one, goes back to the automatic name, which
    /// then follows the file or the site again. Line breaks pasted in become spaces,
    /// since a tile's name is one line. Saves only if the name really changed.
    ///
    /// A shelf folder has no automatic name to go back to: its name is the one given,
    /// and an empty one leaves it as it was, as in Finder.
    func rename(id: ShelfItem.ID, to name: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let cleaned = name.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if item.isShelfFolder {
            guard !cleaned.isEmpty, cleaned != item.title else { return }
            update(id) { $0.title = cleaned }
            return
        }
        let customName = cleaned.isEmpty || cleaned == item.title ? nil : cleaned
        guard customName != item.customName else { return }
        update(id) { $0.customName = customName }
    }

    /// "Rename File" or "Rename Folder" renamed the file on disk: the item points at
    /// where its file is now (`path`), and a kept copy at where its original is now
    /// (`originalPath`), either nil if it didn't move. The tile goes back to its
    /// automatic name, the new one, since a label left over would hide the change.
    func fileRenamed(id: ShelfItem.ID, to name: String, path: String?, originalPath: String?) {
        guard let item = items.first(where: { $0.id == id }), case .file = item.source else { return }
        update(id) { item in
            if let path {
                item.source = .file(path: path, bookmark: FileReference.bookmark(for: URL(fileURLWithPath: path)))
            }
            if let originalPath {
                item.original = ShelfItem.Original(path: originalPath,
                                                   bookmark: FileReference.bookmark(for: URL(fileURLWithPath: originalPath)))
            }
            item.title = name
            item.customName = nil
        }
    }

    enum AddressChange: Equatable {
        case changed
        /// The link already had this address.
        case unchanged
        /// Another tile has this link, and the shelf holds each link once.
        case duplicate
    }

    /// "Edit Address": the link points at `url` instead, named from its address until
    /// the new site's name and icon arrive (the old ones are dropped, so they're fetched
    /// again). A label given with "Rename Label" stays, since it names the tile, not
    /// the address. `url` must already be a web address (`LinkInput`).
    @discardableResult
    func changeAddress(id: ShelfItem.ID, to url: URL) -> AddressChange {
        guard let item = items.first(where: { $0.id == id }), case .link(let oldURL) = item.source else {
            return .unchanged
        }
        guard url != oldURL else { return .unchanged }
        let key = ShelfItem.Source.link(url).dedupeKey
        guard !items.contains(where: { $0.id != id && $0.dedupeKeys.contains(key) }) else { return .duplicate }
        update(id) { item in
            item.source = .link(url)
            item.title = LinkNaming.title(for: url, siteName: nil)
            item.linkPreview = nil
        }
        return .changed
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

    func setCompressing(_ id: ShelfItem.ID, _ isCompressing: Bool) {
        if isCompressing {
            compressingItemIDs.insert(id)
        } else {
            compressingItemIDs.remove(id)
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

    /// `list` without `ids`. A removed shelf folder's tiles, unless they're removed
    /// too, go back onto the shelf where the folder was, in their order. They lose
    /// their pins, as tiles moved out of a folder do.
    private static func removing(_ ids: Set<ShelfItem.ID>, from list: [ShelfItem]) -> [ShelfItem] {
        let removedFolders = Set(list.filter { ids.contains($0.id) && $0.isShelfFolder }.map(\.id))
        guard !removedFolders.isEmpty else { return list.filter { !ids.contains($0.id) } }
        var released: [ShelfItem.ID: [ShelfItem]] = [:]
        for item in list where !ids.contains(item.id) {
            guard let folderID = item.folderID, removedFolders.contains(folderID) else { continue }
            var item = item
            item.folderID = nil
            item.pinned = nil
            released[folderID, default: []].append(item)
        }
        return list.flatMap { item -> [ShelfItem] in
            if removedFolders.contains(item.id) { return released[item.id] ?? [] }
            if ids.contains(item.id) { return [] }
            if let folderID = item.folderID, removedFolders.contains(folderID) { return [] }
            return [item]
        }
    }

    /// `list` with the tiles of one place put back in the slots they had, in the
    /// order of `ordered`, which holds the same tiles. Every other place keeps its own.
    private static func replacing(_ folderID: ShelfItem.ID?,
                                  with ordered: [ShelfItem],
                                  in list: [ShelfItem]) -> [ShelfItem] {
        var next = ordered.makeIterator()
        return list.map { item in
            guard item.folderID == folderID, let replacement = next.next() else { return item }
            return replacement
        }
    }

    /// A saved shelf as Polka expects it: a tile whose folder is gone goes back onto
    /// the shelf, and a folder is never inside another. Neither happens in a shelf
    /// Polka saved, so this only catches a file changed by hand.
    private static func tidied(_ items: [ShelfItem]) -> [ShelfItem] {
        let folders = Set(items.filter(\.isShelfFolder).map(\.id))
        return items.map { item in
            guard let folderID = item.folderID, item.isShelfFolder || !folders.contains(folderID) else {
                return item
            }
            var item = item
            item.folderID = nil
            return item
        }
    }

    private func update(_ id: ShelfItem.ID, _ change: (inout ShelfItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var newItems = items
        change(&newItems[index])
        commit(newItems)
    }

    /// `list` with each place, the shelf and every shelf folder, in its own order
    /// (`ShelfSort.arranged`: pinned tiles first, then sorted if the place is), in the
    /// slots its tiles already have. The shelf's order is `shelfSort`; a folder's is
    /// its own.
    private static func arranged(_ list: [ShelfItem], shelfSort: ShelfSort) -> [ShelfItem] {
        var places: [ShelfItem.ID?: [ShelfItem]] = [:]
        for item in list {
            places[item.folderID, default: []].append(item)
        }
        let sorts = Dictionary(list.filter(\.isShelfFolder).map { ($0.id, $0.folderSort) },
                               uniquingKeysWith: { first, _ in first })
        var ordered: [ShelfItem.ID?: IndexingIterator<[ShelfItem]>] = [:]
        for (folderID, tiles) in places {
            let sort = folderID.map { sorts[$0] ?? .none } ?? shelfSort
            ordered[folderID] = sort.arranged(tiles).makeIterator()
        }
        return list.map { item in
            ordered[item.folderID]?.next() ?? item
        }
    }

    /// Publishes a new list, each place in its own order, and keeping each item's
    /// `sortOrder` equal to its position. Every change comes through here, so a
    /// sorted place stays sorted whatever changed: a new item, a renamed file, or a
    /// link whose site name just arrived.
    private func commit(_ newItems: [ShelfItem]) {
        items = Self.numbered(Self.arranged(newItems, shelfSort: sort))
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
