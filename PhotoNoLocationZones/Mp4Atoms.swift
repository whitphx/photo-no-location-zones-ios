import Foundation

/// Minimal ISO BMFF / QuickTime atom walker — the thinnest layer of MP4 parsing the GPS reader
/// and stripper need.
///
/// An ISO BMFF file is a sequence of "boxes" (a.k.a. atoms): each box is `[size:4][type:4][payload]`.
///  - `size == 1` means an extended 64-bit size follows in the next 8 bytes.
///  - `size == 0` means "extends to the end of the enclosing scope" (top-level: end of file).
/// "Container" boxes (e.g. `moov`, `udta`) just contain more boxes; "leaf" boxes have format-specific
/// payloads we don't decode here. The walker is intentionally non-recursive — callers re-invoke it
/// for the children of a container they care about (`moov`, `udta`).
///
/// On the wire the type field is conventionally a 4-char ASCII code (`'m','o','o','v'`). We pack
/// it into a single 32-bit big-endian `UInt32` for cheap equality checks. QuickTime location atoms
/// use the non-ASCII byte `0xA9` ('©'), so we expose `atomBytes` alongside `atom` for those.
///
/// Reads go through `BoxReader` rather than directly hitting `FileHandle` so the walker is testable
/// with synthetic byte arrays — production code uses `FileHandleBoxReader`.
///
/// SPEC.md §F: this is the algorithmic core that must match the Android reference byte-for-byte.
enum Mp4Atoms {
    static let MOOV: UInt32 = atom("moov")
    static let UDTA: UInt32 = atom("udta")
    static let META: UInt32 = atom("meta")
    static let FREE: UInt32 = atom("free")

    /// Apple/QuickTime location string in ISO 6709 format: `©xyz`.
    static let XYZ: UInt32 = atomBytes(0xA9, UInt8(ascii: "x"), UInt8(ascii: "y"), UInt8(ascii: "z"))

    /// 3GPP location info atom — older but still seen on some Android cameras.
    static let LOCI: UInt32 = atom("loci")

    /// Atoms whose type-tag the stripper rewrites to `free` to neutralize the GPS payload.
    static let LOCATION_ATOMS: Set<UInt32> = [XYZ, LOCI]

    /// Wire bytes of `free` — used by the stripper when re-tagging a location atom.
    static let FREE_BYTES: [UInt8] = [
        UInt8(ascii: "f"), UInt8(ascii: "r"), UInt8(ascii: "e"), UInt8(ascii: "e"),
    ]

    static func atom(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8)
        precondition(bytes.count == 4, "atom code must be 4 chars: \(s)")
        return (UInt32(bytes[0]) << 24)
             | (UInt32(bytes[1]) << 16)
             | (UInt32(bytes[2]) << 8)
             |  UInt32(bytes[3])
    }

    static func atomBytes(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        return (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    /// Walk the boxes between `[start, end)`. For each, invoke `onBox` with:
    ///  - `type`: 4-byte type packed big-endian (use `atom` / `atomBytes` for comparisons)
    ///  - `payloadStart`: offset of the first payload byte (after size + type, and after any
    ///    extended-size word)
    ///  - `payloadEnd`: offset one past the last payload byte
    ///  - `typeOffset`: offset of the 4-byte type field — useful for in-place re-tag.
    ///
    /// Aborts the scan silently on a malformed size (negative, zero-length payload, or running off
    /// the end). The strip flow tolerates partial walks: if we can't reach a GPS atom we just don't
    /// clear it, and the post-strip verification will warn.
    static func walkBoxes(
        reader: BoxReader,
        start: Int64,
        end: Int64,
        onBox: (_ type: UInt32, _ payloadStart: Int64, _ payloadEnd: Int64, _ typeOffset: Int64) -> Void
    ) {
        var pos = start
        while pos + 8 <= end {
            let header = reader.read(at: pos, length: 8)
            if header.count < 8 { return }
            let size32 = (UInt32(header[0]) << 24)
                       | (UInt32(header[1]) << 16)
                       | (UInt32(header[2]) << 8)
                       |  UInt32(header[3])
            let type = (UInt32(header[4]) << 24)
                     | (UInt32(header[5]) << 16)
                     | (UInt32(header[6]) << 8)
                     |  UInt32(header[7])
            let typeOffset = pos + 4
            let payloadStart: Int64
            let payloadEnd: Int64
            switch size32 {
            case 0:
                payloadStart = pos + 8
                payloadEnd = end
            case 1:
                let ext = reader.read(at: pos + 8, length: 8)
                if ext.count < 8 { return }
                let size64 = (UInt64(ext[0]) << 56)
                           | (UInt64(ext[1]) << 48)
                           | (UInt64(ext[2]) << 40)
                           | (UInt64(ext[3]) << 32)
                           | (UInt64(ext[4]) << 24)
                           | (UInt64(ext[5]) << 16)
                           | (UInt64(ext[6]) << 8)
                           |  UInt64(ext[7])
                if size64 < 16 || pos + Int64(size64) > end { return }
                payloadStart = pos + 16
                payloadEnd = pos + Int64(size64)
            default:
                if size32 < 8 { return }
                let absEnd = pos + Int64(size32)
                if absEnd > end { return }
                payloadStart = pos + 8
                payloadEnd = absEnd
            }
            if payloadEnd <= pos { return }
            onBox(type, payloadStart, payloadEnd, typeOffset)
            pos = payloadEnd
        }
    }
}

/// Random-access read interface for `Mp4Atoms.walkBoxes`. The protocol exists so the walker is
/// testable on the JVM-equivalent test harness (XCTest) with byte-array fixtures — production
/// code wraps a `FileHandle` via `FileHandleBoxReader`, tests can implement it against a
/// `[UInt8]`.
protocol BoxReader {
    /// File length in bytes.
    var size: Int64 { get }

    /// Reads up to `length` bytes at `position`; returns the bytes actually read. An empty array
    /// indicates EOF or an underlying read error. Implementations must not throw on EOF — return
    /// an empty array instead.
    func read(at position: Int64, length: Int) -> [UInt8]
}

struct FileHandleBoxReader: BoxReader {
    let handle: FileHandle
    let size: Int64

    init(handle: FileHandle) throws {
        self.handle = handle
        self.size = Int64(try handle.seekToEnd())
    }

    func read(at position: Int64, length: Int) -> [UInt8] {
        do {
            try handle.seek(toOffset: UInt64(position))
            guard let data = try handle.read(upToCount: length) else { return [] }
            return Array(data)
        } catch {
            return []
        }
    }
}
