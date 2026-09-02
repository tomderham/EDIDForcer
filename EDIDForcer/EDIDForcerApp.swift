//
//  EDIDForcerApp.swift
//  EDIDForcer
//
//  Menu bar app that patches connected external displays' EDIDs via the DCP's
//  virtual-EDID mechanism — a software-only override that never touches the
//  monitor's own EEPROM. Each checkbox enables one deterministic patch (see
//  EDIDPatcher.swift), applied to every connected display. Settings persist
//  across launches and re-apply automatically.
//
//  Requires Developer ID or Personal Team code signing, and App Sandbox off.
//

import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.example.EDIDForcer", category: "App")

/// Per-feature, per-display status. `notNeeded` means the targeted EDID structure
/// doesn't exist at all (nothing to change) — distinct from `verified`, which means
/// the goal is met, whether because we changed it or it was already that way.
enum FeatureStatus {
    case disabled
    case notNeeded
    case verified
    case failed
}

/// One row of read-only UI status per connected external display.
struct MonitorInfo: Identifiable {
    let port: Int
    let persistentID: String
    var name: String
    var eightBitStatus: FeatureStatus = .disabled
    var hdrStripStatus: FeatureStatus = .disabled
    var vrrStripStatus: FeatureStatus = .disabled

    var id: String { persistentID }
}

@MainActor
final class AppState: ObservableObject {
    private enum DefaultsKey {
        static let forceEightBit = "forceEightBit"
        static let stripHDRMetadata = "stripHDRMetadata"
        static let stripVRRSignaling = "stripVRRSignaling"
    }
    private let defaults = UserDefaults.standard

    @Published var forceEightBit = false
    @Published var stripHDRMetadata = false
    @Published var stripVRRSignaling = false
    @Published var monitors: [MonitorInfo] = []

    /// Cached hardware EDIDs keyed by display identity (persistentID), never
    /// solely by port number, so swapping monitors on the same cable/port never
    /// applies one display's EDID to another.
    private var realEDIDByDisplay: [String: Data] = [:]
    private let detector = ScreenDetector()

    private var currentOptions: EDIDPatchOptions {
        EDIDPatchOptions(
            forceEightBpc: forceEightBit,
            stripHDRMetadata: stripHDRMetadata,
            stripVRRSignaling: stripVRRSignaling
        )
    }

    init() {
        forceEightBit = defaults.bool(forKey: DefaultsKey.forceEightBit)
        stripHDRMetadata = defaults.bool(forKey: DefaultsKey.stripHDRMetadata)
        stripVRRSignaling = defaults.bool(forKey: DefaultsKey.stripVRRSignaling)

        detector.onDisplayReconfigured = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                logger.info("onDisplayReconfigured: refreshing connected displays")
                // Always refresh diagnostics first so additions and removals
                // immediately reflect in the UI regardless of option states.
                self.refreshDiagnostics()

                guard !self.currentOptions.isNoop else { return }
                let discovered = DisplayDiagnostics.discoverExternalDisplays()
                for info in discovered {
                    self.apply(for: info)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.refreshDiagnostics()
                }
            }
        }
        detector.start()
        refreshDiagnostics()

        if !currentOptions.isNoop {
            reapplyAll()
        }
    }

    /// Re-enumerates connected external displays and re-verifies each enabled
    /// feature against their live state. Ports that disconnected are dropped.
    func refreshDiagnostics() {
        let discovered = DisplayDiagnostics.discoverExternalDisplays()
        let activeIDs = Set(discovered.map(\.persistentID))
        // Evict cached EDIDs for any displays that are no longer connected
        realEDIDByDisplay = realEDIDByDisplay.filter { activeIDs.contains($0.key) }

        monitors = discovered.map { info in
            var monitor = MonitorInfo(port: info.port, persistentID: info.persistentID, name: info.name)
            let sourceEDID = realEDIDByDisplay[info.persistentID]

            // 8-bit: verified via the DCP's actual negotiated color mode. Never
            // `.notNeeded` — the Video Input Definition byte always exists, so a
            // display that's already natively 8bpc counts as `.verified`.
            if forceEightBit {
                monitor.eightBitStatus = info.negotiatedDepth == 8 ? .verified : .failed
            }

            // HDR/VRR: no equivalent negotiated-state signal exists, so verify by
            // reading the live EDID back directly.
            if stripHDRMetadata || stripVRRSignaling {
                let liveEDID = try? DCPAVService.openExternal(port: info.port).copyEDID()

                if stripHDRMetadata {
                    let blockExists = sourceEDID.map(EDIDPatcher.hasHDRStaticMetadata) ?? true
                    monitor.hdrStripStatus = !blockExists ? .notNeeded
                        : (liveEDID.map { !EDIDPatcher.hasHDRStaticMetadata($0) } == true ? .verified : .failed)
                }

                // `.notNeeded` only if there's no HDMI Forum VSDB at all — distinct
                // from one that exists but is already at/below the baseline
                // (nothing to strip, but the entry exists, which is `.verified`).
                if stripVRRSignaling {
                    let vsdbExists = sourceEDID.map(EDIDPatcher.hasHDMIForumVSDB) ?? true
                    monitor.vrrStripStatus = !vsdbExists ? .notNeeded
                        : (liveEDID.map { !EDIDPatcher.hasExtendedVRRSignaling($0) } == true ? .verified : .failed)
                }
            }
            return monitor
        }
    }

    func setForceEightBit(_ enabled: Bool) {
        forceEightBit = enabled
        defaults.set(enabled, forKey: DefaultsKey.forceEightBit)
        reapplyAll()
    }
    func setStripHDRMetadata(_ enabled: Bool) {
        stripHDRMetadata = enabled
        defaults.set(enabled, forKey: DefaultsKey.stripHDRMetadata)
        reapplyAll()
    }
    func setStripVRRSignaling(_ enabled: Bool) {
        stripVRRSignaling = enabled
        defaults.set(enabled, forKey: DefaultsKey.stripVRRSignaling)
        reapplyAll()
    }

    /// Applies the current option set to every connected display.
    private func reapplyAll() {
        let discovered = DisplayDiagnostics.discoverExternalDisplays()
        for info in discovered {
            apply(for: info)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshDiagnostics()
        }
    }

    /// Validates whether the parsed EDID identity matches the connected framebuffer attributes.
    private func isIdentity(_ identity: EDIDIdentity?, matching display: ExternalDisplayInfo) -> Bool {
        guard let identity else { return false }
        if let mfg = display.manufacturerID, !mfg.isEmpty, identity.manufacturer != mfg {
            return false
        }
        if let pid = display.productID, pid != 0, Int(identity.productCode) != pid {
            return false
        }
        if let edidName = identity.productName, !edidName.isEmpty,
           !display.name.isEmpty, !display.name.starts(with: "External Display #") {
            if edidName != display.name {
                return false
            }
        }
        return true
    }

    /// Computes the EDID for `display` from the enabled options (identity if none are
    /// enabled) and writes it if it differs from what's currently live.
    private func apply(for display: ExternalDisplayInfo) {
        do {
            let service = try DCPAVService.openExternal(port: display.port)

            let sourceEDID: Data
            if let cached = realEDIDByDisplay[display.persistentID] {
                sourceEDID = cached
            } else {
                var currentEDID = try service.copyEDID()
                let currentIdentity = EDIDPatcher.identity(of: currentEDID)

                // Verify that currentEDID actually belongs to this display.
                // If a virtual EDID from a previously connected monitor is still
                // active in the DCP (e.g. from an unplugged display), reset to
                // hardware defaults first so we get the true hardware EDID.
                if !isIdentity(currentIdentity, matching: display) {
                    logger.warning("apply: active EDID on port \(display.port, privacy: .public) (\(currentIdentity?.description ?? "unknown", privacy: .public)) does not match display \"\(display.name, privacy: .public)\" (\(display.persistentID, privacy: .public)) — resetting port to hardware defaults")
                    try service.resetEDID()
                    currentEDID = try service.copyEDID()
                }

                sourceEDID = currentEDID
                realEDIDByDisplay[display.persistentID] = sourceEDID
                if let depth = EDIDPatcher.currentBitDepth(of: sourceEDID) {
                    logger.info("apply(port: \(display.port, privacy: .public), display: \"\(display.name, privacy: .public)\"): hardware EDID declares \(depth.description, privacy: .public)")
                }
            }

            let desired = try EDIDPatcher.patched(sourceEDID, options: currentOptions)

            // Skip the write if the display already presents what we'd apply —
            // safe to call `apply` unconditionally on every reconfiguration event,
            // including the one our own writes trigger.
            let liveEDID = try service.copyEDID()
            logger.info("apply(port: \(display.port, privacy: .public)): desired declares \(EDIDPatcher.currentBitDepth(of: desired)?.description ?? "?", privacy: .public), live declares \(EDIDPatcher.currentBitDepth(of: liveEDID)?.description ?? "?", privacy: .public)")
            guard liveEDID != desired else {
                logger.info("apply(port: \(display.port, privacy: .public)): live EDID already matches desired state, skipping")
                return
            }

            try service.applyVirtualEDID(desired)
            logger.info("Applied EDID successfully to port \(display.port, privacy: .public) for display \"\(display.name, privacy: .public)\" (isNoop=\(self.currentOptions.isNoop, privacy: .public))")
        } catch {
            logger.error("Apply failed for port \(display.port, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Fully releases the virtual-EDID override for every connected display via
    /// `DCPAVService.resetEDID()` — a heavier operation than `apply`'s identity
    /// write, but the one way to be certain no override is active at all.
    func resetAllToHardwareDefaults() {
        let ports = DCPAVService.discoverExternalPorts()
        for port in ports {
            do {
                let service = try DCPAVService.openExternal(port: port)
                try service.resetEDID()
                logger.info("resetAllToHardwareDefaults: released virtual EDID for port \(port, privacy: .public)")
            } catch {
                logger.error("resetAllToHardwareDefaults: failed for port \(port, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        realEDIDByDisplay.removeAll()
        forceEightBit = false
        stripHDRMetadata = false
        stripVRRSignaling = false
        defaults.set(false, forKey: DefaultsKey.forceEightBit)
        defaults.set(false, forKey: DefaultsKey.stripHDRMetadata)
        defaults.set(false, forKey: DefaultsKey.stripVRRSignaling)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshDiagnostics()
        }
    }
}

@main
struct EDIDForcerApp: App {
    @StateObject private var state = AppState()

    private var anyOptionEnabled: Bool {
        state.forceEightBit || state.stripHDRMetadata || state.stripVRRSignaling
    }

    var body: some Scene {
        MenuBarExtra("EDID Forcer", systemImage: anyOptionEnabled ? "square.stack.3d.up.slash" : "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Force 8-bit Color", isOn: Binding(
                    get: { state.forceEightBit }, set: { state.setForceEightBit($0) }
                ))
                Toggle("Strip HDR Metadata (force SDR)", isOn: Binding(
                    get: { state.stripHDRMetadata }, set: { state.setStripHDRMetadata($0) }
                ))
                Toggle("Strip VRR Signaling (HDMI only)", isOn: Binding(
                    get: { state.stripVRRSignaling }, set: { state.setStripVRRSignaling($0) }
                ))

                Divider()

                if state.monitors.isEmpty {
                    Text("No external display detected")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(state.monitors) { monitor in
                        statusLine(for: monitor)
                    }
                }

                Divider()

                Button("Refresh") { state.refreshDiagnostics() }
                Button("Reset All Displays to Hardware Defaults") { state.resetAllToHardwareDefaults() }

                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(12)
            .frame(minWidth: 320, alignment: .leading)
        }
        // .window style hosts live SwiftUI content; the default .menu style bridges
        // to NSMenu, which dims plain text regardless of .foregroundColor and
        // doesn't reliably live-update while open.
        .menuBarExtraStyle(.window)
    }

    /// e.g. "My Display:  8-bit ✓   HDR ✗   VRR –"
    private func statusLine(for monitor: MonitorInfo) -> Text {
        Text("\(monitor.name):  ").foregroundColor(.primary)
            + Text("8-bit ").foregroundColor(.primary) + indicator(monitor.eightBitStatus) + Text("   ").foregroundColor(.primary)
            + Text("HDR ").foregroundColor(.primary) + indicator(monitor.hdrStripStatus) + Text("   ").foregroundColor(.primary)
            + Text("VRR ").foregroundColor(.primary) + indicator(monitor.vrrStripStatus)
    }

    /// ✓ green = verified; ○ blue = not applicable (nothing to change); ✗ red =
    /// enabled but not confirmed; – = not enabled.
    private func indicator(_ status: FeatureStatus) -> Text {
        switch status {
        case .verified: return Text("✓").foregroundColor(.green)
        case .notNeeded: return Text("○").foregroundColor(.blue)
        case .failed: return Text("✗").foregroundColor(.red)
        case .disabled: return Text("–").foregroundColor(.secondary)
        }
    }
}
