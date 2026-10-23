import AppKit
import IOKit.hid

/// The Caps Lock light of every connected keyboard, set by Klavko to show the layout's language
/// (lit for one chosen language). With Caps Lock itself on, the light shows that, as usual.
@MainActor
final class CapsLockLight {
    private var manager: IOHIDManager?
    /// The state last sent; nil: not known (send again).
    private var shown: Bool?

    var isRunning: Bool { manager != nil }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        // A keyboard plugged in later gets the light too.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let light = Unmanaged<CapsLockLight>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { light.shown = nil } }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess {
            Log.engine.error("Caps Lock light: keyboards not opened (\(status))")
        }
        self.manager = manager
        shown = nil
    }

    /// Gives the light back to Caps Lock.
    func stop() {
        guard let manager else { return }
        send(Self.capsLockOn, to: manager)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        shown = nil
    }

    /// Lights it when `lit` (or when Caps Lock is on). `force`: send even if unchanged — macOS sets the light
    /// itself when Caps Lock is pressed or the Mac wakes.
    func show(_ lit: Bool, force: Bool = false) {
        guard let manager else { return }
        let on = lit || Self.capsLockOn
        guard force || shown != on else { return }
        send(on, to: manager)
        shown = on
    }

    static var capsLockOn: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    private func send(_ on: Bool, to manager: IOHIDManager) {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        let match = [kIOHIDElementUsagePageKey: kHIDPage_LEDs, kIOHIDElementUsageKey: kHIDUsage_LED_CapsLock] as CFDictionary
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, match, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
            else { continue }
            for element in elements {
                let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, mach_absolute_time(), on ? 1 : 0)
                let status = IOHIDDeviceSetValue(device, element, value)
                if status != kIOReturnSuccess { Log.engine.error("Caps Lock light not set (\(status))") }
            }
        }
    }
}
