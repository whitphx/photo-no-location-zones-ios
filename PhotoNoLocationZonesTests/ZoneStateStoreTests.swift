import XCTest
@testable import PhotoNoLocationZones

@MainActor
final class ZoneStateStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "ZoneStateStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func test_default_state_is_empty() {
        let store = ZoneStateStore(defaults: defaults)
        XCTAssertTrue(store.activeZoneIds.isEmpty)
        XCTAssertFalse(store.isAnyZoneActive)
        XCTAssertNil(store.lastSeenAssetId)
    }

    func test_markEntered_adds_to_active_set() {
        let store = ZoneStateStore(defaults: defaults)
        let a = UUID(), b = UUID()
        store.markEntered([a, b])
        XCTAssertEqual(store.activeZoneIds, [a, b])
        XCTAssertTrue(store.isAnyZoneActive)
    }

    func test_markEntered_is_idempotent_for_repeated_ids() {
        let store = ZoneStateStore(defaults: defaults)
        let a = UUID()
        store.markEntered([a])
        store.markEntered([a])
        XCTAssertEqual(store.activeZoneIds, [a])
    }

    func test_markExited_removes_from_active_set() {
        let store = ZoneStateStore(defaults: defaults)
        let a = UUID(), b = UUID()
        store.markEntered([a, b])
        store.markExited([a])
        XCTAssertEqual(store.activeZoneIds, [b])
    }

    func test_markExited_for_unknown_id_is_a_noop() {
        let store = ZoneStateStore(defaults: defaults)
        let a = UUID(), unknown = UUID()
        store.markEntered([a])
        store.markExited([unknown])
        XCTAssertEqual(store.activeZoneIds, [a])
    }

    func test_forget_is_an_alias_for_markExited() {
        let store = ZoneStateStore(defaults: defaults)
        let a = UUID(), b = UUID()
        store.markEntered([a, b])
        store.forget([b])
        XCTAssertEqual(store.activeZoneIds, [a])
    }

    func test_clearActiveZones_drops_active_zones_but_preserves_cursor() {
        let store = ZoneStateStore(defaults: defaults)
        store.markEntered([UUID()])
        store.setLastSeenAssetId("photo-1")
        store.clearActiveZones()
        XCTAssertTrue(store.activeZoneIds.isEmpty)
        XCTAssertEqual(store.lastSeenAssetId, "photo-1",
            "the asset cursor must survive an active-zone clear so catchup doesn't re-scan history")
    }

    func test_state_survives_a_new_store_instance() {
        let a = UUID()
        do {
            let store = ZoneStateStore(defaults: defaults)
            store.markEntered([a])
            store.setLastSeenAssetId("abc")
        }
        let restored = ZoneStateStore(defaults: defaults)
        XCTAssertEqual(restored.activeZoneIds, [a])
        XCTAssertEqual(restored.lastSeenAssetId, "abc")
    }

    func test_setLastSeenAssetId_to_nil_clears_the_cursor() {
        let store = ZoneStateStore(defaults: defaults)
        store.setLastSeenAssetId("photo-1")
        store.setLastSeenAssetId(nil)
        XCTAssertNil(store.lastSeenAssetId)
    }

    func test_setLastSeenAssetId_overwrites_an_existing_cursor() {
        let store = ZoneStateStore(defaults: defaults)
        store.setLastSeenAssetId("photo-1")
        store.setLastSeenAssetId("photo-2")
        XCTAssertEqual(store.lastSeenAssetId, "photo-2")
    }
}
