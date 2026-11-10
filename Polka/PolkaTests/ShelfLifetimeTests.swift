import Foundation
import Testing
@testable import Polka

/// Temporary and permanent items, expiry, and the lifetime setting.
@MainActor
struct ShelfLifetimeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func fileDraft(_ name: String) -> ShelfItem.Draft {
        ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    // MARK: - Store

    @Test func newItemsArePermanent() {
        let store = ShelfStore()
        store.add([fileDraft("a.txt")])

        #expect(!store.items[0].isTemporary)
    }

    @Test func makingAnItemTemporaryDatesItFromNow() {
        let store = ShelfStore(now: { start })
        store.add([fileDraft("a.txt")])

        store.makeTemporary(id: store.items[0].id, lifetime: 3600)

        #expect(store.items[0].expiresAt == start.addingTimeInterval(3600))
        #expect(store.items[0].isTemporary)
    }

    @Test func makingAnItemPermanentClearsItsExpiry() {
        let store = ShelfStore(now: { start })
        store.add([fileDraft("a.txt")])
        store.makeTemporary(id: store.items[0].id, lifetime: 3600)

        store.makePermanent(id: store.items[0].id)

        #expect(store.items[0].expiresAt == nil)
    }

    @Test func onlyItemsWhoseTimeIsUpAreRemoved() {
        var clock = start
        let store = ShelfStore(now: { clock })
        store.add([fileDraft("soon.txt"), fileDraft("later.txt"), fileDraft("forever.txt")])
        store.makeTemporary(id: store.items[0].id, lifetime: 60)
        store.makeTemporary(id: store.items[1].id, lifetime: 120)

        clock = start.addingTimeInterval(59)
        #expect(store.removeExpired().isEmpty)

        clock = start.addingTimeInterval(60)
        let removed = store.removeExpired()

        #expect(removed.map(\.title) == ["soon.txt"])
        #expect(store.items.map(\.title) == ["later.txt", "forever.txt"])
        #expect(store.items.map(\.sortOrder) == [0, 1])
    }

    @Test func anExpiredFileCanBeAddedAgain() {
        var clock = start
        let store = ShelfStore(now: { clock })
        store.add([fileDraft("a.txt")])
        store.makeTemporary(id: store.items[0].id, lifetime: 60)
        clock = start.addingTimeInterval(61)
        store.removeExpired()

        let result = store.add([fileDraft("a.txt")])

        #expect(result.added.count == 1)
        #expect(!store.items[0].isTemporary)
    }

    @Test func temporaryStateIsSaved() {
        let persistence = InMemoryShelfPersistence()
        let store = ShelfStore(persistence: persistence, now: { start })
        store.add([fileDraft("a.txt")])

        store.makeTemporary(id: store.items[0].id, lifetime: 60)

        #expect(persistence.load()[0].expiresAt == start.addingTimeInterval(60))
    }

    @Test func anUnknownItemIsLeftAlone() {
        let store = ShelfStore()
        store.add([fileDraft("a.txt")])

        store.makeTemporary(id: UUID(), lifetime: 60)

        #expect(!store.items[0].isTemporary)
    }

    // MARK: - Toggle

    @Test func theToggleSwitchesBetweenPermanentAndTemporary() {
        let store = ShelfStore(now: { start })
        let model = NotchViewModel(store: store, temporaryLifetime: { 90 })
        store.add([fileDraft("a.txt")])
        let id = store.items[0].id

        model.toggleTemporary(id)
        #expect(store.items[0].expiresAt == start.addingTimeInterval(90))

        model.toggleTemporary(id)
        #expect(store.items[0].expiresAt == nil)
    }

    // MARK: - Setting

    @Test func theLifetimeIs24HoursUnlessSet() throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ShelfSettings(defaults: defaults).temporaryLifetime == 24 * 60 * 60)

        defaults.set(30, forKey: ShelfSettings.temporaryLifetimeKey)
        #expect(ShelfSettings(defaults: defaults).temporaryLifetime == 30)

        defaults.set(-5, forKey: ShelfSettings.temporaryLifetimeKey)
        #expect(ShelfSettings(defaults: defaults).temporaryLifetime == 24 * 60 * 60)
    }

    @Test func aLifetimeChosenInSettingsIsUsedForTheNextTemporaryItem() throws {
        let suite = "PolkaTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShelfSettings(defaults: defaults)
        let store = ShelfStore(now: { start })
        store.add([fileDraft("old.txt"), fileDraft("new.txt")])
        let model = NotchViewModel(store: store, temporaryLifetime: { settings.temporaryLifetime })
        model.toggleTemporary(store.items[0].id)

        settings.temporaryLifetime = 3 * 60 * 60
        model.toggleTemporary(store.items[1].id)

        #expect(defaults.double(forKey: ShelfSettings.temporaryLifetimeKey) == 3 * 60 * 60)
        // The item made temporary before the change keeps its 24 hours.
        #expect(store.items[0].expiresAt == start.addingTimeInterval(24 * 60 * 60))
        #expect(store.items[1].expiresAt == start.addingTimeInterval(3 * 60 * 60))
    }

    @Test func settingsOffersTheStandardLifetimesPlusOneSetByHand() {
        let standard = ShelfSettings.standardTemporaryLifetimes
        #expect(standard.contains(ShelfSettings.defaultTemporaryLifetime))
        #expect(ShelfSettings.temporaryLifetimeChoices(current: 6 * 60 * 60) == standard)

        let byHand: TimeInterval = 30 * 60 * 60
        let choices = ShelfSettings.temporaryLifetimeChoices(current: byHand)
        #expect(choices.count == standard.count + 1)
        #expect(choices.contains(byHand))
        #expect(choices == choices.sorted())
    }

    @Test func lifetimesAreWrittenOutInWords() {
        #expect(ShelfSettings.label(forLifetime: 60 * 60) == "1 hour")
        #expect(ShelfSettings.label(forLifetime: 12 * 60 * 60) == "12 hours")
        #expect(ShelfSettings.label(forLifetime: 24 * 60 * 60) == "1 day")
        #expect(ShelfSettings.label(forLifetime: 3 * 24 * 60 * 60) == "3 days")
        #expect(ShelfSettings.label(forLifetime: 7 * 24 * 60 * 60) == "1 week")
        #expect(ShelfSettings.label(forLifetime: 30 * 60 * 60) == "1 day, 6 hours")
    }

    // MARK: - Time left label

    @Test func timeLeftIsRoundedUpToAFriendlyUnit() throws {
        let store = ShelfStore(now: { start })
        store.add([fileDraft("a.txt")])
        let id = store.items[0].id

        func label(_ lifetime: TimeInterval) -> String? {
            store.makeTemporary(id: id, lifetime: lifetime)
            return store.items[0].timeLeftLabel(now: start)
        }

        #expect(label(20) == "1m")
        #expect(label(45 * 60) == "45m")
        #expect(label(59 * 60 + 30) == "1h")
        #expect(label(24 * 3600) == "24h")
        #expect(label(47 * 3600 + 1) == "2d")
        #expect(label(-10) == "1m")

        store.makePermanent(id: id)
        #expect(store.items[0].timeLeftLabel(now: start) == nil)
    }
}

/// The sweeper uses a real timer, so these wait a moment of real time.
@MainActor
struct ExpirySweeperTests {
    private func item(_ name: String, expiresAt: Date?, sortOrder: Int) -> ShelfItem {
        ShelfItem(id: UUID(), kind: .file, title: name,
                  source: .file(path: "/tmp/\(name)", bookmark: nil),
                  storageMode: .reference, createdAt: Date(), expiresAt: expiresAt, sortOrder: sortOrder)
    }

    @Test func anItemThatExpiredWhilePolkaWasClosedIsGoneAtLaunch() {
        let saved = [
            item("expired.txt", expiresAt: Date().addingTimeInterval(-60), sortOrder: 0),
            item("keep.txt", expiresAt: nil, sortOrder: 1),
        ]
        let store = ShelfStore(persistence: InMemoryShelfPersistence(items: saved))

        let sweeper = ExpirySweeper(store: store)
        sweeper.start()

        #expect(store.items.map(\.title) == ["keep.txt"])
    }

    @Test func anItemDisappearsWhenItsTimeIsUp() async throws {
        let store = ShelfStore()
        store.add([ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/a.txt")),
                   ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/b.txt"))])
        let sweeper = ExpirySweeper(store: store)
        sweeper.start()

        store.makeTemporary(id: store.items[0].id, lifetime: 0.3)
        #expect(store.items.count == 2)

        try await Task.sleep(for: .seconds(2))
        #expect(store.items.map(\.title) == ["b.txt"])
    }
}
