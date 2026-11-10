import AppKit
import os

/// Key and extra-mouse-button events while another app is in front (for push to talk and the
/// toggle shortcuts). Events for our own windows come through the app's local monitor instead.
///
/// Uses a listen-only event tap on the login session, which sees input whatever app is in front
/// (full-screen games included) and never swallows it. macOS only allows that with Accessibility or
/// Input Monitoring access; `refresh()` is called every couple of seconds, so the tap appears as
/// soon as access is granted, without restarting the app. Until then a plain global monitor still
/// delivers mouse buttons, which need no access.
@MainActor
final class GlobalInput {
    var onEvent: ((NSEvent) -> Void)?
    /// Whether macOS lets us see key presses made in other apps.
    private(set) var hasKeyboardAccess = false

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var lastReported: String?
    private static let logger = Logger(subsystem: "TS3Kit", category: "input")

    func refresh() {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        hasKeyboardAccess = accessibility || inputMonitoring

        if tap == nil && hasKeyboardAccess { startTap() }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }

        if tap != nil, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        } else if tap == nil && mouseMonitor == nil {
            // Without the tap: mouse buttons always arrive here, keys only with Accessibility.
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.onEvent?(event) }
            }
        }

        let state = "accessibility=\(accessibility) inputMonitoring=\(inputMonitoring) tap=\(tap != nil)"
        if state != lastReported {
            lastReported = state
            Self.logger.notice("global input: \(state, privacy: .public)")
        }
    }

    private func startTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let input = Unmanaged<GlobalInput>.fromOpaque(context).takeUnretainedValue()
            // The tap's source is on the main run loop, so this is the main thread.
            MainActor.assumeIsolated { input.received(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
    }

    private func received(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS switches a tap off when it was slow to respond; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Our own windows' events are handled (and can be swallowed) by the local monitor.
        guard !NSApp.isActive, let converted = NSEvent(cgEvent: event) else { return }
        onEvent?(converted)
    }
}
