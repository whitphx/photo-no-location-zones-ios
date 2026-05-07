# Photo No-Location Zones (iOS)

iOS implementation of the same privacy goal as the [Android app](https://github.com/whitphx/photo-no-location-zones): strip GPS metadata from photos and videos taken inside user-defined geographic zones, while preserving location data on media taken anywhere else.

**Privacy contract:** [SPEC.md](./SPEC.md), pinned to [`spec-v1.0.0`](https://github.com/whitphx/photo-no-location-zones/tree/spec-v1.0.0) of the upstream.

## What it does

You define circular "no-location zones" on your phone. The OS uses native region monitoring (`CLLocationManager`) to detect when you cross into one of those zones. Whenever the app comes to the foreground after a zone entry — or during a Background App Refresh tick — it queries `PHPhotoLibrary` for new photos and videos taken since it last looked, and queues each GPS-tagged item for review. While the app is in foreground, a `PHPhotoLibraryChangeObserver` catches additions in real time. Modification waits for you to authorize it; every batch of edits is gated by an explicit per-asset save through `PHContentEditingInput`/`Output`.

The stock Camera app still runs, which means computational-photography features and full-resolution video recording are preserved. The app does not capture media itself — it post-processes whatever the camera has already saved to the photo library.

## Platform-specific behavior

This implementation conforms to all sections of [SPEC.md](./SPEC.md) plus the iOS deviations in §H. The most user-visible deviation:

> **Detection on iOS is "catch-up-on-open" rather than continuous.** iOS does not grant arbitrary apps the equivalent of an always-running photo-library observer in the background; the OS won't reliably wake the app on new photo additions. Photos taken inside a zone may be queued the next time you open the app rather than immediately. See SPEC.md §H.2 for the rationale.

Region-monitoring limit: 20 active geofences on iOS (vs 100 on Android). The app surfaces this limit in the zone editor.

## Building

Prerequisites:
- Xcode 16+
- iOS 17.0+ device or simulator
- A free Apple Developer account (paid only needed for TestFlight / App Store)

```sh
xcodebuild -scheme PhotoNoLocationZones \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build

xcodebuild -scheme PhotoNoLocationZones \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

## License

[MIT](./LICENSE).
