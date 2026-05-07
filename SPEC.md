# Photo No-Location Zones — Privacy Contract

```
Spec-Version: 1.0.0
Status:       Stable
Implementations:
  - Android (this repo)         conforms to: 1.0.0
  - iOS    (separate repo, TBD) conforms to: —
```

This document is the canonical privacy contract for *Photo No-Location Zones* across every platform implementation. It defines **what the app must do**, **what it must not do**, and **what it is allowed to do differently per platform**. Platform implementations (Android, iOS, etc.) are independent codebases; this spec is what keeps them honest.

The single rule: changes to privacy-correctness behavior start as a PR against this document. Implementation PRs follow.

---

## A. Privacy posture (the "why")

The app strips GPS metadata from photos and videos that were captured inside user-defined "no-location zones" while preserving location data on media taken anywhere else. Two non-negotiable invariants make this safe to ship:

1. **Detection automatic, modification user-gated.** The OS's geofence and media-observation primitives are used to *detect* and *queue* candidate items. Bytes on disk are never modified without an explicit per-batch system consent dialog showing the user every file about to change.
2. **No silent rewrites, ever.** No code path in any implementation may modify a media file without first obtaining write permission for that specific file via the platform's per-batch consent mechanism (`MediaStore.createWriteRequest` on Android, `PHContentEditingInput`/`Output` on iOS).

A user reading the app's behavior should be able to say: "the only way bytes change is when I tap a button and confirm a system dialog." This is a contract, not an aspiration.

---

## B. EXIF location tags (cleared)

These are stripped on every successful "Strip GPS" of a JPEG / HEIF / HEIC photo. The list is canonical: an implementation that fails to clear any of these is non-conformant.

| Tag | EXIF ID (hex) | IFD | Why |
|---|---|---|---|
| GPSVersionID         | 0x0000 | GPS | Identifies the GPS-IFD as present. |
| GPSLatitudeRef       | 0x0001 | GPS | N/S marker for latitude. |
| GPSLatitude          | 0x0002 | GPS | Coordinate. |
| GPSLongitudeRef      | 0x0003 | GPS | E/W marker for longitude. |
| GPSLongitude         | 0x0004 | GPS | Coordinate. |
| GPSAltitudeRef       | 0x0005 | GPS | Above/below sea-level marker. |
| GPSAltitude          | 0x0006 | GPS | Altitude reading. |
| GPSTimeStamp         | 0x0007 | GPS | UTC time of fix (precise to the second). |
| GPSSatellites        | 0x0008 | GPS | Satellite IDs at fix. |
| GPSStatus            | 0x0009 | GPS | Receiver status. |
| GPSMeasureMode       | 0x000A | GPS | 2D / 3D fix marker. |
| GPSDOP               | 0x000B | GPS | Dilution-of-precision. |
| GPSSpeedRef          | 0x000C | GPS | Speed unit. |
| GPSSpeed             | 0x000D | GPS | Speed reading. |
| GPSTrackRef          | 0x000E | GPS | Track direction reference. |
| GPSTrack             | 0x000F | GPS | Track direction. |
| GPSImgDirectionRef   | 0x0010 | GPS | Image-direction reference. |
| GPSImgDirection      | 0x0011 | GPS | Direction the camera was pointing. |
| GPSMapDatum          | 0x0012 | GPS | Geodetic datum. |
| GPSDestLatitudeRef   | 0x0013 | GPS | Destination-coordinate marker. |
| GPSDestLatitude      | 0x0014 | GPS | Destination coordinate. |
| GPSDestLongitudeRef  | 0x0015 | GPS | Destination-coordinate marker. |
| GPSDestLongitude     | 0x0016 | GPS | Destination coordinate. |
| GPSDestBearingRef    | 0x0017 | GPS | Bearing reference. |
| GPSDestBearing       | 0x0018 | GPS | Bearing to destination. |
| GPSDestDistanceRef   | 0x0019 | GPS | Distance unit. |
| GPSDestDistance      | 0x001A | GPS | Distance to destination. |
| GPSProcessingMethod  | 0x001B | GPS | Geolocation method (GPS / Wi-Fi / cell). |
| GPSAreaInformation   | 0x001C | GPS | Free-text area name (sometimes a place label). |
| GPSDateStamp         | 0x001D | GPS | UTC date of fix. |
| GPSDifferential      | 0x001E | GPS | Differential correction marker. |
| GPSHPositioningError | 0x001F | GPS | Horizontal positioning error. |
| MakerNote            | 0x927C | EXIF | **Critical.** Vendor-defined binary that frequently embeds a *duplicate* of the GPS coordinates in proprietary format, plus Wi-Fi SSID, Apple `AssetIdentifier`, scene/face recognition data, etc. Clearing the GPS-IFD without clearing `MakerNote` will still resolve to the user's address in some forensic tools. |

Verification: every successful strip re-reads the file and warns to the platform log if any of the above survived (`adb logcat -s ExifGpsStripper` on Android). A surviving tag is a defect, not a "documented gap."

---

## C. EXIF identity tags

Cleared in addition to **B** because they tie photos to a specific person or device. The list is short on purpose — these are the identifiers the platform's standard library exposes for clearing.

| Tag | EXIF ID (hex) | Status | Why |
|---|---|---|---|
| Artist            | 0x013B | Cleared | Photographer's name; some camera apps and editors fill it. |
| CameraOwnerName   | 0xA430 | Cleared | Same purpose, EXIF-IFD location. |
| BodySerialNumber  | 0xA431 | Cleared | Unique to a physical camera; ties multiple photos to one device. |
| LensSerialNumber  | 0xA435 | Cleared | Unique to a physical lens. |
| UserComment       | 0x9286 | Cleared | Free-form text; occasionally contains location names. |
| ImageDescription  | 0x010E | Cleared | Free-form text in IFD0; same risk as UserComment. |
| XPTitle           | 0x9C9B | **Gap**    | Windows-Explorer "Tags" UI writes here. AndroidX `ExifInterface` doesn't expose `setAttribute` constants for the `XP*` family, so we cannot clear them through that library. Low practical risk on mobile. |
| XPComment         | 0x9C9C | **Gap**    | Same as XPTitle. |
| XPAuthor          | 0x9C9D | **Gap**    | Same as XPTitle. |
| XPKeywords        | 0x9C9E | **Gap**    | Same as XPTitle. |
| XPSubject         | 0x9C9F | **Gap**    | Same as XPTitle. |

iOS implementations have no equivalent library limitation here — they can clear the `XP*` family if `CGImageDestination` exposes the keys. If they do, they must update this row to "Cleared" and bump the spec.

---

## D. Container atoms (MP4 / MOV / 3GPP)

For video files, GPS metadata lives inside ISO BMFF "boxes" (atoms). Implementations re-tag these atoms in place rather than deleting them — see **F**.

| Path | Type code (hex) | Status | Why |
|---|---|---|---|
| `moov/udta/©xyz` | 0xA978797A | Cleared | QuickTime ISO 6709 location string. Stock Android camera apps and many third-party recorders use this path. |
| `moov/udta/loci` | 0x6C6F6369 | Cleared | 3GPP location info. Older Android cameras still emit this. |
| `moov/meta/keys` + `moov/meta/ilst/<n>` referencing `com.apple.quicktime.location.ISO6709` | — | **Gap** | iPhone-recorded `.mov` uses an Apple keys-table indirection. Decoding requires walking the keys table and matching by name. Not yet implemented in any platform. |
| Embedded MP4 inside Motion Photo / Live Photo (Samsung `MotionPhoto`, Google "Top Shot", Apple Live Photo) | — | **Gap** | The still's EXIF is rewritten; the embedded video's atoms are left intact. The atom logic is known; the container-aware byte-range path that hands the embedded MP4 to the same walker is not yet wired up. |

Verification: like **B**, every successful strip re-walks the file post-write and warns if a recognized GPS atom type survived.

---

## E. ISO 6709 parser rules

Parser semantics for the `©xyz` payload (used for both reading the location for "Show location" and for sanity-checking after a strip).

1. **Try prefixed first.** QuickTime convention is `[u16 textLen][u16 language][UTF-8 text]`. Skip 4 bytes, parse the next `textLen` bytes as the ISO 6709 string.
2. **Fall back to whole payload.** Some non-conformant writers omit the prefix. If the prefixed parse returns null, re-run the regex against the entire payload from offset 0.
3. **Range-validate.** A signed-decimal regex finds the first two consecutive signed numbers; both must satisfy `lat ∈ [-90, 90]` and `lon ∈ [-180, 180]`. Out-of-range pairs are rejected (returning null), which is what makes step 2's fallback safe — a partial parse that ate a leading sign always lands outside the valid range.
4. **Strip altitude / CRS suffixes.** Only the first two numbers are read; trailing `±AAA.AAA/` segments are ignored.

---

## F. In-place rewrite invariants

These rules apply to **D** (videos). Photos go through library-mediated EXIF write, which the library guarantees doesn't touch unrelated bytes.

1. **Re-tag, don't delete.** Replace the 4-byte type field with `'free'` (a valid ISO BMFF "ignore me" box). Do not change the box's size, do not move it, do not reflow the parent. This preserves every other atom's offset and means the file's `mdat` chunk offsets in `stco`/`co64` stay correct without recomputation.
2. **Byte-aligned write.** Use platform random-access I/O (`android.system.Os.lseek` + `Os.write` on Android; `FileHandle` / `Data.write(to:)` on iOS) — not a re-mux library that might reflow.
3. **Post-strip verification.** Re-walk `moov/udta` after writing; warn (don't fail) if any recognized location atom type survived. The user is already past the consent step at this point; the warning surfaces a coverage gap to investigators rather than blocking the user.
4. **Notify the platform media store.** After a successful strip, call the platform's "this file changed" API (`ContentResolver.notifyChange` on Android; trigger PhotoKit cache invalidation on iOS) so gallery apps caching `LATITUDE`/`LONGITUDE` columns flush.

---

## G. UX & flow invariants

The user-visible promises both platforms keep, regardless of how they implement detection.

1. **Geofence-triggered detection.** Detection is gated by the OS's native geofencing primitives — not periodic polling, not always-on monitoring outside zones. While the user is outside every zone, the app is idle and battery drain is at baseline.
2. **Per-batch system consent for writes.** Every "Strip GPS" action — single-photo, multi-select, or notification action — surfaces the platform's standard "Allow this app to modify these files?" dialog *before* any byte is written. The dialog enumerates the affected files. Declining means nothing is touched.
3. **Zone-bounded detection.** Photos and videos taken outside every defined zone are not queued. The user controls what gets considered.
4. **Per-item review.** Every queued item is shown to the user before stripping; the user can preview, see the photo's GPS location on a map, and skip or strip individually.
5. **Reversible queue, irreversible writes.** Skipping does not modify the file. Stripping is deliberately one-way (the app does not retain the original GPS for "undo"); this is part of the privacy story — we don't want a "forget to clean up" path that re-leaks coordinates.

---

## H. Platform deviations (intentional)

Each platform is allowed to differ on **how detection is triggered** as long as **A**, **B**, **C**, **D**, **E**, **F**, **G** all hold. The deviations below are *contracts*, not bugs: a platform that "fixes" them by working around the OS limit is suspicious.

### H.1 — Android: continuous in-zone monitoring

While the user is inside any zone:
- A foreground service (`PhotoMonitorService`, type `location`) is running.
- The service holds a `ContentObserver` on `MediaStore.Images` and `MediaStore.Video`.
- New media that satisfies the queue criteria is detected within ~400 ms of MediaStore indexing it.

This is what Android's foreground-service-from-geofence-broadcast exemption permits, and the user gets an ongoing notification while it's active.

### H.2 — iOS: catchup-on-open monitoring

iOS does not grant arbitrary apps continuous photo-library observation in the background. The intentional design is:
- Geofence ENTER fires (`CLLocationManager` region monitoring).
- The app records "needs catchup since `<lastSeen>`" durably.
- On the next foreground launch *or* a Background App Refresh tick, the app queries `PHPhotoLibrary` for assets created since the cursor and queues anything that satisfies the criteria.
- A `PHPhotoLibraryChangeObserver` is active *while in foreground* to catch real-time additions during the same session.

User-visible consequence: photos taken inside a zone may be queued **on the next time the user opens the app** rather than immediately. This is documented in the iOS app's first-run UX so users who tap "Strip GPS" later don't think detection is broken.

The privacy invariants don't change: when detection eventually runs, it still goes through B–G unchanged.

### H.3 — Geofence registration limits

| Platform | Per-app limit | Source |
|---|---|---|
| Android | 100 active geofences | Play Services geofencing API |
| iOS | 20 active regions | `CLLocationManager` |

Implementations show this limit in the zone-editor UI when the user approaches it. iOS implementations may need a "rotation" strategy if the user defines many zones (tracking the user's location coarsely and registering the nearest 20).

### H.4 — System write-consent surface

| Platform | API | UX |
|---|---|---|
| Android | `MediaStore.createWriteRequest(uris)` | One system dialog listing every URI per batch. Granted bytes are writable for that session only. |
| iOS | `PHPhotoLibrary.shared().performChanges` with `PHContentEditingInput` / `PHContentEditingOutput` | Per-asset save through the photo library. iOS may show a single confirmation per session rather than per asset. |

Both surfaces satisfy **A.2** ("explicit per-batch system consent"). The iOS one is slightly looser because the OS doesn't itemize files in the dialog; the app's own per-photo review screen (G.4) is where the per-item visibility happens.

---

## I. Versioning & change process

```
Spec-Version: <major>.<minor>.<patch>
```

- **Major** bump (e.g. 1.x → 2.0): a new tag is added to **B**/**C** as `Cleared`, a tag changes from `Gap` to `Cleared`, an atom path is added to **D**, **F** changes (e.g. switch from re-tag to delete), or **A** is loosened. Every implementation must re-conform within an agreed window.
- **Minor** bump: a new gap is documented (status `Gap`), a platform deviation is added to **H**, a new test reference is added. No implementation is forced to change behavior.
- **Patch** bump: typo, prose clarification, no semantic change.

A SPEC.md PR must update the changelog below. CI in this repo enforces "version line bumped" + "changelog entry added" on any SPEC.md edit.

Each implementation declares its conformance in its own README:

> **Privacy contract:** [SPEC.md@1.0.0](https://github.com/whitphx/photo-no-location-zones/blob/v1.0.0-spec/SPEC.md)

iOS repos may consume SPEC.md as a Git submodule pinned to the conforming SHA, or as a copied snapshot with the version recorded — implementer's choice.

### Changelog

- **1.0.0** — Initial spec. Captures the Android implementation as of commit `2ca6a4c` (post-review-findings).

---

## Test references (Android, this repo)

Spec rows in **D**/**E** are pinned by JVM unit tests. Renaming a test method without updating the row breaks the link — a small CI guard (planned, see **I**) flags this on edit.

| Spec row | Test class | Method (JUnit display name) |
|---|---|---|
| **D**: `moov/udta/©xyz` and `loci` are located | `Mp4AtomsTest` | `findLocationAtomTypeOffsets locates xyz and loci nested under moov udta` |
| **D**: missing `moov/udta` returns empty | `Mp4AtomsTest` | `findLocationAtomTypeOffsets returns empty when moov udta absent` |
| **D**: nested walker reaches `udta` children | `Mp4AtomsTest` | `walk skips deeper into a nested udta with multiple children` |
| **F.1**: walker tolerates malformed sizes | `Mp4AtomsTest` | `malformed size below header length is rejected`, `size running past end aborts` |
| **F.1**: 64-bit extended size is decoded | `Mp4AtomsTest` | `extended 64-bit size is decoded` |
| **E.1**: prefixed payload parses | `Mp4GpsReaderTest` | `parses prefixed QuickTime payload` |
| **E.2**: raw-payload fallback succeeds | `Mp4GpsReaderTest` | `falls back to raw payload when prefix is absent` |
| **E.3**: out-of-range rejected | `Mp4GpsReaderTest` | `out-of-range pair is rejected`, `parseIso6709 enforces lat-lon ranges` |
| **E.3**: integer-only coords accepted | `Mp4GpsReaderTest` | `parseIso6709 accepts integer-only coordinates` |

EXIF tag rows in **B**/**C** are not pinned by JVM unit tests today — coverage relies on the post-strip verification re-read (`ExifGpsStripper.verifyClean`) flagging survivors at runtime. A future spec revision may add fixture-based tests; until then, treat the verifyClean log as the runtime contract.
