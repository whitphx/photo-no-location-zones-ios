import Foundation
import os.log

/// Reads the location embedded in an MP4 / MOV by parsing the QuickTime `moov/udta/©xyz` atom.
///
/// SPEC.md §E. Stock Android camera apps (Pixel, Samsung One UI, OnePlus, etc.) write GPS into
/// this atom as an ISO 6709 string, e.g. `+35.6895+139.6917+25.000/`. We only target this single
/// path: it covers the common Android case at the cost of missing iPhone videos that use Apple's
/// `moov/meta/keys` + `moov/meta/ilst` indirection (a known gap).
enum Mp4GpsReader {

    /// Returns `(lat, lon)` or nil if no readable GPS atom is present.
    static func readLatLong(at url: URL) -> (Double, Double)? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let reader = try FileHandleBoxReader(handle: handle)
            return readGps(reader: reader)
        } catch {
            log.warning("readLatLong failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Visible for testing. Same algorithm as the URL entry point, but operates on any
    /// `BoxReader` so unit tests can drive it with synthetic byte arrays.
    static func readGps(reader: BoxReader) -> (Double, Double)? {
        var found: (Double, Double)? = nil
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { type, payloadStart, payloadEnd, _ in
            guard type == Mp4Atoms.MOOV, found == nil else { return }
            Mp4Atoms.walkBoxes(reader: reader, start: payloadStart, end: payloadEnd) { t2, p2s, p2e, _ in
                guard t2 == Mp4Atoms.UDTA, found == nil else { return }
                Mp4Atoms.walkBoxes(reader: reader, start: p2s, end: p2e) { t3, p3s, p3e, _ in
                    guard t3 == Mp4Atoms.XYZ, found == nil else { return }
                    let len = Int(p3e - p3s)
                    if len < 1 { return }
                    let buf = reader.read(at: p3s, length: len)
                    if buf.isEmpty { return }
                    found = parseAtomPayload(buf: buf, length: buf.count)
                }
            }
        }
        return found
    }

    /// Most cameras follow the QuickTime convention — `[u16 textLen][u16 language][text]` — so
    /// we try the prefixed parse first. A few non-conformant writers store the raw ISO 6709
    /// string with no header; in that case the prefixed parse either returns nil (range
    /// validation rejects bogus numbers) or never matches because the regex needs a leading
    /// sign at offset 4. The fallback re-runs the regex against the entire payload.
    static func parseAtomPayload(buf: [UInt8], length: Int) -> (Double, Double)? {
        if length >= 4 {
            let textLen = (Int(buf[0]) << 8) | Int(buf[1])
            let effective = max(0, min(textLen, length - 4))
            if effective > 0 {
                let end = min(4 + effective, buf.count)
                if let s = String(bytes: buf[4..<end], encoding: .utf8),
                   let coords = parseIso6709(s) {
                    return coords
                }
            }
        }
        let end = min(length, buf.count)
        if let s = String(bytes: buf[0..<end], encoding: .utf8) {
            return parseIso6709(s)
        }
        return nil
    }

    /// ISO 6709 simple form: `±DD.DDDD±DDD.DDDD[±AAA.AAA]/`. We pluck the first two signed
    /// numbers and ignore altitude / CRS suffixes — we only need lat/lon for the in-app map.
    /// Both values are range-validated so a partial parse (e.g. when a leading sign was
    /// stripped) is rejected rather than returned as a real location.
    static func parseIso6709(_ s: String) -> (Double, Double)? {
        guard let match = s.firstMatch(of: iso6709Pattern) else { return nil }
        let (_, latStr, lonStr) = match.output
        guard let lat = Double(latStr), let lon = Double(lonStr) else { return nil }
        if !(-90.0 ... 90.0).contains(lat) || !(-180.0 ... 180.0).contains(lon) { return nil }
        return (lat, lon)
    }

    private static let iso6709Pattern = #/([+\-]\d+(?:\.\d+)?)([+\-]\d+(?:\.\d+)?)/#

    private static let log = Logger(subsystem: "io.github.whitphx.nolocationzones", category: "Mp4GpsReader")
}
