import XCTest
@testable import PhotoNoLocationZones

final class ZoneStateStoreTests: XCTestCase {

    /// In-memory `KeyValueStore` so tests don't touch the device's shared `UserDefaults`.
    private final class InMemoryStore: KeyValueStore {
        private var storage: [String: Any] = [:]

        func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }
        func string(forKey key: String) -> String? { storage[key] as? String }
        func set(_ value: Any?, forKey key: String) {
            if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
    }

    private var memoryStore: InMemoryStore!

    override func setUp() {
        super.setUp()
        memoryStore = InMemoryStore()
    }

    override func tearDown() {
        memoryStore = nil
        super.tearDown()
    }

    private func makeStore() -> ZoneStateStore {
        ZoneStateStore(store: memoryStore)
    }

    func test_default_state_is_empty() {
        let store = makeStore()
        XCTAssertTrue(store.activeZoneIds.isEmpty)
        XCTAssertFalse(store.isAnyZoneActive)
        XCTAssertNil(store.lastSeenAssetId)
    }

    func test_markEntered_adds_to_active_set() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.markEntered([a, b])
        XCTAssertEqual(store.activeZoneIds, [a, b])
        XCTAssertTrue(store.isAnyZoneActive)
    }

    func test_markEntered_is_idempotent_for_repeated_ids() {
        let store = makeStore()
        let a = UUID()
        store.markEntered([a])
        store.markEntered([a])
        XCTAssertEqual(store.activeZoneIds, [a])
    }

    func test_markExited_removes_from_active_set() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.markEntered([a, b])
        store.markExited([a])
        XCTAssertEqual(store.activeZoneIds, [b])
    }

    func test_markExited_for_unknown_id_is_a_noop() {
        let store = makeStore()
        let a = UUID(), unknown = UUID()
        store.markEntered([a])
        store.markExited([unknown])
        XCTAssertEqual(store.activeZoneIds, [a])
    }

    func test_forget_is_an_alias_for_markExited() {
        let store = makeStore()
        let a = UUID(), b = UUID()
        store.markEntered([a, b])
        store.forget([b])
        XCTAssertEqual(store.activeZoneIds, [a])
    }

    func test_clearActiveZones_drops_active_zones_but_preserves_cursor() {
        let store = makeStore()
        store.markEntered([UUID()])
        store.setLastSeenAssetId("photo-1")
        store.clearActiveZones()
        XCTAssertTrue(store.activeZoneIds.isEmpty)
        XCTAssertEqual(store.lastSeenAssetId, "photo-1",
            "the asset cursor must survive an active-zone clear so catchup doesn't re-scan history")
    }

    func test_state_survives_a_new_store_instance_against_the_same_backing_store() {
        let a = UUID()
        do {
            let store = makeStore()
            store.markEntered([a])
            store.setLastSeenAssetId("abc")
        }
        let restored = makeStore()
        XCTAssertEqual(restored.activeZoneIds, [a])
        XCTAssertEqual(restored.lastSeenAssetId, "abc")
    }

    func test_setLastSeenAssetId_to_nil_clears_the_cursor() {
        let store = makeStore()
        store.setLastSeenAssetId("photo-1")
        store.setLastSeenAssetId(nil)
        XCTAssertNil(store.lastSeenAssetId)
    }

    func test_setLastSeenAssetId_overwrites_an_existing_cursor() {
        let store = makeStore()
        store.setLastSeenAssetId("photo-1")
        store.setLastSeenAssetId("photo-2")
        XCTAssertEqual(store.lastSeenAssetId, "photo-2")
    }
}
