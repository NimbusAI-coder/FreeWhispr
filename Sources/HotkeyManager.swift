import AppKit
import Foundation

/// Watches the Fn key via a CGEvent tap.
///
/// This is the one piece that genuinely requires Accessibility: macOS has no
/// other way to observe a modifier key globally. The tap is `listenOnly`, so
/// FreeWhispr can see events but cannot alter or swallow them.
///
/// Gestures:
///   - Hold Fn                 -> record while held, stop on release
///   - Press Cmd while holding -> latch on; Fn release keeps recording
///   - Fn tap while latched    -> stop
final class HotkeyManager {

    var onHoldStart: (() -> Void)?
    var onHoldStop: (() -> Void)?
    var onLatch: (() -> Void)?
    var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var fnDown = false
    private var isLatched = false
    private var recording = false

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts for Accessibility if not yet granted. Returns current state.
    @discardableResult
    func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard tap == nil, isTrusted else { return }

        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    /// Called by the controller so the manager's view of state stays honest
    /// when recording ends for reasons other than a key press.
    func noteRecordingEnded() {
        recording = false
        isLatched = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The tap is disabled by the system if it ever times out. Re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }

        let flags = event.flags

        if type == .keyDown {
            // Escape cancels an in-flight dictation without pasting.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 53, recording {
                recording = false
                isLatched = false
                dispatch { self.onCancel?() }
            }
            return
        }

        guard type == .flagsChanged else { return }

        let fnNowDown = flags.contains(.maskSecondaryFn)
        let cmdDown = flags.contains(.maskCommand)

        // Cmd pressed during a hold latches the session on.
        if fnDown, recording, !isLatched, cmdDown {
            isLatched = true
            dispatch { self.onLatch?() }
        }

        if fnNowDown, !fnDown {
            fnDown = true
            if isLatched, recording {
                // Tapping Fn while latched ends the session.
                recording = false
                isLatched = false
                dispatch { self.onHoldStop?() }
            } else if !recording {
                recording = true
                dispatch { self.onHoldStart?() }
            }
        } else if !fnNowDown, fnDown {
            fnDown = false
            if recording, !isLatched {
                recording = false
                dispatch { self.onHoldStop?() }
            }
        }
    }

    private func dispatch(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
