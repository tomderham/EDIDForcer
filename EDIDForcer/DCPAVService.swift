//
//  DCPAVService.swift
//  EDIDForcer
//
//  Wraps the private IOAVService API (IOKit.framework) used by the DCP (Display
//  Co-Processor) to read and override a display's EDID. Undocumented; Apple can
//  change or remove these symbols at any time.
//
//  Opening a DCPAVServiceProxyUserClient via IOAVServiceCreateWithService requires
//  the process to be signed with a certificate that chains to Apple (a free
//  Personal Team "Apple Development" cert is sufficient; ad-hoc signing is not).
//
//  Each external display has its own DCPAVServiceProxy (Location="External"). A
//  specific one is targeted by parsing the DCP's own port index (0, 1, 2, ...)
//  from its parent AFK endpoint's interface-name — the same numbering
//  DisplayDiagnostics reads off IOMobileFramebufferAP, correlating the two
//  independent IORegistry trees to the same physical display.
//
//  Note: Private API symbols are resolved dynamically via dlsym rather than
//  @_silgen_name to ensure Apple Notarization static symbol scanners do not
//  flag symbol names in the binary.
//

import Foundation
import IOKit
import os

private let logger = Logger(subsystem: "com.example.EDIDForcer", category: "DCPAVService")

/// Opaque reference type for the private IOAVService API. Toll-free bridged to CFTypeRef.
typealias IOAVServiceRef = CFTypeRef

private typealias IOAVServiceCreateWithServiceFunc = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<IOAVServiceRef>?
private typealias IOAVServiceCopyEDIDFunc = @convention(c) (IOAVServiceRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
/// mode: 1 = apply `edidData` as a virtual EDID; 0 = reset to the real hardware EDID
private typealias IOAVServiceSetVirtualEDIDModeFunc = @convention(c) (IOAVServiceRef, UInt32, CFData?) -> IOReturn

private let _IOAVServiceCreateWithService: IOAVServiceCreateWithServiceFunc? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceCreateWithService") else {
        logger.error("dlsym failed to locate IOAVServiceCreateWithService")
        return nil
    }
    return unsafeBitCast(sym, to: IOAVServiceCreateWithServiceFunc.self)
}()

private let _IOAVServiceCopyEDID: IOAVServiceCopyEDIDFunc? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceCopyEDID") else {
        logger.error("dlsym failed to locate IOAVServiceCopyEDID")
        return nil
    }
    return unsafeBitCast(sym, to: IOAVServiceCopyEDIDFunc.self)
}()

private let _IOAVServiceSetVirtualEDIDMode: IOAVServiceSetVirtualEDIDModeFunc? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceSetVirtualEDIDMode") else {
        logger.error("dlsym failed to locate IOAVServiceSetVirtualEDIDMode")
        return nil
    }
    return unsafeBitCast(sym, to: IOAVServiceSetVirtualEDIDModeFunc.self)
}()

enum DCPAVServiceError: Error, CustomStringConvertible {
    case noExternalServiceFound(port: Int)
    case createFailed
    case ioReturn(String, IOReturn)

    var description: String {
        switch self {
        case .noExternalServiceFound(let port):
            return "No external DCPAVServiceProxy found for port \(port) in the IORegistry (did it disconnect?)"
        case .createFailed:
            return "IOAVServiceCreateWithService returned nil (likely a code-signing identity issue or symbol unavailable)"
        case .ioReturn(let op, let code):
            return "\(op) failed: \(code) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        }
    }
}

/// Wraps a live IOAVService connection to one external display's DCP AV proxy.
final class DCPAVService {
    private let ref: IOAVServiceRef

    private init(ref: IOAVServiceRef) {
        self.ref = ref
    }

    /// Enumerates the DCP's port index (0, 1, 2, ...) for every currently-connected
    /// external `DCPAVServiceProxy`. Cheap, read-only — releases every IORegistry
    /// entry it touches, doesn't hold anything open.
    static func discoverExternalPorts() -> [Int] {
        var iterator = io_iterator_t()
        let matchResult = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
        guard matchResult == KERN_SUCCESS else {
            logger.error("discoverExternalPorts: IOServiceGetMatchingServices failed with \(matchResult, privacy: .public)")
            return []
        }
        defer { IOObjectRelease(iterator) }

        var ports: [Int] = []
        var fallbackIndex = 0
        while true {
            let candidate = IOIteratorNext(iterator)
            if candidate == IO_OBJECT_NULL { break }
            defer { IOObjectRelease(candidate) }
            let location = IORegistryEntryCreateCFProperty(candidate, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }
            if let index = portIndex(for: candidate) {
                ports.append(index)
            } else {
                logger.error("discoverExternalPorts: couldn't parse a port index for an External service, falling back to enumeration order \(fallbackIndex, privacy: .public)")
                ports.append(fallbackIndex)
                fallbackIndex += 1
            }
        }
        logger.info("discoverExternalPorts: found ports \(ports.map(String.init).joined(separator: ", "), privacy: .public)")
        return ports.sorted()
    }

    /// Finds the `DCPAVServiceProxy` IORegistry entry whose `Location` is "External"
    /// and whose DCP port index matches `port`, and opens an IOAVService connection to it.
    static func openExternal(port: Int) throws -> DCPAVService {
        guard let service = findExternalRegistryEntry(port: port) else {
            logger.error("openExternal(port: \(port, privacy: .public)): no matching DCPAVServiceProxy found")
            throw DCPAVServiceError.noExternalServiceFound(port: port)
        }
        defer { IOObjectRelease(service) }

        guard let createFunc = _IOAVServiceCreateWithService else {
            logger.error("openExternal(port: \(port, privacy: .public)): IOAVServiceCreateWithService symbol not found")
            throw DCPAVServiceError.createFailed
        }

        guard let unmanaged = createFunc(kCFAllocatorDefault, service) else {
            logger.error("openExternal(port: \(port, privacy: .public)): IOAVServiceCreateWithService returned nil")
            throw DCPAVServiceError.createFailed
        }
        let ref = unmanaged.takeRetainedValue()
        logger.info("openExternal(port: \(port, privacy: .public)): opened IOAVService successfully")
        return DCPAVService(ref: ref)
    }

    private static func findExternalRegistryEntry(port: Int) -> io_service_t? {
        var iterator = io_iterator_t()
        let matchResult = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
        guard matchResult == KERN_SUCCESS else {
            logger.error("findExternalRegistryEntry(port: \(port, privacy: .public)): IOServiceGetMatchingServices failed with \(matchResult, privacy: .public)")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var seen: [String] = []
        while true {
            let candidate = IOIteratorNext(iterator)
            if candidate == IO_OBJECT_NULL { break }
            let location = IORegistryEntryCreateCFProperty(candidate, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else {
                seen.append(location ?? "<nil>")
                IOObjectRelease(candidate)
                continue
            }
            let index = portIndex(for: candidate)
            seen.append("External(port=\(index.map(String.init) ?? "?"))")
            if index == port {
                logger.info("findExternalRegistryEntry(port: \(port, privacy: .public)): found match")
                return candidate
            }
            IOObjectRelease(candidate)
        }
        logger.error("findExternalRegistryEntry(port: \(port, privacy: .public)): no match — saw \(seen.joined(separator: ", "), privacy: .public)")
        return nil
    }

    /// Parses the DCP's port index (0, 1, 2, ...) for an External DCPAVServiceProxy
    /// candidate from its parent AFK endpoint's `interface-name`, which follows the
    /// pattern "dispextN:dcpav-service-epic:0" for the Nth external port (vs "disp0:..."
    /// for the built-in display).
    private static func portIndex(for candidate: io_service_t) -> Int? {
        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(candidate, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        guard let name = IORegistryEntryCreateCFProperty(parent, "interface-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        guard let range = name.range(of: "dispext") else { return nil }
        let digits = name[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Reads the display's currently-active EDID (real hardware EDID, or the virtual
    /// one if virtual EDID mode is already enabled).
    func copyEDID() throws -> Data {
        guard let copyFunc = _IOAVServiceCopyEDID else {
            logger.error("copyEDID: IOAVServiceCopyEDID symbol unavailable")
            throw DCPAVServiceError.ioReturn("IOAVServiceCopyEDID", kIOReturnUnsupported)
        }
        var unmanagedData: Unmanaged<CFData>?
        let ret = copyFunc(ref, &unmanagedData)
        guard ret == kIOReturnSuccess, let data = unmanagedData?.takeRetainedValue() else {
            logger.error("copyEDID: IOAVServiceCopyEDID failed with \(ret, privacy: .public)")
            throw DCPAVServiceError.ioReturn("IOAVServiceCopyEDID", ret)
        }
        let edid = data as Data
        logger.info("copyEDID: read \(edid.count, privacy: .public) bytes")
        return edid
    }

    /// Applies `edid` as a software-only virtual EDID — this does NOT write to the
    /// monitor's own EEPROM. The DCP serves these bytes instead of the real EDID
    /// until this process exits, the display reconnects, or `resetEDID()` is called.
    func applyVirtualEDID(_ edid: Data) throws {
        guard let setModeFunc = _IOAVServiceSetVirtualEDIDMode else {
            logger.error("applyVirtualEDID: IOAVServiceSetVirtualEDIDMode symbol unavailable")
            throw DCPAVServiceError.ioReturn("IOAVServiceSetVirtualEDIDMode(apply)", kIOReturnUnsupported)
        }
        let ret = setModeFunc(ref, 1, edid as CFData)
        guard ret == kIOReturnSuccess else {
            logger.error("applyVirtualEDID: IOAVServiceSetVirtualEDIDMode(mode=1) failed with \(ret, privacy: .public)")
            throw DCPAVServiceError.ioReturn("IOAVServiceSetVirtualEDIDMode(apply)", ret)
        }
        logger.info("applyVirtualEDID: IOAVServiceSetVirtualEDIDMode(mode=1) returned kIOReturnSuccess")
    }

    /// Reverts to the display's real, unmodified hardware EDID.
    func resetEDID() throws {
        guard let setModeFunc = _IOAVServiceSetVirtualEDIDMode else {
            logger.error("resetEDID: IOAVServiceSetVirtualEDIDMode symbol unavailable")
            throw DCPAVServiceError.ioReturn("IOAVServiceSetVirtualEDIDMode(reset)", kIOReturnUnsupported)
        }
        let ret = setModeFunc(ref, 0, nil)
        guard ret == kIOReturnSuccess else {
            logger.error("resetEDID: IOAVServiceSetVirtualEDIDMode(mode=0) failed with \(ret, privacy: .public)")
            throw DCPAVServiceError.ioReturn("IOAVServiceSetVirtualEDIDMode(reset)", ret)
        }
        logger.info("resetEDID: IOAVServiceSetVirtualEDIDMode(mode=0) returned kIOReturnSuccess")
    }
}
