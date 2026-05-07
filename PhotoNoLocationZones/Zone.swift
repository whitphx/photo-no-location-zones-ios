import CoreLocation
import Foundation

/// A user-defined "no-location zone": a circular region within which captured photos and
/// videos are queued for a strip review. Mirrors the Android `Zone` domain type.
///
/// The struct is Codable so it round-trips through JSON without ceremony — phase 2.x will
/// move persistence to SwiftData when a query layer pays its weight; for now the small
/// number of zones (≤ 20 on iOS per CoreLocation's `CLCircularRegion` limit, see SPEC.md
/// §H.3) lives happily as a JSON array.
///
/// `nonisolated` is explicit because the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// otherwise infers MainActor isolation, which makes the synthesized Codable / Equatable
/// conformances unusable from non-MainActor test contexts (runtime SIGABRT on
/// `JSONEncoder.encode`). `Zone` is a value type with no shared mutable state — nonisolated
/// is the correct choice on the merits.
nonisolated struct Zone: Codable, Identifiable, Equatable, Hashable, Sendable {

    /// Stable across launches; used as the `CLCircularRegion.identifier` so the geofence
    /// callback can map back to a `Zone` row without a separate lookup.
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double

    static let minRadiusMeters: Double = 100
    static let maxRadiusMeters: Double = 5000
    static let defaultRadiusMeters: Double = 200

    init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = Zone.defaultRadiusMeters
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }

    /// `CLCircularRegion` derived from this zone, identifier-stable across launches.
    /// SPEC.md §H.3: iOS allows 20 active regions per app — the zone editor enforces this
    /// limit at the UI layer, not here.
    var region: CLCircularRegion {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLCircularRegion(center: center, radius: radiusMeters, identifier: id.uuidString)
    }
}
