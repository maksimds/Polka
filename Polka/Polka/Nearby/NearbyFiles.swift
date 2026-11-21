import CoreServices
import CryptoKit
import Foundation

/// Writes the files of one accepted offer as they arrive, each into a new copy folder
/// of its own (`Copies/<UUID>/`), on a queue of its own so the main thread only hands
/// bytes over.
///
/// A file is written as a hidden `.partial` file, hashed as it's written, and only once
/// its last byte is in and the hash matches the sender's is it quarantined, like a
/// download, and given its name. If anything goes wrong, or the transfer is cancelled,
/// every folder it made is deleted, so a half-received file never becomes a tile.
final class NearbyFileSink: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// The disk refused: full, or the folder couldn't be made.
        case cantWrite
        /// What arrived isn't what the sender read.
        case hashMismatch
    }

    /// Something went wrong. Called once, on the main thread; the caller should end the
    /// transfer, which discards what was written.
    var onFailure: (@MainActor (Failure) -> Void)?

    private let copies: ShelfCopies
    /// Each file's cleaned name, by its place in the offer.
    private let names: [Int: String]
    private let queue = DispatchQueue(label: "com.maksimds.Polka.nearby.sink", qos: .userInitiated)

    // Only touched on `queue`.
    private var current: Writing?
    private var written: [Int: URL] = [:]
    private var folders: [URL] = []
    private var failed = false
    private var handedOver = false

    private struct Writing {
        let index: Int
        let folder: URL
        let partial: URL
        let handle: FileHandle
        var hasher = SHA256()
    }

    /// The hidden name a file has while it arrives.
    static let partialName = ".polka-receiving.partial"

    init(copies: ShelfCopies, names: [Int: String]) {
        self.copies = copies
        self.names = names
    }

    /// The next bytes of the file at `index`. The first bytes of a file start it.
    func write(_ data: Data, to index: Int) {
        queue.async { [self] in
            guard !failed, !handedOver, let writing = start(index) else { return }
            current?.hasher.update(data: data)
            do {
                try writing.handle.write(contentsOf: data)
            } catch {
                Log.nearby.error("Couldn't write a received file: \(error.logCode, privacy: .public)")
                fail(.cantWrite)
            }
        }
    }

    /// The file at `index` is all in: checks it against `sha256`, then quarantines it and
    /// gives it its name. A file with no bytes starts and ends here.
    func end(_ index: Int, sha256: Data) {
        queue.async { [self] in
            guard !failed, !handedOver, start(index) != nil, let writing = current else { return }
            current = nil
            try? writing.handle.close()
            guard Data(writing.hasher.finalize()) == sha256 else {
                Log.nearby.error("A received file didn't match its hash")
                fail(.hashMismatch)
                return
            }
            do {
                written[index] = try finish(writing)
            } catch {
                Log.nearby.error("Couldn't finish a received file: \(error.logCode, privacy: .public)")
                fail(.cantWrite)
            }
        }
    }

    /// Everything has arrived: where each file now is, by its place in the offer, once
    /// every write before this is done. From then on the files are the shelf's, and
    /// `discard` leaves them alone. Nil if something went wrong.
    func handOver(completion: @escaping @MainActor ([Int: URL]?) -> Void) {
        queue.async { [self] in
            let result = failed || current != nil ? nil : written
            if result != nil { handedOver = true }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Deletes every folder it made, unless they were handed over.
    func discard() {
        queue.async { [self] in
            guard !handedOver else { return }
            try? current?.handle.close()
            current = nil
            failed = true
            for folder in folders {
                copies.removeFolder(named: folder.lastPathComponent)
            }
            if !folders.isEmpty {
                Log.nearby.info("Removed \(self.folders.count, privacy: .public) partly received file(s)")
            }
            folders = []
            written = [:]
        }
    }

    // MARK: - On the queue

    /// The file being written, started if `index` is a new one.
    private func start(_ index: Int) -> Writing? {
        if let current, current.index == index { return current }
        guard current == nil, written[index] == nil, names[index] != nil else {
            fail(.cantWrite)
            return nil
        }
        do {
            let folder = try copies.makeFolder()
            folders.append(folder)
            let partial = folder.appendingPathComponent(Self.partialName)
            // A new file only, never through a link: the folder is brand new, but this
            // costs nothing.
            let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            current = Writing(index: index, folder: folder, partial: partial,
                              handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
            return current
        } catch {
            Log.nearby.error("Couldn't start a received file: \(error.logCode, privacy: .public)")
            fail(.cantWrite)
            return nil
        }
    }

    private func finish(_ writing: Writing) throws -> URL {
        let name = names[writing.index] ?? NearbyFileName.fallback
        let destination = writing.folder.appendingPathComponent(name)
        // The name was cleaned on arrival, so it has no "/" and can't leave the folder;
        // checked again here, since this is where it would matter.
        guard destination.deletingLastPathComponent().standardizedFileURL.path
                == writing.folder.standardizedFileURL.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        chmod(writing.partial.path, 0o644)
        try Self.quarantine(writing.partial)
        // Never over anything: the folder holds only this file.
        guard renamex_np(writing.partial.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }

    private func fail(_ failure: Failure) {
        guard !failed else { return }
        failed = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFailure?(failure) }
        }
    }

    /// Marks a file as downloaded by Polka (`com.apple.quarantine`), so macOS checks it
    /// the first time it's opened, as it does a file from a browser (NS-9). Polka isn't
    /// sandboxed, so nothing it writes is quarantined on its own.
    static func quarantine(_ file: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Polka",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var url = file
        try url.setResourceValues(values)
    }
}

/// Reads one file to send, a piece at a time, through one open handle, hashing exactly
/// the bytes it hands over. It sends as many bytes as the offer said, no more: a file
/// that grew since is cut there, and one that shrank fails, since the other Mac is
/// waiting for the rest.
final class NearbyFileSource: @unchecked Sendable {
    enum Chunk: Equatable {
        case piece(Data)
        /// Every byte has been read: the SHA-256 of them all.
        case end(sha256: Data)
    }

    enum Failure: Error, Equatable {
        case unreadable
        /// It's shorter than it was when the offer was made.
        case changed
    }

    private let url: URL
    private let size: Int64
    private let queue = DispatchQueue(label: "com.maksimds.Polka.nearby.source", qos: .userInitiated)

    // Only touched on `queue`.
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var remaining: Int64
    private var isClosed = false

    init(url: URL, size: Int64) {
        self.url = url
        self.size = size
        remaining = size
    }

    /// The next piece, or the end with the hash, on the main thread.
    func next(completion: @escaping @MainActor (Result<Chunk, Failure>) -> Void) {
        queue.async { [self] in
            let result = read()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    func close() {
        queue.async { [self] in
            isClosed = true
            try? handle?.close()
            handle = nil
        }
    }

    private func read() -> Result<Chunk, Failure> {
        guard !isClosed else { return .failure(.unreadable) }
        if handle == nil {
            guard let opened = try? FileHandle(forReadingFrom: url) else { return .failure(.unreadable) }
            handle = opened
        }
        guard remaining > 0 else {
            try? handle?.close()
            handle = nil
            isClosed = true
            return .success(.end(sha256: Data(hasher.finalize())))
        }
        let count = Int(min(Int64(NearbyProtocol.maxPieceBytes), remaining))
        let data: Data
        do {
            // Nil at the end of the file.
            data = try handle?.read(upToCount: count) ?? Data()
        } catch {
            return .failure(.unreadable)
        }
        guard !data.isEmpty else { return .failure(.changed) }
        hasher.update(data: data)
        remaining -= Int64(data.count)
        return .success(.piece(data))
    }
}
