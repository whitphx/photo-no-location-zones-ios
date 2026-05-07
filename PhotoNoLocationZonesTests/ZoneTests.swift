import XCTest
import CoreLocation
@testable import PhotoNoLocationZones

final class ZoneTests: XCTestCase {

    func test_region_uses_zone_id_as_identifier() {
        let id = UUID()
        let zone = Zone(id: id, name: "Home", latitude: 35.6895, longitude: 139.6917, radiusMeters: 200)
        let region = zone.region
        XCTAssertEqual(region.identifier, id.uuidString)
        XCTAssertEqual(region.center.latitude, 35.6895, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, 139.6917, accuracy: 1e-9)
        XCTAssertEqual(region.radius, 200, accuracy: 1e-9)
    }

    func test_codable_round_trip() throws {
        let original = Zone(name: "Office", latitude: 1.0, longitude: 2.0, radiusMeters: 500)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Zone.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_default_radius_is_used_when_unspecified() {
        let zone = Zone(name: "Home", latitude: 0, longitude: 0)
        XCTAssertEqual(zone.radiusMeters, Zone.defaultRadiusMeters)
    }

    func test_radius_constants_are_in_canonical_order() {
        XCTAssertLessThan(Zone.minRadiusMeters, Zone.defaultRadiusMeters)
        XCTAssertLessThan(Zone.defaultRadiusMeters, Zone.maxRadiusMeters)
    }
}
