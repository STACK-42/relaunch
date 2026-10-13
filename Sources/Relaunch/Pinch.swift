import AppKit
import IOKit

/// Launchpad's trackpad gesture: pinch thumb and three fingers together to
/// open, spread them to close.
///
/// The Dock consumes that gesture before any app sees it as an event, so this
/// reads raw touches from the private MultitouchSupport framework (the same
/// source gesture utilities use). It is loaded at runtime; if it is missing
/// or its layout changes, the pinch simply does nothing.
///
/// Turn off with `defaults write com.ahmedalghali.Relaunch pinch -bool false`.
final class PinchGesture {
    enum Kind { case pinchIn, spreadOut }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "pinch") as? Bool ?? true }

    private typealias DeviceCreateList = @convention(c) () -> Unmanaged<CFArray>
    private typealias ContactCallback = @convention(c) (
        Int32, UnsafeRawPointer?, Int32, Double, Int32) -> Int32
    private typealias SetCallback = @convention(c) (UnsafeRawPointer, ContactCallback) -> Void
    private typealias DeviceStart = @convention(c) (UnsafeRawPointer, Int32) -> Void
    private typealias DeviceCall = @convention(c) (UnsafeRawPointer) -> Void
    private typealias DeviceIsRunning = @convention(c) (UnsafeRawPointer) -> Bool

    private struct API {
        let createList: DeviceCreateList
        let register: SetCallback
        let unregister: SetCallback
        let start: DeviceStart
        let stop: DeviceCall
        let isRunning: DeviceIsRunning
    }

    /// Layout of MultitouchSupport's per-finger record: 96 bytes, normalised
    /// position (0…1 on each axis) at offset 32.
    private static let fingerStride = 96
    private static let positionOffset = 32

    private static var api: API?
    private static var handler: ((Kind) -> Void)?
    private static var devices: CFArray?
    private static var reconnectWork: DispatchWorkItem?
    private static var healthTimer: Timer?
    private static var ioPort: IONotificationPortRef?
    private static var ioIterators: [io_iterator_t] = []
    private static var mouseMonitors: [Any] = []
    private static var lastFrame: CFAbsoluteTime = 0
    private static var lastConnect: CFAbsoluteTime = 0

    // Per-gesture state, touched only on the framework's callback thread.
    private static var minSpread: Float = 0
    private static var maxSpread: Float = 0
    private static var fired = false
    private static var sawFrame = false

    /// Starts listening. Returns false when the framework isn't available.
    @discardableResult
    static func start(_ onGesture: @escaping (Kind) -> Void) -> Bool {
        guard handler == nil else { return true }
        guard let api = loadAPI() else {
            NSLog("Relaunch: MultitouchSupport unavailable; pinch disabled")
            return false
        }
        self.api = api
        handler = onGesture
        connect()
        watchForResets()
        return true
    }

    /// Re-subscribes after the trackpad driver resets. A reset (applying
    /// trackpad settings, waking from sleep, connecting a Magic Trackpad)
    /// silently ends the old subscription.
    static func reconnect(after delay: TimeInterval = 0.5) {
        guard handler != nil else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func loadAPI() -> API? {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let create = dlsym(lib, "MTDeviceCreateList"),
              let register = dlsym(lib, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(lib, "MTUnregisterContactFrameCallback"),
              let start = dlsym(lib, "MTDeviceStart"),
              let stop = dlsym(lib, "MTDeviceStop"),
              let isRunning = dlsym(lib, "MTDeviceIsRunning") else { return nil }
        return API(createList: unsafeBitCast(create, to: DeviceCreateList.self),
                   register: unsafeBitCast(register, to: SetCallback.self),
                   unregister: unsafeBitCast(unregister, to: SetCallback.self),
                   start: unsafeBitCast(start, to: DeviceStart.self),
                   stop: unsafeBitCast(stop, to: DeviceCall.self),
                   isRunning: unsafeBitCast(isRunning, to: DeviceIsRunning.self))
    }

    private static func forEachDevice(_ list: CFArray?, _ body: (UnsafeRawPointer) -> Void) {
        guard let list else { return }
        for i in 0..<CFArrayGetCount(list) {
            if let device = CFArrayGetValueAtIndex(list, i) { body(device) }
        }
    }

    private static func connect() {
        guard let api else { return }
        forEachDevice(devices) { device in
            api.unregister(device, frameCallback)
            api.stop(device)
        }
        let list = api.createList().takeRetainedValue()
        devices = list // keeps the device refs alive
        sawFrame = false
        lastConnect = CFAbsoluteTimeGetCurrent()
        forEachDevice(list) { device in
            api.register(device, frameCallback)
            api.start(device, 0)
        }
        debugLog("pinch: listening on \(CFArrayGetCount(list)) multitouch device(s)")
    }

    private static func watchForResets() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in reconnect(after: 1) }

        // A trackpad appearing or going away (driver reloads included).
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        ioPort = port
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("AppleMultitouchDevice"),
                { _, iterator in
                    PinchGesture.drain(iterator)
                    PinchGesture.reconnect()
                }, nil, &iterator)
            guard result == KERN_SUCCESS else { continue }
            drain(iterator) // arms the notification
            ioIterators.append(iterator)
        }

        // A reset can leave the old subscription looking alive but silent. The
        // cursor moving means a finger is on the trackpad, so frames should be
        // arriving; if they aren't, re-subscribe (at most every 10 s, since an
        // external mouse also moves the cursor).
        let checkAlive: (NSEvent) -> Void = { _ in
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastFrame > 2, now - lastConnect > 10 else { return }
            debugLog("pinch: cursor moving but no touches, reconnecting")
            reconnect(after: 0)
        }
        mouseMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: checkAlive) as Any)
        mouseMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { checkAlive($0); return $0 } as Any)

        // Belt and braces: a device that quietly stopped gets restarted.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            guard let api else { return }
            var stopped = false
            forEachDevice(devices) { if !api.isRunning($0) { stopped = true } }
            if stopped {
                debugLog("pinch: device stopped, reconnecting")
                reconnect(after: 0)
            }
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            IOObjectRelease(obj)
            obj = IOIteratorNext(iterator)
        }
    }

    private static let frameCallback: ContactCallback = { _, data, count, _, _ in
        PinchGesture.frame(data, Int(count))
        return 0
    }

    /// Thumb and three fingers = four or more touches. The gesture is the
    /// average distance of the touches from their centre shrinking (pinch) or
    /// growing (spread) by a clear margin from its widest or narrowest point,
    /// firing once per gesture.
    private static func frame(_ data: UnsafeRawPointer?, _ count: Int) {
        lastFrame = CFAbsoluteTimeGetCurrent()
        if !sawFrame {
            sawFrame = true
            DispatchQueue.main.async { debugLog("pinch: receiving touches") }
        }
        guard count >= 4, let data else {
            minSpread = 0
            maxSpread = 0
            fired = false
            return
        }
        var xs = [Float](), ys = [Float]()
        for i in 0..<count {
            let p = data + i * fingerStride + positionOffset
            xs.append(p.loadUnaligned(as: Float.self))
            ys.append(p.loadUnaligned(fromByteOffset: 4, as: Float.self))
        }
        let cx = xs.reduce(0, +) / Float(count), cy = ys.reduce(0, +) / Float(count)
        var spread: Float = 0
        for i in 0..<count { spread += hypotf(xs[i] - cx, ys[i] - cy) }
        spread /= Float(count)

        if maxSpread == 0 { minSpread = spread; maxSpread = spread; return }
        minSpread = min(minSpread, spread)
        maxSpread = max(maxSpread, spread)
        guard !fired, minSpread > 0.01 else { return }
        let kind: Kind? = spread < maxSpread * 0.6 ? .pinchIn
            : spread > minSpread * 1.5 ? .spreadOut : nil
        guard let kind else { return }
        fired = true
        DispatchQueue.main.async { handler?(kind) }
    }
}

/// macOS's own thumb-and-three-finger pinch, which opens Apple's Apps view
/// (and spreads to Show Desktop). Its "Apps" switch in System Settings doesn't
/// turn off on current macOS, so Relaunch can turn off the trackpad setting
/// underneath it. That also turns off the spread, which Relaunch then
/// performs itself (see `showDesktop`).
enum SystemPinch {
    private static let domains = ["com.apple.AppleMultitouchTrackpad",
                                  "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    private static let keys = ["TrackpadFourFingerPinchGesture", "TrackpadFiveFingerPinchGesture"]
    private static let hostKeys = ["com.apple.trackpad.fourFingerPinchSwipeGesture",
                                   "com.apple.trackpad.fiveFingerPinchSwipeGesture"]

    private static let turnedOffKey = "turnedOffSystemPinch"

    static var isEnabled: Bool {
        let v = CFPreferencesCopyAppValue(keys[0] as CFString, domains[0] as CFString) as? Int
        return (v ?? 2) != 0
    }

    /// Whether macOS's pinch is off because Relaunch turned it off, so an
    /// uninstall only restores what Relaunch changed. Copies from before this
    /// was recorded only offered while the pinch was on, so having asked and
    /// finding it off means Relaunch did it.
    static var relaunchTurnedItOff: Bool {
        guard !isEnabled else { return false }
        return UserDefaults.standard.object(forKey: turnedOffKey) as? Bool
            ?? UserDefaults.standard.bool(forKey: "askedSystemPinch")
    }

    /// `wait` blocks until the trackpad has the new setting (used when quitting).
    static func set(_ on: Bool, wait: Bool = false) {
        UserDefaults.standard.set(!on, forKey: turnedOffKey)
        let value = (on ? 2 : 0) as CFNumber
        for domain in domains {
            for key in keys { CFPreferencesSetAppValue(key as CFString, value, domain as CFString) }
            CFPreferencesAppSynchronize(domain as CFString)
        }
        for key in hostKeys {
            CFPreferencesSetValue(key as CFString, value, kCFPreferencesAnyApplication,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)

        // Pushes the saved trackpad settings to the driver, as System Settings does.
        let task = Process()
        task.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        task.arguments = ["-u"]
        task.terminationHandler = { _ in DispatchQueue.main.async { PinchGesture.reconnect(after: 1) } }
        do {
            try task.run()
            if wait { task.waitUntilExit() }
        } catch {
            NSLog("Relaunch: could not apply trackpad settings: \(error)")
        }
        debugLog("system pinch -> \(on)")
    }

    /// Show Desktop, as the system spread gesture would.
    static func showDesktop() {
        typealias Send = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
        guard let lib = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let sym = dlsym(lib, "CoreDockSendNotification") else { return }
        unsafeBitCast(sym, to: Send.self)("com.apple.showdesktop.awake" as CFString, nil)
    }

    /// Asks once, on the first launch that isn't at login.
    static func offerTakeover() {
        let asked = "askedSystemPinch"
        guard isEnabled, !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)
        let alert = NSAlert()
        alert.messageText = "Use the trackpad pinch for Relaunch?"
        alert.informativeText = """
            Pinching thumb and three fingers also opens macOS's Apps view, and its switch in \
            System Settings doesn't turn off. Relaunch can turn off macOS's pinch so the gesture \
            opens only Relaunch. Apple's Apps view stays one ⌘Space away, and spreading still \
            shows the desktop.

            You can change this later by right-clicking the Relaunch background.
            """
        alert.addButton(withTitle: "Use Pinch for Relaunch")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            set(false)
        } else {
            UserDefaults.standard.set(false, forKey: turnedOffKey)
        }
    }
}
