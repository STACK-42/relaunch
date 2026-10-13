import Foundation

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
    private typealias RegisterCallback = @convention(c) (UnsafeRawPointer, ContactCallback) -> Void
    private typealias DeviceStart = @convention(c) (UnsafeRawPointer, Int32) -> Void

    /// Layout of MultitouchSupport's per-finger record: 96 bytes, normalised
    /// position (0…1 on each axis) at offset 32.
    private static let fingerStride = 96
    private static let positionOffset = 32

    private static var handler: ((Kind) -> Void)?
    private static var devices: CFArray?

    // Per-gesture state, touched only on the framework's callback thread.
    private static var startSpread: Float = 0
    private static var fired = false

    /// Starts listening. Returns false when the framework isn't available.
    @discardableResult
    static func start(_ onGesture: @escaping (Kind) -> Void) -> Bool {
        guard handler == nil else { return true }
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSym = dlsym(lib, "MTDeviceCreateList"),
              let registerSym = dlsym(lib, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(lib, "MTDeviceStart") else {
            NSLog("Relaunch: MultitouchSupport unavailable; pinch disabled")
            return false
        }
        let createList = unsafeBitCast(createSym, to: DeviceCreateList.self)
        let register = unsafeBitCast(registerSym, to: RegisterCallback.self)
        let startDevice = unsafeBitCast(startSym, to: DeviceStart.self)

        handler = onGesture
        let list = createList().takeRetainedValue()
        devices = list // keep the device refs alive
        for i in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, i) else { continue }
            register(device, frameCallback)
            startDevice(device, 0)
        }
        debugLog("pinch: listening on \(CFArrayGetCount(list)) multitouch device(s)")
        return true
    }

    private static let frameCallback: ContactCallback = { _, data, count, _, _ in
        PinchGesture.frame(data, Int(count))
        return 0
    }

    /// Thumb and three fingers = four or more touches. The gesture is the
    /// average distance of the touches from their centre shrinking (pinch)
    /// or growing (spread) by a clear margin, firing once per gesture.
    private static func frame(_ data: UnsafeRawPointer?, _ count: Int) {
        guard count >= 4, let data else {
            startSpread = 0
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

        if startSpread == 0 { startSpread = spread; return }
        guard !fired, startSpread > 0.02 else { return }
        let ratio = spread / startSpread
        let kind: Kind? = ratio < 0.6 ? .pinchIn : ratio > 1.5 ? .spreadOut : nil
        guard let kind else { return }
        fired = true
        DispatchQueue.main.async { handler?(kind) }
    }
}
