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

## Privacy gaps specific to this iOS implementation

These are gaps **beyond** what SPEC.md already documents — they exist on iOS only because the public ImageIO API has no public-API path for selective IFD-tag clearing. Worth knowing before claiming "iOS conforms to SPEC.md §C."

### EXIF / TIFF identity tags are not cleared yet (iOS-only gap)

`ExifGpsStripper` clears **the entire `kCGImagePropertyGPSDictionary`** (SPEC.md §B — fully covered). It does **not** clear the SPEC.md §C identity tags: `MakerNote`, `UserComment`, `CameraOwnerName`, `BodySerialNumber`, `LensSerialNumber` (inside the EXIF IFD), and `Artist`, `ImageDescription` (inside the TIFF IFD).

**Why**: `CGImageDestinationAddImageFromSource`'s properties override merges with — does not replace — the source's sub-dictionaries. `kCFNull` inside a sub-dictionary is silently ignored. The `CGImageDestinationCopyImageSource` + `CGImageMetadata` route operates on the XMP graph, which is a separate view from the IFD properties. There's no public ImageIO path to remove a single IFD sub-dictionary key without re-encoding the image (lossy for JPEG).

**Impact**:
- `MakerNote` is the meaningful exposure. *On Android-shot or DSLR-imported photos* it commonly embeds a duplicate of the GPS coordinates in proprietary format — a photo taken on an Android phone, transferred to an iPhone, then processed through this app would still leak its capture address. *On iPhone-native stock-Camera photos* Apple's MakerNote mostly carries an `AssetIdentifier` (Live Photo grouping) — identity correlation, not direct location.
- The other identity tags are typically empty on iPhone-native stock-Camera output but get populated by Lightroom imports, professional cameras, and some Android modes.

**Follow-up to close the gap**: a JPEG APP1 / IFD walker analogous to `Mp4Atoms` — walk the JPEG marker stream, locate the EXIF APP1 segment (marker `FFE1`, payload starts with `Exif\0\0`), walk the IFD0 / EXIF-IFD entries, and zero specific tag IDs in place without re-encoding the image data. Same algorithmic shape as the MP4 atom rewriter; same byte-layout-preserving guarantee. When this lands, update `ExifGpsStripper` to call into it before the PhotoKit-mediated write, add tests for each §C tag, and bump SPEC.md to a minor version that records the iOS gap as closed.

Until then: SPEC.md §B is met; SPEC.md §C is partially met (Android: full; iOS: documented gap pending the APP1 walker).

## Conventions

- **No SwiftPM workspace yet.** Single Xcode app target + a Unit Testing Bundle target. Add SwiftPM only when an external dep makes sense.
- **MapLibre Native iOS** is the planned map layer (mirrors the Android choice; same OpenFreeMap tile source). Not wired up in v1; placeholder map view is acceptable until phase 2.
- **Photon** (https://photon.komoot.io) is the planned geocoder for place search — keyless, OSM-backed. Mirrors the Android choice.
