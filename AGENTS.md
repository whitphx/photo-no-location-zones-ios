# AGENTS.md

iOS implementation of *photo-no-location-zones*. Read [SPEC.md](./SPEC.md) before changing anything in the photo or location pipelines — it is the canonical privacy contract.

## Build, test

```sh
xcodebuild -scheme PhotoNoLocationZones -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme PhotoNoLocationZones -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Open `PhotoNoLocationZones.xcodeproj` in Xcode for SwiftUI previews and faster iteration.

## Privacy contract

[`SPEC.md`](./SPEC.md), pinned to [`spec-v1.0.0`](https://github.com/whitphx/photo-no-location-zones/tree/spec-v1.0.0) of the upstream. **Any change to which EXIF tags are cleared, which MP4 atoms are rewritten, the ISO 6709 parser, or the detection trigger model must be a SPEC.md PR upstream first** ([whitphx/photo-no-location-zones](https://github.com/whitphx/photo-no-location-zones)), then bumped here, then code.

The Android reference implementation is the source-of-truth for "what does this spec test name actually assert." When porting tests, mirror the JUnit display names listed in SPEC.md's "Test references" table verbatim into XCTest method names — `grep` for a test name should hit the spec row + the Android test + the iOS test in one shot.

## Architecture invariants (iOS-specific)

These are SPEC.md §H.2–H.4 made concrete in code:

### Detection is catch-up-on-open

- `CLLocationManager` region monitoring fires on geofence ENTER. The handler records "needs catchup since `<lastSeenAssetLocalIdentifier>`" durably (e.g. `UserDefaults` or a small SQLite store).
- On the next foreground launch *or* a Background App Refresh tick, the app queries `PHFetchResult<PHAsset>` for assets created since the cursor and queues anything that satisfies the criteria.
- A `PHPhotoLibraryChangeObserver` is registered while the app is in foreground to catch real-time additions during the same session.

There is **no** equivalent of Android's foreground service that watches the photo library while in background. Don't try to fake one with location-update tricks; the App Store will reject it and the privacy story breaks.

### Modification through PhotoKit, never direct file I/O

- All writes go through `PHPhotoLibrary.shared().performChanges` with `PHContentEditingInput` → `PHContentEditingOutput`. The system shows its own consent surface; declining means nothing is touched.
- The MP4 atom walker, ISO 6709 parser, and EXIF tag list are direct ports from the Android reference. Algorithmic identity is the contract — pixel-level / byte-level behavior must be the same on both platforms.

### Region-monitoring limit

iOS allows 20 active `CLCircularRegion`s per app. The zone editor must enforce this limit (vs Android's 100). For users with more than 20 zones, either reject creation past 20 or implement a "rotating window" strategy that registers the nearest 20 to the user's current coarse location — the latter is a follow-up, not v1.

## Conventions

- **No SwiftPM workspace yet.** Single Xcode app target + a Unit Testing Bundle target. Add SwiftPM only when an external dep makes sense.
- **MapLibre Native iOS** is the planned map layer (mirrors the Android choice; same OpenFreeMap tile source). Not wired up in v1; placeholder map view is acceptable until phase 2.
- **Photon** (https://photon.komoot.io) is the planned geocoder for place search — keyless, OSM-backed. Mirrors the Android choice.
