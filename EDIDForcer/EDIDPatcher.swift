//
//  EDIDPatcher.swift
//  EDIDForcer
//
//  Deterministic, spec-driven EDID transforms. Each patch touches only the bytes
//  and checksum(s) it needs, so any combination composes safely via
//  `patched(_:options:)`. Each strip function has a read-only `has...` counterpart
//  used to verify a patch actually took, by reading the display back.
//
//  1. Force 8bpc: sets the Video Input Definition byte (EDID 1.4 §3.6.1, base
//     block offset 20) to declare 8 bits per component.
//
//  2. Strip HDR static metadata: removes the CTA-861.3 HDR Static Metadata Data
//     Block (extended tag 0x06) from any CTA-861 extension block, so the display
//     reports as SDR-only.
//
//  3. Strip VRR signaling (HDMI only): truncates the HDMI Forum Vendor-Specific
//     Data Block (IEEE OUI C4-5D-D8) to its pre-HDMI-2.1 baseline payload, which
//     drops VRR/CNMVRR/ALLM/QMS signaling along with it. Truncating avoids
//     depending on the exact bit position of any one flag. Has no effect on a
//     DisplayPort connection, where VRR is negotiated via DPCD rather than EDID.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.example.EDIDForcer", category: "EDIDPatcher")

enum EDIDBitDepth: UInt8, CustomStringConvertible {
    case undefined = 0
    case sixBpc = 1
    case eightBpc = 2
    case tenBpc = 3
    case twelveBpc = 4
    case fourteenBpc = 5
    case sixteenBpc = 6
    case reserved = 7

    var description: String {
        switch self {
        case .undefined: return "undefined"
        case .sixBpc: return "6 bpc"
        case .eightBpc: return "8 bpc"
        case .tenBpc: return "10 bpc"
        case .twelveBpc: return "12 bpc"
        case .fourteenBpc: return "14 bpc"
        case .sixteenBpc: return "16 bpc"
        case .reserved: return "reserved"
        }
    }
}

enum EDIDPatcherError: Error, CustomStringConvertible {
    case tooShort
    case notDigital
    case badChecksum(offset: Int)

    var description: String {
        switch self {
        case .tooShort: return "EDID is shorter than 128 bytes — not a valid base block"
        case .notDigital: return "Video Input Definition byte says this is an analog display; bit-depth field doesn't apply"
        case .badChecksum(let offset): return "Checksum mismatch at block starting offset \(offset) — refusing to patch a malformed EDID"
        }
    }
}

/// Which deterministic patches to apply, composed together into a single EDID.
struct EDIDPatchOptions {
    var forceEightBpc = false
    var stripHDRMetadata = false
    var stripVRRSignaling = false

    var isNoop: Bool {
        !forceEightBpc && !stripHDRMetadata && !stripVRRSignaling
    }
}

struct EDIDPatcher {
    private static let videoInputDefinitionOffset = 20
    private static let baseBlockChecksumOffset = 127
    private static let baseBlockSize = 128
    /// Baseline (pre-HDMI-2.1) payload length for the HDMI Forum VSDB, shared
    /// between `stripVRRSignaling` and `hasExtendedVRRSignaling` so they stay in sync.
    private static let vrrBaselinePayload = 6

    /// Reports the bit depth this EDID's base block currently declares, if it's a
    /// digital display. Read-only, no side effects.
    static func currentBitDepth(of edid: Data) -> EDIDBitDepth? {
        guard edid.count >= baseBlockSize else { return nil }
        let vid = edid[edid.startIndex + videoInputDefinitionOffset]
        guard (vid & 0x80) != 0 else { return nil } // bit 7: 1 = digital
        return EDIDBitDepth(rawValue: (vid >> 4) & 0b111)
    }

    /// Validates every 128-byte block's checksum sums to 0 mod 256 (the standard
    /// EDID rule). Read-only.
    static func validateChecksums(_ edid: Data) -> Bool {
        guard edid.count % baseBlockSize == 0, edid.count > 0 else { return false }
        var offset = edid.startIndex
        while offset < edid.endIndex {
            let block = edid[offset ..< offset + baseBlockSize]
            let sum = block.reduce(0) { UInt8((Int($0) + Int($1)) % 256) }
            if sum != 0 { return false }
            offset += baseBlockSize
        }
        return true
    }

    /// Applies every patch enabled in `options`, in sequence, to a single EDID.
    /// Each patch only touches the block(s) and checksum(s) relevant to it, so any
    /// combination of options composes safely.
    static func patched(_ edid: Data, options: EDIDPatchOptions) throws -> Data {
        var result = edid
        if options.forceEightBpc {
            result = try patched(result, to: .eightBpc)
        }
        if options.stripHDRMetadata {
            result = stripHDRStaticMetadata(result)
        }
        if options.stripVRRSignaling {
            result = stripVRRSignaling(result)
        }
        return result
    }

    /// Returns a copy of `edid` with the base block's declared bit depth changed to
    /// `target`, and the base-block checksum byte recomputed. Extension blocks are
    /// returned byte-for-byte unchanged.
    static func patched(_ edid: Data, to target: EDIDBitDepth = .eightBpc) throws -> Data {
        guard edid.count >= baseBlockSize else {
            logger.error("patched: EDID is \(edid.count, privacy: .public) bytes, need >= \(baseBlockSize, privacy: .public)")
            throw EDIDPatcherError.tooShort
        }
        var bytes = [UInt8](edid)

        let vidOffset = videoInputDefinitionOffset
        let vid = bytes[vidOffset]
        guard (vid & 0x80) != 0 else {
            logger.error("patched: Video Input Definition byte 0x\(String(vid, radix: 16), privacy: .public) has bit 7 clear — analog display, not patchable")
            throw EDIDPatcherError.notDigital
        }

        try requireValidBaseBlockChecksum(bytes)

        // Clear bits 6:4 (the bit-depth field), then set them to the target value.
        let newVid = (vid & 0b1000_1111) | (target.rawValue << 4)
        let delta = Int(vid) - Int(newVid) // how much the byte decreased (mod 256 arithmetic below)

        bytes[vidOffset] = newVid
        // Recompute the checksum byte so the base block still sums to 0 mod 256.
        // Equivalent to: newChecksum = oldChecksum + delta (mod 256).
        let oldChecksum = Int(bytes[baseBlockChecksumOffset])
        bytes[baseBlockChecksumOffset] = UInt8(((oldChecksum + delta) % 256 + 256) % 256)

        logger.info("patched(bitDepth): vid byte 0x\(String(vid, radix: 16), privacy: .public) -> 0x\(String(newVid, radix: 16), privacy: .public) (target \(target.description, privacy: .public)), checksum 0x\(String(oldChecksum, radix: 16), privacy: .public) -> 0x\(String(bytes[baseBlockChecksumOffset], radix: 16), privacy: .public)")

        return Data(bytes)
    }

    /// Removes the CTA-861.3 HDR Static Metadata Data Block (extended tag 0x06)
    /// from any CTA-861 extension block present, if found. A no-op (returns `edid`
    /// unchanged) if there's no CTA-861 extension or no such block in it.
    static func stripHDRStaticMetadata(_ edid: Data) -> Data {
        editExtensionBlocks(edid) { block, dbcEnd in
            guard let ref = dataBlocks(in: block, dbcStart: 4, dbcEnd: dbcEnd)
                .first(where: { $0.tag == 7 && $0.extendedTag == 0x06 }) else {
                logger.info("stripHDRStaticMetadata: no HDR Static Metadata block found in this extension block")
                return nil
            }
            let oldSize = ref.totalSize
            shiftLeft(in: &block, from: ref.headerOffset + oldSize, to: dbcEnd, by: oldSize)
            logger.info("stripHDRStaticMetadata: removed HDR Static Metadata data block (\(oldSize, privacy: .public) bytes)")
            return dbcEnd - oldSize
        }
    }

    /// Truncates the HDMI Forum Vendor-Specific Data Block (IEEE OUI C4-5D-D8) down
    /// to its baseline 6-byte payload (OUI + version + max TMDS rate + one flags
    /// byte), dropping the HDMI-2.1-era extension bytes where VRR/CNMVRR/ALLM/QMS
    /// are signaled. A no-op if there's no such block, or it's already at/below
    /// that size.
    static func stripVRRSignaling(_ edid: Data) -> Data {
        editExtensionBlocks(edid) { block, dbcEnd in
            guard let ref = dataBlocks(in: block, dbcStart: 4, dbcEnd: dbcEnd).first(where: { ref in
                ref.tag == 3 && ref.length >= 3
                    && block[ref.headerOffset + 1] == 0xD8
                    && block[ref.headerOffset + 2] == 0x5D
                    && block[ref.headerOffset + 3] == 0xC4
            }) else {
                logger.info("stripVRRSignaling: no HDMI Forum VSDB found in this extension block")
                return nil
            }
            guard ref.length > vrrBaselinePayload else {
                logger.info("stripVRRSignaling: HDMI Forum VSDB payload already <= \(vrrBaselinePayload, privacy: .public) bytes, nothing to strip")
                return nil
            }
            let oldSize = ref.totalSize
            let newSize = 1 + vrrBaselinePayload
            block[ref.headerOffset] = (ref.tag << 5) | UInt8(vrrBaselinePayload)
            shiftLeft(in: &block, from: ref.headerOffset + oldSize, to: dbcEnd, by: oldSize - newSize)
            logger.info("stripVRRSignaling: truncated HDMI Forum VSDB payload from \(ref.length, privacy: .public) to \(vrrBaselinePayload, privacy: .public) bytes")
            return dbcEnd - (oldSize - newSize)
        }
    }

    /// Read-only: does `edid` currently carry a CTA-861.3 HDR Static Metadata Data
    /// Block in any extension block? Used to verify `stripHDRMetadata` actually
    /// took, by checking the display's live EDID after applying.
    static func hasHDRStaticMetadata(_ edid: Data) -> Bool {
        anyExtensionBlockContains(edid) { block, dbcEnd in
            dataBlocks(in: block, dbcStart: 4, dbcEnd: dbcEnd).contains { $0.tag == 7 && $0.extendedTag == 0x06 }
        }
    }

    /// Read-only: does `edid` currently carry an HDMI Forum VSDB payload longer
    /// than the pre-2.1 baseline (i.e. still advertising VRR/CNMVRR/ALLM/QMS)? Used
    /// to verify `stripVRRSignaling` actually took.
    static func hasExtendedVRRSignaling(_ edid: Data) -> Bool {
        anyExtensionBlockContains(edid) { block, dbcEnd in
            dataBlocks(in: block, dbcStart: 4, dbcEnd: dbcEnd).contains { ref in
                ref.tag == 3 && ref.length > vrrBaselinePayload
                    && block[ref.headerOffset + 1] == 0xD8
                    && block[ref.headerOffset + 2] == 0x5D
                    && block[ref.headerOffset + 3] == 0xC4
            }
        }
    }

    /// Read-only: does `edid` carry an HDMI Forum VSDB at all, regardless of its
    /// payload length? Distinct from `hasExtendedVRRSignaling` — a display can have
    /// one that's already at/below the baseline (nothing to strip, but the block
    /// exists) vs. having none at all (nothing could exist to strip).
    static func hasHDMIForumVSDB(_ edid: Data) -> Bool {
        anyExtensionBlockContains(edid) { block, dbcEnd in
            dataBlocks(in: block, dbcStart: 4, dbcEnd: dbcEnd).contains { ref in
                ref.tag == 3 && ref.length >= 3
                    && block[ref.headerOffset + 1] == 0xD8
                    && block[ref.headerOffset + 2] == 0x5D
                    && block[ref.headerOffset + 3] == 0xC4
            }
        }
    }

    // MARK: - Shared helpers

    /// True if any CTA-861 extension block in `edid` satisfies `matches`. Shared,
    /// read-only counterpart to `editExtensionBlocks` — same block/DBC-boundary
    /// logic, but never mutates anything.
    private static func anyExtensionBlockContains(
        _ edid: Data,
        _ matches: (_ block: [UInt8], _ dbcEnd: Int) -> Bool
    ) -> Bool {
        guard edid.count >= baseBlockSize * 2, edid.count % baseBlockSize == 0 else { return false }
        let bytes = [UInt8](edid)
        let blockCount = bytes.count / baseBlockSize
        for blockIndex in 1..<blockCount {
            let base = blockIndex * baseBlockSize
            guard bytes[base] == 0x02 else { continue }
            let block = Array(bytes[base ..< base + baseBlockSize])
            let dtdOffset = Int(block[2])
            let dbcEnd = dtdOffset == 0 ? 126 : dtdOffset
            guard dbcEnd > 4, dbcEnd <= 126 else { continue }
            if matches(block, dbcEnd) { return true }
        }
        return false
    }

    private static func requireValidBaseBlockChecksum(_ bytes: [UInt8]) throws {
        // Refuse to touch a base block whose checksum doesn't already validate —
        // better to fail loudly than silently "fix" a corrupt EDID.
        let sum = bytes[0 ..< baseBlockSize].reduce(0) { UInt8((Int($0) + Int($1)) % 256) }
        guard sum == 0 else {
            logger.error("requireValidBaseBlockChecksum: base block checksum is \(sum, privacy: .public), expected 0 — refusing to patch")
            throw EDIDPatcherError.badChecksum(offset: 0)
        }
    }

    private static func fixChecksum(of bytes: inout [UInt8], checksumOffset: Int) {
        let sum = bytes[0..<checksumOffset].reduce(0) { UInt8((Int($0) + Int($1)) % 256) }
        bytes[checksumOffset] = UInt8((256 - Int(sum)) % 256)
    }

    /// One data block within a CTA-861 Data Block Collection (DBC).
    private struct CTADataBlockRef {
        let tag: UInt8          // bits 7:5 of the header byte
        let extendedTag: UInt8? // payload[0] when tag == 7 ("use extended tag"), else nil
        let headerOffset: Int   // offset of the header byte within the 128-byte block
        let length: Int         // payload length, bits 4:0 of the header byte
        var totalSize: Int { 1 + length }
    }

    /// Parses the sequence of data blocks in `block[dbcStart..<dbcEnd]`. Stops early
    /// (rather than throwing) if a block's declared length would run past `dbcEnd` —
    /// callers treat "no matches found" as a safe no-op.
    private static func dataBlocks(in block: [UInt8], dbcStart: Int, dbcEnd: Int) -> [CTADataBlockRef] {
        var refs: [CTADataBlockRef] = []
        var offset = dbcStart
        while offset < dbcEnd {
            let header = block[offset]
            let tag = header >> 5
            let length = Int(header & 0x1F)
            guard offset + 1 + length <= dbcEnd else { break }
            let extendedTag: UInt8? = (tag == 7 && length >= 1) ? block[offset + 1] : nil
            refs.append(CTADataBlockRef(tag: tag, extendedTag: extendedTag, headerOffset: offset, length: length))
            offset += 1 + length
        }
        return refs
    }

    private static func shiftLeft(in block: inout [UInt8], from: Int, to end: Int, by amount: Int) {
        guard amount > 0, from <= end else { return }
        for i in from..<end { block[i - amount] = block[i] }
    }

    /// Applies `edit` to each CTA-861 extension block (tag 0x02) found in `edid`.
    /// `edit` receives the block's 128 bytes and the current end-of-DBC offset
    /// (exclusive of the Detailed Timing Descriptors that may follow), and returns
    /// the new end-of-DBC offset if it shrank the DBC, or nil for no change. Any
    /// Detailed Timing Descriptors that follow are shifted left by however much the
    /// DBC shrank (via the block's own DTD-offset byte, index 2), the freed space is
    /// zero-padded, and the block's own checksum is recomputed. Blocks `edit` leaves
    /// unchanged (returns nil) are passed through byte-for-byte.
    private static func editExtensionBlocks(
        _ edid: Data,
        _ edit: (_ block: inout [UInt8], _ dbcEnd: Int) -> Int?
    ) -> Data {
        guard edid.count >= baseBlockSize * 2, edid.count % baseBlockSize == 0 else {
            logger.info("editExtensionBlocks: EDID is \(edid.count, privacy: .public) bytes — no extension blocks present, nothing to edit")
            return edid
        }
        var bytes = [UInt8](edid)
        let blockCount = bytes.count / baseBlockSize
        let ctaBlockCount = (1..<blockCount).filter { bytes[$0 * baseBlockSize] == 0x02 }.count
        logger.info("editExtensionBlocks: \(blockCount - 1, privacy: .public) extension block(s) total, \(ctaBlockCount, privacy: .public) of them CTA-861 (tag 0x02)")

        for blockIndex in 1..<blockCount {
            let base = blockIndex * baseBlockSize
            guard bytes[base] == 0x02 else { continue } // not a CTA-861 extension block

            var block = Array(bytes[base ..< base + baseBlockSize])
            let dtdOffset = Int(block[2])
            // DTD offset 0 means "no DTDs present" — the DBC then runs up to the
            // reserved byte at 126 (127 is the checksum).
            let dbcEnd = dtdOffset == 0 ? 126 : dtdOffset
            guard dbcEnd > 4, dbcEnd <= 126 else {
                logger.error("editExtensionBlocks: block \(blockIndex, privacy: .public) has an out-of-range DTD offset (\(dtdOffset, privacy: .public)) — leaving it untouched")
                continue
            }

            guard let newDbcEnd = edit(&block, dbcEnd), newDbcEnd < dbcEnd else { continue }

            let shrink = dbcEnd - newDbcEnd
            for i in newDbcEnd..<dbcEnd { block[i] = 0 } // zero-pad freed space
            if dtdOffset != 0 { block[2] = UInt8(dtdOffset - shrink) }

            fixChecksum(of: &block, checksumOffset: baseBlockChecksumOffset)
            for i in 0..<baseBlockSize { bytes[base + i] = block[i] }
        }
        return Data(bytes)
    }
}
