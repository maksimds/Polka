import AppKit
import Combine

/// Keeps Polka's copies in step with the shelf. It makes a copy when an item is set to
/// keep one, receives the files apps hand over by promise, and deletes a copy once no
/// item uses it: when the item is removed, expires, or goes back to its original.
///
/// Originals are never deleted. Only copy folders inside Polka's Copies folder are.
@MainActor
final class CopyKeeper {
    private let store: ShelfStore
    private let copies: ShelfCopies
    /// Copy folders the shelf used at the last change, so a folder that drops out of
    /// use can be deleted. A folder still being written isn't in use yet, so it is
    /// never deleted from under the copy.
    private var foldersInUse = Set<String>()
    private var watcher: AnyCancellable?
    /// Where apps write promised files from. The files land in the Copies folder.
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(store: ShelfStore, copies: ShelfCopies) {
        self.store = store
        self.copies = copies
    }

    func start() {
        removeLeftovers()
        foldersInUse = folders(usedBy: store.items)
        watcher = store.$items.sink { [weak self] items in
            self?.removeCopiesNoLongerUsed(by: items)
        }
    }

    // MARK: - Keeping a copy

    /// Copies a file item's original into Polka's folder in the background, then
    /// points the item at the copy. Returns false if the copy couldn't be made.
    func keepCopy(of id: ShelfItem.ID) async -> Bool {
        guard let item = store.items.first(where: { $0.id == id }),
              item.storageMode == .reference,
              case .file(let path, _) = item.source,
              !store.copyingItemIDs.contains(id) else { return false }

        store.setCopying(id, true)
        defer { store.setCopying(id, false) }

        let copies = self.copies
        let original = URL(fileURLWithPath: path)
        // A large file or folder can take a while, so the copy runs off the main thread.
        let result = await Task.detached(priority: .userInitiated) {
            Result { try copies.copy(original) }
        }.value

        switch result {
        case .success(let copy):
            guard store.useCopy(id: id, at: copy) else {
                // The item was removed, or changed, while it was being copied.
                if let name = copies.folderName(containing: copy.path) {
                    copies.removeFolder(named: name)
                }
                return false
            }
            Log.storage.info("Keeping a copy of \(item.title, privacy: .private)")
            return true
        case .failure(let error):
            Log.storage.error("""
                Could not copy \(item.title, privacy: .private): \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)
                """)
            return false
        }
    }

    // MARK: - File promises

    /// Asks the app a drag came from to write its promised files into new copy folders.
    /// Each file is added to the shelf when it arrives, which can be a moment later.
    ///
    /// Call it during the drop itself (`performDragOperation`): a promise has to be
    /// asked for while the drag is still going.
    func receive(_ promises: [NSFilePromiseReceiver],
                 onFailure: @escaping @MainActor (_ fileName: String?) -> Void) {
        for promise in promises {
            let destination: URL
            do {
                destination = try copies.makeFolder()
            } catch {
                Log.drop.error("No folder for a promised file: \(error.logCode, privacy: .public), \(error.localizedDescription, privacy: .private)")
                onFailure(nil)
                continue
            }
            // The reader runs on `promiseQueue`, once per file, after the app has written it.
            promise.receivePromisedFiles(atDestination: destination,
                                         options: [:],
                                         operationQueue: promiseQueue) { [weak self] url, error in
                let failure = error?.localizedDescription
                Task { @MainActor in
                    self?.promisedFileArrived(at: url, failure: failure, onFailure: onFailure)
                }
            }
        }
    }

    /// Adds a promised file once the app has written it. If it failed, the empty
    /// folder is cleared away at the next launch.
    func promisedFileArrived(at url: URL,
                             failure: String?,
                             onFailure: @MainActor (_ fileName: String?) -> Void) {
        let name = url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
        if let failure {
            Log.drop.error("A promised file didn't arrive: \(failure, privacy: .private)")
            onFailure(name)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.drop.error("A promised file was reported but isn't on disk")
            onFailure(name)
            return
        }
        // Apps write where they're asked, but anything that lands elsewhere is only
        // ever referenced, so Polka never deletes it.
        let mode: ShelfItem.StorageMode = copies.folderName(containing: url.path) != nil ? .copy : .reference
        Log.drop.info("Received promised file \(url.lastPathComponent, privacy: .private)")
        store.add([ShelfItem.Draft(fileURL: url, storageMode: mode)])
    }

    // MARK: - Cleaning up

    private func folders(usedBy items: [ShelfItem]) -> Set<String> {
        Set(items.compactMap { item -> String? in
            guard item.storageMode == .copy, case .file(let path, _) = item.source else { return nil }
            return copies.folderName(containing: path)
        })
    }

    private func removeCopiesNoLongerUsed(by items: [ShelfItem]) {
        let used = folders(usedBy: items)
        for name in foldersInUse.subtracting(used) {
            copies.removeFolder(named: name)
        }
        foldersInUse = used
    }

    /// Clears out copy folders no item uses, left behind when Polka quit mid-copy or an
    /// app didn't deliver a promised file. Skipped when the saved shelf couldn't be
    /// read, because the items in it may still need their copies.
    private func removeLeftovers() {
        guard !store.loadFailed else {
            Log.storage.info("The shelf couldn't be read, so leftover copies are kept")
            return
        }
        let used = folders(usedBy: store.items)
        let leftovers = copies.folderNames().filter { !used.contains($0) }
        for name in leftovers {
            copies.removeFolder(named: name)
        }
        if !leftovers.isEmpty {
            Log.storage.info("Removed \(leftovers.count) unused copy folder(s)")
        }
    }
}
