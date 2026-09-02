//
//  DisplayDiagnostics.swift
//  EDIDForcer
//
//  Read-only inspection of the DCP framebuffer's negotiated color mode for each
//  external display, so the UI can show what's actually in effect rather than
//  just what was requested. Also the source of each display's DCP port index and
//  human-readable name, used to correlate with DCPAVService and list multiple
//  external displays independently. The port index is parsed from
//  IOMobileFramebufferAP's "IONameMatched" (e.g. "dispext0,t604x"); the name comes
//  from "DisplayAttributes.ProductAttributes.ProductName", from the display's EDID.
//

import Foundation
import IOKit
import os

private let logger = Logger(subsystem: "com.example.EDIDForcer", category: "DisplayDiagnostics")

struct ColorModeInfo: CustomStringConvertible {
    let depth: Int
    let pixelEncoding: Int
    let score: Int

    var description: String { "\(depth)bpc (encoding \(pixelEncoding), score \(score))" }
}

struct ExternalDisplayInfo {
    let port: Int
    let name: String
    let edidUUID: String?
    let manufacturerID: String?
    let productID: Int?
    let alphanumericSerial: String?
    /// The active (IsPreferred) timing's ColorMode entries, sorted by score descending.
    /// Only the first entry reflects what's actually negotiated right now — the rest
    /// are lower-priority fallback options the DCP didn't pick.
    let colorModes: [ColorModeInfo]

    var negotiatedDepth: Int? { colorModes.first?.depth }

    /// A stable identity key for this display, so EDID caching and verification
    /// never confuse one monitor with another on the same port.
    var persistentID: String {
        if let uuid = edidUUID, !uuid.isEmpty {
            return uuid
        }
        let mfg = manufacturerID ?? "UNKNOWN"
        let prod = productID.map(String.init) ?? "0"
        let serial = alphanumericSerial ?? ""
        if !serial.isEmpty {
            return "\(mfg):\(prod):\(serial)"
        }
        return "\(mfg):\(prod):\(name)"
    }
}

struct DisplayDiagnostics {
    /// Enumerates every currently-connected external display with an active timing,
    /// each with its DCP port index, a human-readable name, and its negotiated color
    /// modes (highest-scored first).
    static func discoverExternalDisplays() -> [ExternalDisplayInfo] {
        var iterator = io_iterator_t()
        // IOMobileFramebufferAP is the common ancestor of the concrete framebuffer
        // classes across chip generations.
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferAP"), &iterator)
        guard result == KERN_SUCCESS else {
            logger.error("discoverExternalDisplays: IOServiceGetMatchingServices failed with \(result, privacy: .public)")
            return []
        }
        defer { IOObjectRelease(iterator) }

        var displays: [ExternalDisplayInfo] = []
        var fallbackIndex = 0
        var seen = 0
        while true {
            let candidate = IOIteratorNext(iterator)
            if candidate == IO_OBJECT_NULL { break }
            defer { IOObjectRelease(candidate) }
            seen += 1

            let isExternal = (IORegistryEntryCreateCFProperty(candidate, "external" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) ?? false
            let modes = colorModes(for: candidate)
            guard isExternal, !modes.isEmpty else { continue }

            let port = portIndex(for: candidate) ?? {
                let index = fallbackIndex
                fallbackIndex += 1
                logger.error("discoverExternalDisplays: couldn't parse a port index, falling back to enumeration order \(index, privacy: .public)")
                return index
            }()

            let edidUUID = IORegistryEntryCreateCFProperty(candidate, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            let attributes = IORegistryEntryCreateCFProperty(candidate, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary
            let product = attributes?["ProductAttributes"] as? NSDictionary
            let manufacturerID = product?["ManufacturerID"] as? String
            let productID = product?["ProductID"] as? Int
            let alphanumericSerial = product?["AlphanumericSerialNumber"] as? String

            let rawName = product?["ProductName"] as? String
            let cleanName = rawName?.trimmingCharacters(in: .whitespaces)
            let name = (cleanName != nil && !cleanName!.isEmpty) ? cleanName! : "External Display #\(port)"

            logger.info("discoverExternalDisplays: port \(port, privacy: .public) = \"\(name, privacy: .public)\" (uuid=\(edidUUID ?? "nil", privacy: .public)) — \(modes.map(\.description).joined(separator: " | "), privacy: .public)")
            displays.append(ExternalDisplayInfo(
                port: port,
                name: name,
                edidUUID: edidUUID,
                manufacturerID: manufacturerID,
                productID: productID,
                alphanumericSerial: alphanumericSerial,
                colorModes: modes
            ))
        }
        logger.info("discoverExternalDisplays: found \(displays.count, privacy: .public) external display(s) among \(seen, privacy: .public) candidate(s)")
        return displays.sorted { $0.port < $1.port }
    }

    /// The active (IsPreferred) timing's ColorMode entries for one framebuffer service,
    /// sorted by score descending. Empty if there's no active timing to read.
    private static func colorModes(for service: io_service_t) -> [ColorModeInfo] {
        guard let timingElements = IORegistryEntryCreateCFProperty(
            service, "TimingElements" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSArray else { return [] }

        guard let active = timingElements.first(where: {
            ($0 as? NSDictionary)?["IsPreferred"] as? Bool == true
        }) as? NSDictionary else { return [] }

        guard let colorModes = active["ColorModes"] as? NSArray else { return [] }

        let infos: [ColorModeInfo] = colorModes.compactMap { entry in
            guard let dict = entry as? NSDictionary,
                  let depth = dict["Depth"] as? Int,
                  let encoding = dict["PixelEncoding"] as? Int else { return nil }
            let score = dict["Score"] as? Int ?? -1
            return ColorModeInfo(depth: depth, pixelEncoding: encoding, score: score)
        }
        return infos.sorted { $0.score > $1.score }
    }

    /// The display's own product name, straight from its EDID's product descriptor.
    /// Falls back to nil (caller supplies a generic name) for displays whose EDID
    /// doesn't carry one.
    private static func productName(for service: io_service_t) -> String? {
        guard let attributes = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary,
              let product = attributes["ProductAttributes"] as? NSDictionary,
              let name = product["ProductName"] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    /// Parses the DCP's port index (0, 1, 2, ...) from this framebuffer's own
    /// IONameMatched property, e.g. "dispext0,t604x" -> 0.
    private static func portIndex(for service: io_service_t) -> Int? {
        guard let nameMatched = IORegistryEntryCreateCFProperty(service, "IONameMatched" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        guard let range = nameMatched.range(of: "dispext") else { return nil }
        let digits = nameMatched[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
