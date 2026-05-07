import Foundation

/// Tiny key-value store protocol that `ZoneStateStore` writes to. `UserDefaults` is the
/// production implementation; tests inject an in-memory dict-backed store so they don't have
/// to coordinate suite names or clean up the shared `.standard` defaults.
nonisolated protocol KeyValueStore: AnyObject {
    func stringArray(forKey key: String) -> [String]?
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

nonisolated extension UserDefaults: KeyValueStore {
    func stringArray(forKey key: String) -> [String]? {
        return (self.array(forKey: key) as? [String])
    }
}

/// Tracks state that must survive process restarts:
///  - which zones the user is currently inside (set by geofence transitions)
///  - the highest `PHAsset.localIdentifier` we have already inspected
///
/// SPEC.md §H.2: detection on iOS is "catch-up-on-open" — geofence ENTER fires while the app
/// is in background, the app records "needs catchup since `<lastSeenAssetId>`" durably, and
/// the next foreground launch (or a Background App Refresh tick) reads that cursor and
/// queries `PHFetchResult<PHAsset>` for assets created since.
///
/// Marked `nonisolated` because the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// otherwise infers MainActor isolation, which is undesired for a service that geofence
/// callbacks (delivered on a background queue) and Background App Refresh tasks need to call.
nonisolated final class ZoneStateStore {

    private let store: KeyValueStore

    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store
    }

    // MARK: Active zones

    var activeZoneIds: Set<UUID> {
        guard let raw = store.stringArray(forKey: Keys.activeZoneIds) else { return [] }
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
        store.removeObject(forKey: Keys.activeZoneIds)
    }

    private func save(activeZoneIds: Set<UUID>) {
        let encoded = activeZoneIds.map(\.uuidString)
        store.set(encoded, forKey: Keys.activeZoneIds)
    }

    // MARK: PhotoKit cursor

    /// The last `PHAsset.localIdentifier` we have already inspected. The catchup task fetches
    /// assets created strictly after this point. `nil` means "no cursor yet — first run, or
    /// the user reset state."
    var lastSeenAssetId: String? {
        store.string(forKey: Keys.lastSeenAssetId)
    }

    func setLastSeenAssetId(_ id: String?) {
        if let id {
            store.set(id, forKey: Keys.lastSeenAssetId)
        } else {
            store.removeObject(forKey: Keys.lastSeenAssetId)
        }
    }

    private enum Keys {
        static let activeZoneIds = "zone_state.active_zone_ids"
        static let lastSeenAssetId = "zone_state.last_seen_asset_id"
    }
}
