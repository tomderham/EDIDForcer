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
    private var timer: Timer?
    var onDisplayReconfigured: (() -> Void)?

    private static let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        logger.info("reconfiguration callback fired for display \(displayID, privacy: .public), flags=\(flags.rawValue, privacy: .public)")
        guard let opaque = userInfo else {
            logger.error("reconfiguration callback: userInfo was nil, cannot recover ScreenDetector instance")
            return
        }
        let detector = Unmanaged<ScreenDetector>.fromOpaque(opaque).takeUnretainedValue()

        guard flags.contains(.addFlag) || flags.contains(.enabledFlag) else {
            logger.info("reconfiguration callback: ignored (no addFlag/enabledFlag)")
            return
        }
        // This callback fires for any display's reconfiguration, including the
        // built-in display — ignore those, we only care about external displays.
        guard CGDisplayIsBuiltin(displayID) == 0 else {
            logger.info("reconfiguration callback: ignored (display \(displayID, privacy: .public) is the built-in display)")
            return
        }

        // Debounce: several reconfiguration notifications typically fire in a
        // burst around a single physical connect event.
        logger.info("reconfiguration callback: external display add/enable — (re)starting 1.5s debounce timer")
        detector.timer?.invalidate()
        detector.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            logger.info("debounce timer fired — invoking onDisplayReconfigured")
            detector.onDisplayReconfigured?()
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
        timer?.invalidate()
        logger.info("stopped — removed CGDisplayReconfigurationCallback")
    }
}
