import Foundation
import Testing
@testable import Polka

@MainActor
struct JSONFileShelfPersistenceTests {
    /// A real, empty temporary folder, removed when `body` returns.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try body(folder)
    }

    private func sampleItems() -> [ShelfItem] {
        let date = Date(timeIntervalSinceReferenceDate: 784_000_123.456)
        return [
            ShelfItem(id: UUID(), kind: .file, title: "a.txt",
                      source: .file(path: "/tmp/a.txt", bookmark: Data([1, 2, 3])),
                      storageMode: .reference, createdAt: date, expiresAt: nil, sortOrder: 0),
            ShelfItem(id: UUID(), kind: .link, title: "example.com/a",
                      source: .link(URL(string: "https://example.com/a?b=1")!),
                      storageMode: .reference, createdAt: date,
                      expiresAt: date.addingTimeInterval(86_400), sortOrder: 1),
        ]
    }

    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func aMissingFileIsAnEmptyShelfAndIsNotCreated() throws {
        try withTemporaryFolder { folder throws in
            let persistence = JSONFileShelfPersistence(fileURL: folder.appendingPathComponent("shelf.json"))

            #expect(try persistence.load().isEmpty)
            #expect(try files(in: folder).isEmpty)
        }
    }

    @Test func savedItemsLoadBackExactly() throws {
        try withTemporaryFolder { folder in
            let fileURL = folder.appendingPathComponent("Nested/shelf.json")
            let items = sampleItems()

            try JSONFileShelfPersistence(fileURL: fileURL).save(items)
            let loaded = try JSONFileShelfPersistence(fileURL: fileURL).load()

            #expect(loaded == items)
        }
    }

    @Test func theFileIsVersionedJSON() throws {
        try withTemporaryFolder { folder in
            let fileURL = folder.appendingPathComponent("shelf.json")
            try JSONFileShelfPersistence(fileURL: fileURL).save(sampleItems())

            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]

            #expect(object?["version"] as? Int == 1)
            #expect((object?["items"] as? [Any])?.count == 2)
        }
    }

    @Test func anUnreadableFileIsMovedAsideNotOverwritten() throws {
        try withTemporaryFolder { folder in
            let fileURL = folder.appendingPathComponent("shelf.json")
            try Data("not json".utf8).write(to: fileURL)
            let persistence = JSONFileShelfPersistence(fileURL: fileURL)

            #expect(throws: (any Error).self) { try persistence.load() }
            try persistence.save(sampleItems())

            let names = try files(in: folder)
            #expect(names.count == 2)
            let keptName = try #require(names.first { $0.hasPrefix("shelf-unreadable-") })
            #expect(try Data(contentsOf: folder.appendingPathComponent(keptName)) == Data("not json".utf8))
            #expect(try persistence.load().count == 2)
        }
    }

    @Test func anUnreadableFileThatCannotBeMovedIsNeverSavedOver() throws {
        try withTemporaryFolder { folder in
            let fileURL = folder.appendingPathComponent("shelf.json")
            try Data("not json".utf8).write(to: fileURL)
            // A read-only folder: the file can be read but not renamed or replaced.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            let persistence = JSONFileShelfPersistence(fileURL: fileURL)

            #expect(throws: (any Error).self) { try persistence.load() }
            #expect(throws: JSONFileShelfPersistence.SavingBlocked.self) {
                try persistence.save(sampleItems())
            }
            #expect(try Data(contentsOf: fileURL) == Data("not json".utf8))
        }
    }

    @Test func aStoreComesBackTheSameAfterARelaunch() throws {
        try withTemporaryFolder { folder in
            let fileURL = folder.appendingPathComponent("shelf.json")
            let first = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: fileURL))
            first.add([
                ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.txt")),
                ShelfItem.Draft(linkURL: URL(string: "https://example.com")!),
            ])
            first.remove(id: first.items[0].id)
            first.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/b.txt"))])

            let second = ShelfStore(persistence: JSONFileShelfPersistence(fileURL: fileURL))

            #expect(second.items == first.items)
            #expect(second.items.map(\.title) == ["b.txt", "Example"])
        }
    }
}
