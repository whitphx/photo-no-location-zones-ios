import Foundation
@testable import PhotoNoLocationZones

/// Test helpers for building synthetic ISO BMFF byte arrays and feeding them to the walker.
/// Mirrors the `Mp4Fixtures` file in the Android reference test sources so spec-pinned tests
/// can be ported byte-for-byte.

final class ByteArrayBoxReader: BoxReader {
    let data: [UInt8]

    init(_ data: [UInt8]) {
        self.data = data
    }

    var size: Int64 { Int64(data.count) }

    func read(at position: Int64, length: Int) -> [UInt8] {
        guard position >= 0, position < Int64(data.count) else { return [] }
        let start = Int(position)
        let end = Swift.min(start + length, data.count)
        return Array(data[start..<end])
    }
}

/// Build a 32-bit-sized ISO BMFF box: `[size:4][type:4][payload]`.
func box(type: String, payload: [UInt8] = []) -> [UInt8] {
    precondition(type.utf8.count == 4, "type must be 4 chars: \(type)")
    let size = 8 + payload.count
    var bytes: [UInt8] = []
    bytes.append(UInt8((size >> 24) & 0xFF))
    bytes.append(UInt8((size >> 16) & 0xFF))
    bytes.append(UInt8((size >> 8) & 0xFF))
    bytes.append(UInt8(size & 0xFF))
    bytes.append(contentsOf: type.utf8)
    bytes.append(contentsOf: payload)
    return bytes
}

/// Build a box whose 4-byte type field is given as a packed `UInt32` (for non-ASCII types like `©xyz`).
func boxWithTypeCode(_ typeCode: UInt32, payload: [UInt8] = []) -> [UInt8] {
    let size = 8 + payload.count
    var bytes: [UInt8] = []
    bytes.append(UInt8((size >> 24) & 0xFF))
    bytes.append(UInt8((size >> 16) & 0xFF))
    bytes.append(UInt8((size >> 8) & 0xFF))
    bytes.append(UInt8(size & 0xFF))
    bytes.append(UInt8((typeCode >> 24) & 0xFF))
    bytes.append(UInt8((typeCode >> 16) & 0xFF))
    bytes.append(UInt8((typeCode >> 8) & 0xFF))
    bytes.append(UInt8(typeCode & 0xFF))
    bytes.append(contentsOf: payload)
    return bytes
}

/// Build the 4-byte payload prefix used by QuickTime `©xyz`:
/// `[u16 textLen][u16 language][text...]`.
func quicktimeStringPayload(_ text: String, language: UInt16 = 0) -> [UInt8] {
    let textBytes = Array(text.utf8)
    var bytes: [UInt8] = []
    let len = UInt16(textBytes.count)
    bytes.append(UInt8((len >> 8) & 0xFF))
    bytes.append(UInt8(len & 0xFF))
    bytes.append(UInt8((language >> 8) & 0xFF))
    bytes.append(UInt8(language & 0xFF))
    bytes.append(contentsOf: textBytes)
    return bytes
}

/// Build a 32-bit big-endian size header followed by a literal type word — for tests that need
/// to construct malformed boxes (size too small, size==0 sentinel, etc.) directly.
func rawHeader(size32: UInt32, type: String) -> [UInt8] {
    precondition(type.utf8.count == 4)
    var bytes: [UInt8] = []
    bytes.append(UInt8((size32 >> 24) & 0xFF))
    bytes.append(UInt8((size32 >> 16) & 0xFF))
    bytes.append(UInt8((size32 >> 8) & 0xFF))
    bytes.append(UInt8(size32 & 0xFF))
    bytes.append(contentsOf: type.utf8)
    return bytes
}
