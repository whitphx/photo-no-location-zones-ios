import Foundation
import os.log

/// Removes location atoms (`moov/udta/©xyz`, `moov/udta/loci`) from an MP4 / MOV by overwriting
/// each atom's 4-byte type field in place with `free`.
///
/// SPEC.md §D + §F: re-tag instead of delete. A `free` box is a valid ISO BMFF atom whose contents
/// must be ignored by readers, so retagging keeps the file's byte layout identical (every other
/// atom's offset is preserved) and we never have to relocate `moov`, recompute chunk offsets in
/// `stco`/`co64`, or re-mux `mdat`. The cost is a sliver of dead bytes — worth it for the
/// simplicity. Algorithmic identity with the Android reference is the cross-platform contract.
///
/// What we don't cover (documented as gaps in SPEC.md):
///  - **Apple `moov/meta/keys` + `meta/ilst` location indirection** (used by iPhone-recorded
///    `.mov`). Decoding requires walking the keys table and matching by name; not yet implemented.
///  - **`mdat`-embedded telemetry** (GoPro GPMF, DJI subtitle tracks). Different file altogether.
///
/// Caller must hold write access to `url`. On iOS, that means writes go through a
/// `PHContentEditingInput`/`Output` flow whose `contentEditingOutput.renderedContentURL` is the
/// destination — `strip(at:)` does not call PhotoKit itself.
enum Mp4GpsStripper {

    enum Result {
        case noChange
        case stripped(locationAtomsCleared: Int)
        case failed(Error)
    }

    /// Read-only existence check. Cheap because we walk only `moov/udta`, never the bulk `mdat`.
    static func hasLocationAtoms(at url: URL) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let reader = try FileHandleBoxReader(handle: handle)
            return !findLocationAtomTypeOffsets(reader: reader).isEmpty
        } catch {
            log.warning("hasLocationAtoms failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func strip(at url: URL) -> Result {
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            return .failed(error)
        }
        defer { try? handle.close() }

        do {
            let reader = try FileHandleBoxReader(handle: handle)
            let typeOffsets = findLocationAtomTypeOffsets(reader: reader)
            if typeOffsets.isEmpty { return .noChange }

            for off in typeOffsets {
                try handle.seek(toOffset: UInt64(off))
                try handle.write(contentsOf: Mp4Atoms.FREE_BYTES)
            }
            try? handle.synchronize()
            log.info("Cleared \(typeOffsets.count) location atom(s) from \(url.lastPathComponent, privacy: .public)")

            verifyClean(reader: reader, url: url)
            return .stripped(locationAtomsCleared: typeOffsets.count)
        } catch {
            log.warning("Strip failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed(error)
        }
    }

    /// Visible for testing — operates on any `BoxReader`. Returns the absolute byte offsets of
    /// the 4-byte type tag of every recognised location atom found inside `moov/udta`.
    static func findLocationAtomTypeOffsets(reader: BoxReader) -> [Int64] {
        var results: [Int64] = []
        Mp4Atoms.walkBoxes(reader: reader, start: 0, end: reader.size) { type, payloadStart, payloadEnd, _ in
            guard type == Mp4Atoms.MOOV else { return }
            Mp4Atoms.walkBoxes(reader: reader, start: payloadStart, end: payloadEnd) { t2, p2s, p2e, _ in
                guard t2 == Mp4Atoms.UDTA else { return }
                Mp4Atoms.walkBoxes(reader: reader, start: p2s, end: p2e) { t3, _, _, t3o in
                    if Mp4Atoms.LOCATION_ATOMS.contains(t3) {
                        results.append(t3o)
                    }
                }
            }
        }
        return results
    }

    /// Re-walk after the strip and warn loudly if any location atom survived.
    private static func verifyClean(reader: BoxReader, url: URL) {
        let survivors = findLocationAtomTypeOffsets(reader: reader)
        if !survivors.isEmpty {
            log.warning("Post-strip verification: \(survivors.count) location atom(s) survived for \(url.lastPathComponent, privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "io.github.whitphx.nolocationzones", category: "Mp4GpsStripper")
}
