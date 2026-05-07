import XCTest
@testable import PhotoNoLocationZones

/// XCTest mirrors of the Android reference `Mp4AtomsTest` (and the spec pinning tests for
/// `Mp4GpsStripper.findLocationAtomTypeOffsets`). Each method's snake_case name is the
/// slug-form of the JUnit display name in SPEC.md's "Test references" table; the doc comment
/// preserves the exact display name so a grep for either form lands here.
final class Mp4AtomsTests: XCTestCase {

    /// Mirrors `Mp4AtomsTest."walks a single top-level box"`.
    func test_walks_a_single_top_level_box() {
        let data = box(type: "moov", payload: [UInt8](repeating: 0, count: 16))
        let reader = ByteArrayBoxReader(data)
        var seen: [UInt32] = []
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { type, _, _, _ in
            seen.append(type)
        }
        XCTAssertEqual(seen, [Mp4Atoms.MOOV])
    }

    /// Mirrors `Mp4AtomsTest."walks multiple top-level boxes in order"`.
    func test_walks_multiple_top_level_boxes_in_order() {
        let data = box(type: "ftyp", payload: [UInt8](repeating: 0, count: 8))
                 + box(type: "moov", payload: [UInt8](repeating: 0, count: 8))
                 + box(type: "free")
        let reader = ByteArrayBoxReader(data)
        var seen: [UInt32] = []
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { type, _, _, _ in
            seen.append(type)
        }
        XCTAssertEqual(seen, [Mp4Atoms.atom("ftyp"), Mp4Atoms.MOOV, Mp4Atoms.FREE])
    }

    /// Mirrors `Mp4AtomsTest."nested walk recurses into containers"`.
    func test_nested_walk_recurses_into_containers() {
        let xyzBox = boxWithTypeCode(Mp4Atoms.XYZ, payload: [UInt8](repeating: 0, count: 4))
        let udtaBox = box(type: "udta", payload: xyzBox)
        let moovBox = box(type: "moov", payload: udtaBox)
        let reader = ByteArrayBoxReader(moovBox)

        var foundXyz: [Int64] = []
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { t1, p1s, p1e, _ in
            guard t1 == Mp4Atoms.MOOV else { return }
            Mp4Atoms.walkBoxes(reader: reader, start: p1s, end: p1e) { t2, p2s, p2e, _ in
                guard t2 == Mp4Atoms.UDTA else { return }
                Mp4Atoms.walkBoxes(reader: reader, start: p2s, end: p2e) { t3, _, _, t3o in
                    if t3 == Mp4Atoms.XYZ { foundXyz.append(t3o) }
                }
            }
        }
        XCTAssertEqual(foundXyz.count, 1)
    }

    /// Mirrors `Mp4AtomsTest."typeOffset points at the four bytes after size"`.
    func test_typeOffset_points_at_the_four_bytes_after_size() {
        let data = box(type: "ftyp", payload: [UInt8](repeating: 0, count: 4))
                 + box(type: "moov", payload: [UInt8](repeating: 0, count: 4))
        let reader = ByteArrayBoxReader(data)
        var typeOffsets: [Int64] = []
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { _, _, _, off in
            typeOffsets.append(off)
        }
        // First box: size at 0, type at 4. Second box: starts at 12 (size 12), type at 16.
        XCTAssertEqual(typeOffsets, [4, 16])
        // Verify the type-tag bytes at those offsets are the ASCII codes themselves.
        XCTAssertEqual(reader.read(at: typeOffsets[0], length: 4), Array("ftyp".utf8))
        XCTAssertEqual(reader.read(at: typeOffsets[1], length: 4), Array("moov".utf8))
    }

    /// Mirrors `Mp4AtomsTest."size equals zero extends to end of scope"`.
    func test_size_equals_zero_extends_to_end_of_scope() {
        // size = 0 sentinel: box must extend to the enclosing scope's end.
        let payload = (0..<20).map { UInt8($0) }
        let data = rawHeader(size32: 0, type: "moov") + payload
        let reader = ByteArrayBoxReader(data)
        var seenEnd: Int64 = -1
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { _, _, payloadEnd, _ in
            seenEnd = payloadEnd
        }
        XCTAssertEqual(seenEnd, reader.size)
    }

    /// Mirrors `Mp4AtomsTest."extended 64-bit size is decoded"`.
    func test_extended_64_bit_size_is_decoded() {
        let payload: [UInt8] = Array(repeating: 0xAB, count: 8)
        let totalSize = UInt64(16 + payload.count)
        var data = rawHeader(size32: 1, type: "moov")
        // 8-byte big-endian size64
        for i in (0..<8).reversed() {
            data.append(UInt8((totalSize >> (8 * i)) & 0xFF))
        }
        data.append(contentsOf: payload)
        let reader = ByteArrayBoxReader(data)
        var seenStart: Int64 = -1
        var seenEnd: Int64 = -1
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { _, payloadStart, payloadEnd, _ in
            seenStart = payloadStart
            seenEnd = payloadEnd
        }
        XCTAssertEqual(seenStart, 16)
        XCTAssertEqual(seenEnd, Int64(totalSize))
    }

    /// Mirrors `Mp4AtomsTest."malformed size below header length is rejected"`.
    func test_malformed_size_below_header_length_is_rejected() {
        // size = 4 is too small to even contain the header (8 bytes). Walker must abort cleanly.
        let data = rawHeader(size32: 4, type: "moov")
        let reader = ByteArrayBoxReader(data)
        var seen = 0
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { _, _, _, _ in
            seen += 1
        }
        XCTAssertEqual(seen, 0)
    }

    /// Mirrors `Mp4AtomsTest."size running past end aborts"`.
    func test_size_running_past_end_aborts() {
        // size = 16 declared but the file is only 12 bytes long.
        var data = rawHeader(size32: 16, type: "moov")
        data.append(contentsOf: [0, 0, 0, 0]) // 4 bytes of payload
        let reader = ByteArrayBoxReader(data)
        var seen = 0
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { _, _, _, _ in
            seen += 1
        }
        XCTAssertEqual(seen, 0)
    }

    /// Mirrors `Mp4AtomsTest."under eight bytes does not call the callback"`.
    func test_under_eight_bytes_does_not_call_the_callback() {
        let reader = ByteArrayBoxReader([UInt8](repeating: 0, count: 7))
        var seen = 0
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { _, _, _, _ in
            seen += 1
        }
        XCTAssertEqual(seen, 0)
    }

    /// Mirrors `Mp4AtomsTest."walk skips deeper into a nested udta with multiple children"`.
    func test_walk_skips_deeper_into_a_nested_udta_with_multiple_children() {
        let loci = box(type: "loci", payload: [UInt8](repeating: 0, count: 4))
        let xyz = boxWithTypeCode(Mp4Atoms.XYZ, payload: [UInt8](repeating: 0, count: 4))
        let free = box(type: "free", payload: [UInt8](repeating: 0, count: 4))
        let udtaPayload = loci + xyz + free
        let moovPayload = box(type: "udta", payload: udtaPayload)
        let data = box(type: "moov", payload: moovPayload)
        let reader = ByteArrayBoxReader(data)

        var children: [UInt32] = []
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { t1, p1s, p1e, _ in
            guard t1 == Mp4Atoms.MOOV else { return }
            Mp4Atoms.walkBoxes(reader: reader, start: p1s, end: p1e) { t2, p2s, p2e, _ in
                guard t2 == Mp4Atoms.UDTA else { return }
                Mp4Atoms.walkBoxes(reader: reader, start: p2s, end: p2e) { t3, _, _, _ in
                    children.append(t3)
                }
            }
        }
        XCTAssertEqual(children, [Mp4Atoms.LOCI, Mp4Atoms.XYZ, Mp4Atoms.FREE])
    }

    /// Mirrors `Mp4AtomsTest."findLocationAtomTypeOffsets locates xyz and loci nested under moov udta"`.
    func test_findLocationAtomTypeOffsets_locates_xyz_and_loci_nested_under_moov_udta() {
        let xyz = boxWithTypeCode(Mp4Atoms.XYZ, payload: quicktimeStringPayload("+35.0+139.0/"))
        let loci = box(type: "loci", payload: [UInt8](repeating: 0, count: 8))
        let udta = box(type: "udta", payload: xyz + loci)
        let moov = box(type: "moov", payload: udta)
        let data = box(type: "ftyp", payload: [UInt8](repeating: 0, count: 8)) + moov
        let reader = ByteArrayBoxReader(data)

        let offsets = Mp4GpsStripper.findLocationAtomTypeOffsets(reader: reader)
        XCTAssertEqual(offsets.count, 2)
        // Verify the type bytes at the reported offsets are the actual location atom types.
        let firstType = reader.read(at: offsets[0], length: 4)
        let firstPacked = (UInt32(firstType[0]) << 24) | (UInt32(firstType[1]) << 16)
                        | (UInt32(firstType[2]) << 8) | UInt32(firstType[3])
        XCTAssertEqual(firstPacked, Mp4Atoms.XYZ)
        XCTAssertEqual(reader.read(at: offsets[1], length: 4), Array("loci".utf8))
    }

    /// Mirrors `Mp4AtomsTest."findLocationAtomTypeOffsets returns empty when moov udta absent"`.
    func test_findLocationAtomTypeOffsets_returns_empty_when_moov_udta_absent() {
        let data = box(type: "ftyp", payload: [UInt8](repeating: 0, count: 8))
                 + box(type: "free", payload: [UInt8](repeating: 0, count: 8))
        let reader = ByteArrayBoxReader(data)
        XCTAssertTrue(Mp4GpsStripper.findLocationAtomTypeOffsets(reader: reader).isEmpty)
    }
}
