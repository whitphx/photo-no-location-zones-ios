import Foundation

/// Tracks state that must survive process restarts:
///  - which zones the user is currently inside (set by geofence transitions)
///  - the highest `PHAsset.localIdentifier` we have already inspected
///
/// SPEC.md §H.2: detection on iOS is "catch-up-on-open" — geofence ENTER fires while the app
/// is in background, the app records "needs catchup since `<lastSeenAssetId>`" durably, and the
/// next foreground launch (or a Background App Refresh tick) reads that cursor and queries
/// `PHFetchResult<PHAsset>` for assets created since.
///
/// UserDefaults-backed: the data is small (a `Set<UUID>` of zone IDs and one optional `String`
/// cursor), the access pattern is read-mostly, and the durability requirements match
/// UserDefaults exactly. SwiftData would be over-engineering at this scale.
@MainActor
final class ZoneStateStore {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Active zones

    var activeZoneIds: Set<UUID> {
        guard let raw = defaults.array(forKey: Keys.activeZoneIds) as? [String] else { return [] }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    var isAnyZoneActive: Bool { !activeZoneIds.isEmpty }

    func markEntered(_ ids: [UUID]) {
        let merged = activeZoneIds.union(ids)
        save(activeZoneIds: merged)
    }

    func markExited(_ ids: [UUID]) {
        let pruned = activeZoneIds.subtracting(ids)
        save(activeZoneIds: pruned)
    }

    /// Drop a zone's presence — used when a zone is deleted, so the queue's
    /// "isAnyZoneActive" gate doesn't keep firing for a zone that no longer exists.
    func forget(_ ids: [UUID]) { markExited(ids) }

    /// Clear every active zone ID. Doesn't touch the asset cursor — those are independent
    /// pieces of state with different lifecycles (the cursor must persist across "I'm now
    /// outside every zone" transitions so we don't refetch already-seen assets).
    func clearActiveZones() {
        defaults.removeObject(forKey: Keys.activeZoneIds)
    }

    private func save(activeZoneIds: Set<UUID>) {
        let encoded = activeZoneIds.map(\.uuidString)
        defaults.set(encoded, forKey: Keys.activeZoneIds)
    }

    // MARK: PhotoKit cursor

    /// The last `PHAsset.localIdentifier` we have already inspected. The catchup task fetches
    /// assets created strictly after this point. `nil` means "no cursor yet — first run, or the
    /// user reset state."
    var lastSeenAssetId: String? {
        defaults.string(forKey: Keys.lastSeenAssetId)
    }

    func setLastSeenAssetId(_ id: String?) {
        if let id {
            defaults.set(id, forKey: Keys.lastSeenAssetId)
        } else {
            defaults.removeObject(forKey: Keys.lastSeenAssetId)
        }
    }

    private enum Keys {
        static let activeZoneIds = "zone_state.active_zone_ids"
        static let lastSeenAssetId = "zone_state.last_seen_asset_id"
    }
}
