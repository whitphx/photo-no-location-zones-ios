import XCTest
@testable import PhotoNoLocationZones

/// XCTest mirrors of the Android reference `Mp4GpsReaderTest`. SPEC.md §E pinning.
final class Mp4GpsReaderTests: XCTestCase {

    /// Mirrors `Mp4GpsReaderTest."parses prefixed QuickTime payload"`.
    func test_parses_prefixed_QuickTime_payload() {
        let xyz = boxWithTypeCode(Mp4Atoms.XYZ, payload: quicktimeStringPayload("+35.6895+139.6917/"))
        let reader = ByteArrayBoxReader(box(type: "moov", payload: box(type: "udta", payload: xyz)))
        let coords = Mp4GpsReader.readGps(reader: reader)
        XCTAssertNotNil(coords)
        XCTAssertEqual(coords!.0, 35.6895, accuracy: 1e-9)
        XCTAssertEqual(coords!.1, 139.6917, accuracy: 1e-9)
    }

    /// Mirrors `Mp4GpsReaderTest."falls back to raw payload when prefix is absent"`.
    func test_falls_back_to_raw_payload_when_prefix_is_absent() {
        // Some non-conformant writers emit just the ISO 6709 text with no length prefix.
        // The prefixed parse skips the first 4 bytes and ends up with a string that the
        // regex either doesn't match or matches with out-of-range numbers (rejected by the
        // range guard); the fallback then re-runs against the whole payload.
        let raw = Array("+12.34+56.78/".utf8)
        let xyz = boxWithTypeCode(Mp4Atoms.XYZ, payload: raw)
        let reader = ByteArrayBoxReader(box(type: "moov", payload: box(type: "udta", payload: xyz)))
        let coords = Mp4GpsReader.readGps(reader: reader)
        XCTAssertNotNil(coords)
        XCTAssertEqual(coords!.0, 12.34, accuracy: 1e-9)
        XCTAssertEqual(coords!.1, 56.78, accuracy: 1e-9)
    }

    /// Mirrors `Mp4GpsReaderTest."negative coordinates round-trip"`.
    func test_negative_coordinates_round_trip() {
        let xyz = boxWithTypeCode(Mp4Atoms.XYZ, payload: quicktimeStringPayload("-33.8688-151.2093/"))
        let reader = ByteArrayBoxReader(box(type: "moov", payload: box(type: "udta", payload: xyz)))
        let coords = Mp4GpsReader.readGps(reader: reader)
        XCTAssertNotNil(coords)
        XCTAssertEqual(coords!.0, -33.8688, accuracy: 1e-9)
        XCTAssertEqual(coords!.1, -151.2093, accuracy: 1e-9)
    }

    /// Mirrors `Mp4GpsReaderTest."out-of-range pair is rejected"`.
    func test_out_of_range_pair_is_rejected() {
        let xyz = boxWithTypeCode(Mp4Atoms.XYZ, payload: quicktimeStringPayload("+999.0+0.0/"))
        let reader = ByteArrayBoxReader(box(type: "moov", payload: box(type: "udta", payload: xyz)))
        XCTAssertNil(Mp4GpsReader.readGps(reader: reader))
    }

    /// Mirrors `Mp4GpsReaderTest."returns null when no xyz atom is present"`.
    func test_returns_null_when_no_xyz_atom_is_present() {
        let data = box(
            type: "moov",
            payload: box(type: "udta", payload: box(type: "loci", payload: [UInt8](repeating: 0, count: 8)))
        )
        let reader = ByteArrayBoxReader(data)
        XCTAssertNil(Mp4GpsReader.readGps(reader: reader))
    }

    /// Mirrors `Mp4GpsReaderTest."returns null when moov is absent"`.
    func test_returns_null_when_moov_is_absent() {
        let reader = ByteArrayBoxReader(box(type: "ftyp", payload: [UInt8](repeating: 0, count: 16)))
        XCTAssertNil(Mp4GpsReader.readGps(reader: reader))
    }

    /// Mirrors `Mp4GpsReaderTest."parseIso6709 accepts integer-only coordinates"`.
    func test_parseIso6709_accepts_integer_only_coordinates() {
        let coords = Mp4GpsReader.parseIso6709("+35+139/")
        XCTAssertNotNil(coords)
        XCTAssertEqual(coords!.0, 35.0, accuracy: 1e-9)
        XCTAssertEqual(coords!.1, 139.0, accuracy: 1e-9)
    }

    /// Mirrors `Mp4GpsReaderTest."parseIso6709 rejects strings without a leading sign on either number"`.
    func test_parseIso6709_rejects_strings_without_a_leading_sign_on_either_number() {
        XCTAssertNil(Mp4GpsReader.parseIso6709("35.0 139.0"))
    }

    /// Mirrors `Mp4GpsReaderTest."parseIso6709 enforces lat-lon ranges"`.
    func test_parseIso6709_enforces_lat_lon_ranges() {
        XCTAssertNil(Mp4GpsReader.parseIso6709("+91.0+0.0/"))
        XCTAssertNil(Mp4GpsReader.parseIso6709("+0.0+181.0/"))
        XCTAssertNotNil(Mp4GpsReader.parseIso6709("-90.0-180.0/"))
        XCTAssertNotNil(Mp4GpsReader.parseIso6709("+90.0+180.0/"))
    }
}
