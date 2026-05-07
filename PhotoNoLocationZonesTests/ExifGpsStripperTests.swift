import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoNoLocationZones

/// Fixture-based pinning tests for `ExifGpsStripper`. SPEC.md §B coverage on the iOS side.
///
/// SPEC.md §C identity tags (MakerNote, BodySerialNumber, Artist, etc.) are an iOS-specific
/// gap today — see the doc comment on `ExifGpsStripper` and AGENTS.md for the rationale.
/// When the JPEG APP1/IFD walker lands, this file gains the corresponding tests.
final class ExifGpsStripperTests: XCTestCase {

    // MARK: - Round-trip helpers

    /// Build a 1x1 white JPEG at a temp URL, embedding the supplied EXIF / GPS / TIFF
    /// dictionaries verbatim into the image properties. Returns the URL.
    private func makeJpeg(
        gps: [CFString: Any]? = nil,
        exif: [CFString: Any]? = nil,
        tiff: [CFString: Any]? = nil
    ) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).jpg")

        let cs = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [255, 255, 255, 255]
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            XCTFail("Failed to construct test CGImage")
            throw NSError(domain: "TestSetup", code: 1)
        }

        var properties: [CFString: Any] = [:]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        if let tiff { properties[kCGImagePropertyTIFFDictionary] = tiff }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else {
            XCTFail("Failed to create CGImageDestination")
            throw NSError(domain: "TestSetup", code: 2)
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func gpsDictionary(at url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    // MARK: - Tests

    /// SPEC.md §B: stripping a JPEG that carries a GPS dictionary clears every GPS-IFD
    /// field. ImageIO surfaces them as one sub-dictionary, so removing the whole
    /// dictionary is the conformant action.
    func test_strip_clears_the_GPS_dictionary_in_full() throws {
        let url = try makeJpeg(gps: [
            kCGImagePropertyGPSLatitude: 35.6895,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.6917,
            kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 25.0,
            kCGImagePropertyGPSAltitudeRef: 0,
            kCGImagePropertyGPSDateStamp: "2026:05:07",
            kCGImagePropertyGPSTimeStamp: "12:00:00",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNotNil(gpsDictionary(at: url), "fixture GPS dict must be present pre-strip")
        XCTAssertTrue(ExifGpsStripper.hasGpsTags(at: url))

        switch ExifGpsStripper.strip(at: url) {
        case .stripped(let loc):
            XCTAssertEqual(loc, 1)
        default: XCTFail("expected .stripped")
        }
        XCTAssertNil(gpsDictionary(at: url), "GPS dict must be absent post-strip")
        XCTAssertFalse(ExifGpsStripper.hasGpsTags(at: url))
    }

    /// SPEC.md §F.3: post-strip verification — running `strip` twice on the same file
    /// returns `noChange` the second time, because the first pass cleared everything.
    func test_strip_is_idempotent_returns_noChange_on_second_pass() throws {
        let url = try makeJpeg(gps: [
            kCGImagePropertyGPSLatitude: 35.0,
            kCGImagePropertyGPSLatitudeRef: "N",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        switch ExifGpsStripper.strip(at: url) {
        case .stripped: break
        default: XCTFail("expected first pass to strip")
        }

        switch ExifGpsStripper.strip(at: url) {
        case .noChange: break
        default: XCTFail("expected second pass to be noChange")
        }
    }

    /// SPEC.md §A.2: stripping a file that has no targeted metadata returns `noChange`
    /// without touching the file. The contract is "we never modify bytes when there's
    /// nothing to clear" — important because the strip path is post-consent and the user
    /// expects deterministic outcomes.
    func test_strip_noChange_when_no_targeted_metadata_is_present() throws {
        let url = try makeJpeg() // bare 1x1 with no GPS / Exif / TIFF identity
        defer { try? FileManager.default.removeItem(at: url) }

        let attrsBefore = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtimeBefore = attrsBefore[.modificationDate] as? Date

        switch ExifGpsStripper.strip(at: url) {
        case .noChange: break
        default: XCTFail("expected noChange")
        }

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtimeAfter = attrsAfter[.modificationDate] as? Date
        XCTAssertEqual(mtimeBefore, mtimeAfter,
            "file mtime must not change when there's nothing to strip")
    }

    /// SPEC.md §A.1: hasGpsTags is the read-only existence check used to decide whether to
    /// queue a media item. It must be cheap (no temp file, no destination).
    func test_hasGpsTags_returns_false_for_a_file_without_GPS() throws {
        let url = try makeJpeg(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:01:01 00:00:00"])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ExifGpsStripper.hasGpsTags(at: url))
    }

    func test_hasGpsTags_returns_true_for_a_file_with_GPS() throws {
        let url = try makeJpeg(gps: [
            kCGImagePropertyGPSLatitude: 0.0,
            kCGImagePropertyGPSLatitudeRef: "N",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ExifGpsStripper.hasGpsTags(at: url))
    }
}
