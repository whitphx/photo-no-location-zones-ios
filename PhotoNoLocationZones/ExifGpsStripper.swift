import Foundation
import ImageIO
import os.log
import UniformTypeIdentifiers

/// Strips the EXIF GPS-IFD from a JPEG / HEIF / HEIC photo.
///
/// SPEC.md §B is fully covered: the entire `kCGImagePropertyGPSDictionary` (all 32 GPS-IFD
/// fields ImageIO surfaces under that key) is removed by passing `kCFNull` at the top level
/// to `CGImageDestinationAddImageFromSource`. Pixel data is copied frame-by-frame from the
/// source — no re-encode.
///
/// ## iOS-specific gap (SPEC.md §C identity tags)
///
/// The Android implementation also clears `MakerNote`, `UserComment`, `CameraOwnerName`,
/// `BodySerialNumber`, `LensSerialNumber` (inside EXIF), and `Artist`, `ImageDescription`
/// (inside TIFF). On iOS, the public ImageIO API does not let us remove individual sub-
/// dictionary keys without re-encoding the image:
///
///  - `kCFNull` is honored only at the top level of `CGImageDestinationAddImageFromSource`'s
///    properties override; nested `kCFNull` is silently ignored.
///  - Passing a sub-dictionary as an override **merges** with the source's sub-dictionary
///    rather than replacing it, so omitted keys fall through unchanged.
///  - `CGImageDestinationCopyImageSource` + `kCGImageDestinationMetadata` operates on the
///    XMP metadata graph, which is a separate view from the IFD properties surfaced by
///    `CGImageSourceCopyPropertiesAtIndex`. Removing from XMP doesn't clear the IFD entries.
///
/// Real-world impact:
///
///  - **MakerNote** is the meaningful gap. *On Android-shot or DSLR-imported photos*, it
///    commonly embeds a **duplicate of the GPS coordinates** in proprietary format. So a
///    photo shot on an Android phone, transferred to an iPhone, and processed through this
///    app would still leak its capture address — material privacy hole. *On iPhone-native
///    stock-Camera photos*, Apple's MakerNote mostly carries an `AssetIdentifier` (Live
///    Photo grouping) — identity correlation, not direct location.
///  - The other identity tags are **typically empty** on iPhone-native stock-Camera output
///    but get populated by Lightroom imports, professional cameras, and some Android modes.
///
/// Follow-up work to close the gap is a JPEG APP1/IFD walker analogous to `Mp4Atoms` —
/// walk the JPEG marker stream, locate the EXIF APP1 segment, walk the IFD entries, and
/// zero specific tag IDs in place. Until that lands, this iOS-side coverage is "GPS only";
/// the gap is documented in SPEC.md §C wording (Android-side) and in this iOS repo's
/// AGENTS.md ("Privacy gaps specific to this iOS implementation").
enum ExifGpsStripper {

    enum Result {
        case noChange
        case stripped(locationFieldsCleared: Int)
        case failed(Error)
    }

    enum StripError: Error {
        case sourceUnreadable(URL)
        case unknownImageType(URL)
        case destinationFailed(URL)
        case finalizeFailed(URL)
        case noFrames(URL)
    }

    /// Read-only existence check. Returns true if the file's metadata still carries a
    /// `kCGImagePropertyGPSDictionary` entry.
    static func hasGpsTags(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return props[kCGImagePropertyGPSDictionary] != nil
    }

    static func strip(at url: URL) -> Result {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .failed(StripError.sourceUnreadable(url))
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return .failed(StripError.noFrames(url)) }

        guard let typeID = CGImageSourceGetType(source) else {
            return .failed(StripError.unknownImageType(url))
        }

        // Pre-flight: skip the re-write if no targeted tag is present in any frame.
        var locationCount = 0
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] ?? [:]
            if props[kCGImagePropertyGPSDictionary] != nil { locationCount += 1 }
        }
        if locationCount == 0 {
            return .noChange
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).strip-tmp")

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, typeID, count, nil) else {
            return .failed(StripError.destinationFailed(tempURL))
        }

        let stripOverrides: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: kCFNull as Any,
        ]
        for i in 0..<count {
            CGImageDestinationAddImageFromSource(destination, source, i, stripOverrides as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            return .failed(StripError.finalizeFailed(tempURL))
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return .failed(error)
        }

        log.info("Cleared GPS dictionary from \(locationCount)/\(count) frame(s) of \(url.lastPathComponent, privacy: .public)")

        verifyClean(at: url)
        return .stripped(locationFieldsCleared: locationCount)
    }

    /// Re-read after the strip and warn loudly if any GPS dict survived.
    private static func verifyClean(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            log.warning("Post-strip verification: could not re-read \(url.lastPathComponent, privacy: .public)")
            return
        }
        if props[kCGImagePropertyGPSDictionary] != nil {
            log.warning("Post-strip verification: GPS dictionary survived for \(url.lastPathComponent, privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "io.github.whitphx.nolocationzones", category: "ExifGpsStripper")
}
