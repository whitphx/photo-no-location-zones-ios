import CoreLocation
import Foundation
import os.log

/// Tiny abstraction over `CLLocationManager` that `GeofenceController` writes to. Production
/// uses `CLLocationManager`; tests inject a stand-in so they don't have to coordinate the
/// actual CoreLocation runtime (region delegate callbacks come on a CL-internal queue, which
/// is awkward to drive from XCTest).
nonisolated protocol LocationMonitor: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var monitoredRegions: Set<CLRegion> { get }
    var authorizationStatus: CLAuthorizationStatus { get }

    func startMonitoring(for region: CLRegion)
    func stopMonitoring(for region: CLRegion)
    func requestAlwaysAuthorization()
}

nonisolated extension CLLocationManager: LocationMonitor {}

/// Manages CoreLocation region monitoring for the user's `Zone`s. Mirrors the Android
/// `GeofenceController` — same name, same role: the single point of contact between the app
/// and the OS's geofencing primitive, and the only place that translates region transitions
/// into writes on `ZoneStateStore`.
///
/// SPEC.md §H.3: iOS allows up to 20 active `CLCircularRegion`s per app. The zone editor
/// enforces this at the UI layer; this controller refuses to start monitoring once that
/// limit is hit and surfaces an error so the UI can tell the user.
///
/// SPEC.md §H.2 catch-up-on-open: ENTER fires while the app is in background; the
/// `ZoneStateStore` write the controller performs is the durable signal that the next
/// foreground / Background App Refresh tick reads. The controller does **not** start a
/// foreground service or a long-running task — iOS doesn't have an equivalent to Android's
/// `PhotoMonitorService`, and trying to fake one with location-update tricks will get the
/// app rejected. The actual photo-library catch-up happens elsewhere (`PhotoCatchupTask`,
/// phase 2.x) on app foreground.
nonisolated final class GeofenceController: NSObject {

    enum SyncError: Error {
        /// Returned by `syncAll` when the supplied set exceeds iOS's 20-region per-app
        /// limit. SPEC.md §H.3: the editor must enforce this; the throw is defence in depth.
        case tooManyZones(supplied: Int, limit: Int)
        /// Authorization isn't `.authorizedAlways` — region monitoring won't fire while the
        /// app is suspended without it. Caller should escort the user through the Settings
        /// flow before retrying.
        case authorizationInsufficient(CLAuthorizationStatus)
        /// Region monitoring isn't available on this device (private VPN profile, simulator
        /// without Settings → Privacy → Location Services on, etc.).
        case monitoringUnavailable
    }

    static let regionLimit = 20

    private let monitor: LocationMonitor
    private let stateStore: ZoneStateStore
    private let isMonitoringAvailable: () -> Bool
    private let log = Logger(subsystem: "io.github.whitphx.nolocationzones", category: "GeofenceController")

    init(
        monitor: LocationMonitor = CLLocationManager(),
        stateStore: ZoneStateStore,
        isMonitoringAvailable: @escaping () -> Bool = {
            CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        }
    ) {
        self.monitor = monitor
        self.stateStore = stateStore
        self.isMonitoringAvailable = isMonitoringAvailable
        super.init()
        monitor.delegate = self
    }

    /// Currently registered region identifiers (= zone UUID strings). Reading this from a
    /// freshly initialised controller surfaces whatever the OS persisted across launches.
    var monitoredRegionIds: Set<String> {
        Set(monitor.monitoredRegions.map(\.identifier))
    }

    /// Make the OS's monitoring set match exactly the supplied zones. Stops any region whose
    /// identifier is no longer in the input, starts any new region, and updates radii / centres
    /// on regions that changed (CoreLocation has no in-place mutate; the implementation stops
    /// then restarts the region).
    ///
    /// Throws `tooManyZones` if `zones.count > 20`. The editor should enforce this beforehand;
    /// this throw is a guardrail that prevents the silent CoreLocation-side truncation that
    /// would otherwise leave the user with the wrong subset of zones armed.
    func syncAll(zones: [Zone]) throws {
        if zones.count > Self.regionLimit {
            throw SyncError.tooManyZones(supplied: zones.count, limit: Self.regionLimit)
        }
        guard isMonitoringAvailable() else {
            throw SyncError.monitoringUnavailable
        }
        let status = monitor.authorizationStatus
        if status != .authorizedAlways {
            // Allow .authorizedWhenInUse to proceed — region monitoring works while the app
            // is in foreground/background; only "always" guarantees background wakeups. The
            // UI surfaces this as a warning ("zones won't trigger when the app is closed
            // unless you grant Always") rather than a hard error.
            if status != .authorizedWhenInUse {
                throw SyncError.authorizationInsufficient(status)
            }
            log.notice("Authorization is .authorizedWhenInUse; background ENTER/EXIT may not fire reliably until user grants Always")
        }

        let desired = Dictionary(uniqueKeysWithValues: zones.map { ($0.id.uuidString, $0) })
        let existing = monitor.monitoredRegions

        // Stop regions that are no longer wanted, plus those whose center/radius changed.
        var stopped = 0
        for region in existing {
            guard let circular = region as? CLCircularRegion else {
                monitor.stopMonitoring(for: region)
                stopped += 1
                continue
            }
            if let zone = desired[circular.identifier],
               circular.center.latitude == zone.latitude,
               circular.center.longitude == zone.longitude,
               circular.radius == zone.radiusMeters {
                continue
            }
            monitor.stopMonitoring(for: circular)
            stopped += 1
            // Drop a stale "I'm inside this zone" marker so the next ENTER (which CoreLocation
            // re-fires on startMonitoring if the user is inside the new region) is the source
            // of truth. Without this, deleting a zone while inside it would leave a phantom
            // active-zone-id behind.
            if let id = UUID(uuidString: circular.identifier) {
                stateStore.forget([id])
            }
        }

        // Start any region not already monitored (or restarted after a stop above).
        var started = 0
        let alreadyMonitoredIds = Set(monitor.monitoredRegions.map(\.identifier))
        for zone in zones where !alreadyMonitoredIds.contains(zone.id.uuidString) {
            let region = zone.region
            // ENTER fires on transition; the user being inside at start of monitoring also
            // counts via `didDetermineState`. EXIT fires on the transition out.
            region.notifyOnEntry = true
            region.notifyOnExit = true
            monitor.startMonitoring(for: region)
            started += 1
        }

        log.info("syncAll: started=\(started, privacy: .public) stopped=\(stopped, privacy: .public) total=\(zones.count, privacy: .public)")
    }

    /// Stop monitoring everything. Used on a sign-out / "reset" flow; not part of the normal
    /// detection path.
    func stopAll() {
        for region in monitor.monitoredRegions {
            monitor.stopMonitoring(for: region)
        }
        stateStore.clearActiveZones()
    }

    /// Request `Always` authorization. The first call after a fresh install surfaces the
    /// system's two-step prompt (When-In-Use first, then a separate Always upgrade). The UI
    /// is responsible for the explanatory copy; this method just makes the request.
    func requestAuthorization() {
        monitor.requestAlwaysAuthorization()
    }
}

nonisolated extension GeofenceController: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier) else { return }
        log.info("ENTER \(region.identifier, privacy: .public)")
        stateStore.markEntered([id])
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier) else { return }
        log.info("EXIT \(region.identifier, privacy: .public)")
        stateStore.markExited([id])
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        log.warning("monitoringDidFailFor \(region?.identifier ?? "<nil>", privacy: .public): \(String(describing: error), privacy: .public)")
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        // CoreLocation calls this after `startMonitoring` to tell us whether the user is
        // already inside the region at start time. We mirror it into `ZoneStateStore` so a
        // user who installs the app *while* at home immediately gets the active-zone status,
        // without having to step outside and back inside.
        guard let id = UUID(uuidString: region.identifier) else { return }
        switch state {
        case .inside: stateStore.markEntered([id])
        case .outside: stateStore.markExited([id])
        case .unknown: break
        @unknown default: break
        }
    }

    /// Internal entry points for tests that don't have a real `CLLocationManager` to hand.
    /// Each forwards to the corresponding `CLLocationManagerDelegate` method, threading a
    /// throwaway `CLLocationManager` instance through (the manager argument is unused on
    /// our side — we read region state, not the manager).
    func _testEnter(region: CLRegion) {
        locationManager(CLLocationManager(), didEnterRegion: region)
    }
    func _testExit(region: CLRegion) {
        locationManager(CLLocationManager(), didExitRegion: region)
    }
    func _testDetermineState(_ state: CLRegionState, for region: CLRegion) {
        locationManager(CLLocationManager(), didDetermineState: state, for: region)
    }
}
