import XCTest
import CoreLocation
@testable import PhotoNoLocationZones

final class GeofenceControllerTests: XCTestCase {

    /// Mock `LocationMonitor` that records start/stop calls and lets tests drive
    /// authorization status + monitoredRegions explicitly.
    private final class MockMonitor: LocationMonitor {
        var delegate: CLLocationManagerDelegate?
        var monitoredRegions: Set<CLRegion> = []
        var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
        var requestAlwaysCount = 0

        func startMonitoring(for region: CLRegion) {
            monitoredRegions.insert(region)
        }

        func stopMonitoring(for region: CLRegion) {
            monitoredRegions.remove(region)
        }

        func requestAlwaysAuthorization() {
            requestAlwaysCount += 1
        }
    }

    /// In-memory KV store so tests can inspect ZoneStateStore writes without touching
    /// shared `UserDefaults`.
    private final class InMemoryStore: KeyValueStore {
        private var storage: [String: Any] = [:]
        func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }
        func string(forKey key: String) -> String? { storage[key] as? String }
        func set(_ value: Any?, forKey key: String) {
            if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        }
        func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
    }

    private var monitor: MockMonitor!
    private var stateStore: ZoneStateStore!
    private var controller: GeofenceController!

    override func setUp() {
        super.setUp()
        monitor = MockMonitor()
        stateStore = ZoneStateStore(store: InMemoryStore())
        controller = GeofenceController(
            monitor: monitor,
            stateStore: stateStore,
            isMonitoringAvailable: { true }
        )
    }

    override func tearDown() {
        controller = nil
        stateStore = nil
        monitor = nil
        super.tearDown()
    }

    // MARK: syncAll — diff logic

    func test_syncAll_starts_regions_for_new_zones() throws {
        let a = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        let b = Zone(name: "Office", latitude: 35.1, longitude: 139.1)
        try controller.syncAll(zones: [a, b])
        XCTAssertEqual(controller.monitoredRegionIds, [a.id.uuidString, b.id.uuidString])
    }

    func test_syncAll_stops_regions_for_removed_zones() throws {
        let a = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        let b = Zone(name: "Office", latitude: 35.1, longitude: 139.1)
        try controller.syncAll(zones: [a, b])
        try controller.syncAll(zones: [a]) // dropped b
        XCTAssertEqual(controller.monitoredRegionIds, [a.id.uuidString])
    }

    func test_syncAll_restarts_a_region_whose_center_changed() throws {
        let original = Zone(id: UUID(), name: "Home", latitude: 35.0, longitude: 139.0)
        try controller.syncAll(zones: [original])
        let centerStart = (monitor.monitoredRegions.first as? CLCircularRegion)?.center.latitude
        XCTAssertEqual(centerStart, 35.0)

        let moved = Zone(id: original.id, name: original.name, latitude: 36.0, longitude: 139.0)
        try controller.syncAll(zones: [moved])

        XCTAssertEqual(controller.monitoredRegionIds, [original.id.uuidString])
        let centerAfter = (monitor.monitoredRegions.first as? CLCircularRegion)?.center.latitude
        XCTAssertEqual(centerAfter, 36.0,
            "the region must be re-registered with the new center, not silently kept stale")
    }

    func test_syncAll_restarts_a_region_whose_radius_changed() throws {
        let original = Zone(id: UUID(), name: "Home", latitude: 35.0, longitude: 139.0, radiusMeters: 200)
        try controller.syncAll(zones: [original])
        let resized = Zone(id: original.id, name: original.name, latitude: 35.0, longitude: 139.0, radiusMeters: 500)
        try controller.syncAll(zones: [resized])
        let radius = (monitor.monitoredRegions.first as? CLCircularRegion)?.radius
        XCTAssertEqual(radius, 500)
    }

    func test_syncAll_does_not_restart_an_unchanged_region() throws {
        let zone = Zone(id: UUID(), name: "Home", latitude: 35.0, longitude: 139.0, radiusMeters: 200)
        try controller.syncAll(zones: [zone])
        let initialRegion = monitor.monitoredRegions.first
        try controller.syncAll(zones: [zone])
        let afterRegion = monitor.monitoredRegions.first
        XCTAssertTrue(initialRegion === afterRegion,
            "unchanged regions should be left in place — no stop+start churn")
    }

    func test_syncAll_throws_tooManyZones_above_the_iOS_limit() throws {
        let many = (0..<21).map { i in
            Zone(name: "z\(i)", latitude: Double(i), longitude: Double(i))
        }
        do {
            try controller.syncAll(zones: many)
            XCTFail("expected tooManyZones to throw")
        } catch GeofenceController.SyncError.tooManyZones(let supplied, let limit) {
            XCTAssertEqual(supplied, 21)
            XCTAssertEqual(limit, 20)
        }
    }

    func test_syncAll_at_the_limit_succeeds() throws {
        let exactly = (0..<20).map { i in
            Zone(name: "z\(i)", latitude: Double(i), longitude: Double(i))
        }
        try controller.syncAll(zones: exactly)
        XCTAssertEqual(monitor.monitoredRegions.count, 20)
    }

    func test_syncAll_throws_when_monitoring_is_unavailable() {
        let c = GeofenceController(
            monitor: monitor, stateStore: stateStore,
            isMonitoringAvailable: { false }
        )
        do {
            try c.syncAll(zones: [Zone(name: "Home", latitude: 0, longitude: 0)])
            XCTFail("expected monitoringUnavailable")
        } catch GeofenceController.SyncError.monitoringUnavailable {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_syncAll_throws_authorizationInsufficient_when_status_is_denied() {
        monitor.authorizationStatus = .denied
        do {
            try controller.syncAll(zones: [Zone(name: "Home", latitude: 0, longitude: 0)])
            XCTFail("expected authorizationInsufficient")
        } catch GeofenceController.SyncError.authorizationInsufficient(let status) {
            XCTAssertEqual(status, .denied)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_syncAll_proceeds_with_whenInUse_authorization() throws {
        // .authorizedWhenInUse is acceptable — the controller logs a notice but still
        // registers regions. Background ENTER/EXIT may be unreliable; that's a UX warning,
        // not a hard refusal.
        monitor.authorizationStatus = .authorizedWhenInUse
        try controller.syncAll(zones: [Zone(name: "Home", latitude: 0, longitude: 0)])
        XCTAssertEqual(monitor.monitoredRegions.count, 1)
    }

    func test_syncAll_forgets_state_for_a_zone_that_is_dropped_while_inside_it() throws {
        let inside = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        try controller.syncAll(zones: [inside])
        controller._testDetermineState(.inside, for: inside.region)
        XCTAssertEqual(stateStore.activeZoneIds, [inside.id])

        // Drop the zone — the controller must clear its active-zone marker so the next
        // foreground check doesn't keep firing for a deleted zone.
        try controller.syncAll(zones: [])
        XCTAssertTrue(stateStore.activeZoneIds.isEmpty)
    }

    // MARK: Delegate callbacks

    func test_didEnterRegion_marks_zone_active() {
        let zone = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        controller._testEnter(region: zone.region)
        XCTAssertEqual(stateStore.activeZoneIds, [zone.id])
    }

    func test_didExitRegion_clears_zone_active() {
        let zone = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        controller._testEnter(region: zone.region)
        controller._testExit(region: zone.region)
        XCTAssertTrue(stateStore.activeZoneIds.isEmpty)
    }

    func test_didDetermineState_inside_marks_zone_active_at_start() {
        // CoreLocation calls didDetermineState right after startMonitoring to tell the app
        // whether the user is already inside the region. SPEC.md §G's "modify only inside
        // zones" promise depends on this: a user who installs the app while at home should
        // immediately have Home marked active without stepping outside first.
        let zone = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        controller._testDetermineState(.inside, for: zone.region)
        XCTAssertEqual(stateStore.activeZoneIds, [zone.id])
    }

    func test_didDetermineState_outside_clears_zone() {
        let zone = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        controller._testEnter(region: zone.region) // pretend it was active
        controller._testDetermineState(.outside, for: zone.region)
        XCTAssertTrue(stateStore.activeZoneIds.isEmpty)
    }

    func test_delegate_ignores_regions_whose_identifier_is_not_a_uuid() {
        let bogus = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            radius: 100,
            identifier: "not-a-uuid"
        )
        controller._testEnter(region: bogus)
        XCTAssertTrue(stateStore.activeZoneIds.isEmpty,
            "non-UUID identifiers (e.g. left over from a different app version) must be ignored")
    }

    // MARK: stopAll / requestAuthorization

    func test_stopAll_stops_every_region_and_clears_active_zones() throws {
        let a = Zone(name: "Home", latitude: 35.0, longitude: 139.0)
        let b = Zone(name: "Office", latitude: 35.1, longitude: 139.1)
        try controller.syncAll(zones: [a, b])
        controller._testEnter(region: a.region)

        controller.stopAll()
        XCTAssertTrue(monitor.monitoredRegions.isEmpty)
        XCTAssertTrue(stateStore.activeZoneIds.isEmpty)
    }

    func test_requestAuthorization_calls_through_to_the_monitor() {
        XCTAssertEqual(monitor.requestAlwaysCount, 0)
        controller.requestAuthorization()
        XCTAssertEqual(monitor.requestAlwaysCount, 1)
    }
}
