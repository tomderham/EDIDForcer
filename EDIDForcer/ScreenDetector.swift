//
//  ScreenDetector.swift
//  EDIDForcer
//
//  Notifies when an external display connects or is reconfigured, since a virtual
//  EDID is runtime state that does not survive a real cable disconnect/reconnect.
//  Filters out the built-in display's own reconfigurations (sleep/wake, lid
//  open/close, etc.), which fire the same callback with the same flags but have
//  nothing to do with the external monitor.
//

import Cocoa
import os

private let logger = Logger(subsystem: "com.example.EDIDForcer", category: "ScreenDetector")

final class ScreenDetector {
    private var debounceWorkItem: DispatchWorkItem?
    var onDisplayReconfigured: (() -> Void)?

    private static let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        logger.info("reconfiguration callback fired for display \(displayID, privacy: .public), flags=\(flags.rawValue, privacy: .public)")
        guard let opaque = userInfo else {
            logger.error("reconfiguration callback: userInfo was nil, cannot recover ScreenDetector instance")
            return
        }
        let detector = Unmanaged<ScreenDetector>.fromOpaque(opaque).takeUnretainedValue()

        // Ignore intermediate notifications while reconfiguration is beginning.
        // Wait until it completes (when beginConfigurationFlag is clear).
        guard !flags.contains(.beginConfigurationFlag) else {
            logger.info("reconfiguration callback: ignored (beginConfigurationFlag set)")
            return
        }

        // Filter out purely internal display events unless the desktop shape changed
        // (which often happens when an external display is attached or detached).
        let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        if isBuiltin && !flags.contains(.addFlag) && !flags.contains(.removeFlag) && !flags.contains(.desktopShapeChangedFlag) {
            logger.info("reconfiguration callback: ignored (built-in display minor change)")
            return
        }

        // Debounce on main queue: several reconfiguration notifications typically
        // fire in a burst around a single physical connect/disconnect event.
        logger.info("reconfiguration callback: display change (\(flags.rawValue, privacy: .public)) — scheduling 1.5s debounce on main queue")
        DispatchQueue.main.async {
            detector.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak detector] in
                logger.info("debounce timer fired — invoking onDisplayReconfigured")
                detector?.onDisplayReconfigured?()
            }
            detector.debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        }
    }

    func start() {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(Self.callback, userData)
        logger.info("started — registered CGDisplayReconfigurationCallback")
    }

    func stop() {
        let userData = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(Self.callback, userData)
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        logger.info("stopped — removed CGDisplayReconfigurationCallback")
    }
}
