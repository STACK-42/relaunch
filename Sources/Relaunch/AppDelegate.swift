import AppKit
import SwiftUI

/// Full-screen, borderless, above the Dock and menu bar, on every Space.
/// A non-activating panel, so it can take the keyboard even when macOS
/// refuses to activate the app (cooperative activation, macOS 14+) while
/// another app such as VS Code or Chrome is frontmost.
final class RelaunchWindow: NSPanel {
    init(model: RelaunchModel) {
        super.init(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: RootView(model: model))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = RelaunchModel()
    private var window: RelaunchWindow!
    private var hotKey: HotKey?
    private var monitors: [Any] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var rescanWork: DispatchWorkItem?
    private var cornerArmed = true

    private var isShown: Bool { window.isVisible && !model.isHiding }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--uninstall") { return Uninstaller.run() }
        let launchedAtLogin = Self.launchedAsLoginItem || CommandLine.arguments.contains("--background")
            || Updater.consumeRelaunchFlag()
        NSApp.mainMenu = Self.makeMenu()

        let t0 = CFAbsoluteTimeGetCurrent()
        model.bootstrap()
        NSLog("Relaunch: catalog of \(model.catalog.count) apps ready in %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)

        window = RelaunchWindow(model: model)
        model.onHide = { [weak self] in
            debugLog("orderOut")
            self?.window.orderOut(nil)
            NSApp.hide(nil) // hands focus back to the previous app
            Updater.shared.installIfPending()
        }

        LoginItem.sync()
        installMonitors()
        installHotKey()
        installHotCorner()
        installPinch()
        watchApplicationFolders()
        watchWallpaper()
        Updater.shared.isShown = { [weak self] in self?.isShown ?? false }
        Updater.shared.start()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isShown else { return }
            debugLog("resigned active -> hide")
            self.model.hide()
        }
        // The panel can be key while the app is inactive, so also hide when
        // another window or app takes the keyboard.
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, self.isShown else { return }
            debugLog("resigned key -> hide")
            self.model.hide()
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Wallpaper.prewarm()
            guard let self, self.isShown, let screen = self.window.screen else { return }
            self.place(on: screen)
        }
        // Each Space can have its own wallpaper.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            Wallpaper.prewarm()
        }

        if !launchedAtLogin {
            if PinchGesture.enabled { SystemPinch.offerTakeover() }
            show()
        }
    }

    /// Clicking the Dock icon (or opening the app again) toggles, exactly like
    /// Launchpad's Dock tile.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return false
    }

    func toggle() {
        isShown ? model.hide() : show()
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        place(on: screen)
        model.prepareToShow()

        // The background must be final before the fade starts. Normally it was
        // rendered ahead of time; on a cold start, wait briefly for it, and if
        // it's still late, cross-fade it in rather than swapping it.
        var started = false
        let start = { [weak self] in
            guard let self, !started else { return }
            started = true
            self.model.animateIn()
            debugLog("animate in, wallpaper ready=\(self.model.wallpaper != nil) key=\(self.window.isKeyWindow)")
        }
        if let ready = Wallpaper.cached(for: screen) {
            model.wallpaper = ready
            DispatchQueue.main.async(execute: start)
        } else {
            Wallpaper.blurred(for: screen) { [weak self] image in
                guard let self else { return }
                if started {
                    withAnimation(.easeInOut(duration: 0.35)) { self.model.wallpaper = image }
                } else {
                    self.model.wallpaper = image
                    DispatchQueue.main.async(execute: start)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
        }

        NSApp.unhide(nil)
        // Activation jumps to a Space holding one of the app's windows. The
        // grid is on every Space, but AppKit's text-input helpers for the
        // search field (TUINSWindow, SPRoundedWindow) stay on the Space they
        // were created on, and the grid isn't always registered on this Space
        // by the time activation looks. Put the helpers on every Space too, so
        // there is nowhere else to jump to.
        for w in NSApp.windows where w !== window {
            w.collectionBehavior.insert(.canJoinAllSpaces)
        }
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        debugLog("show on \(screen.frame) visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive)")
    }

    private func place(on screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
        model.size = screen.frame.size
        model.topInset = screen.safeAreaInsets.top
    }

    // MARK: Input

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isShown else { return e }
            return self.model.handleKey(e) ? nil : e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.isShown else { return e }
            self.model.handleScroll(e)
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let held = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            if self?.model.optionHeld != held { self?.model.optionHeld = held }
            return e
        } as Any)
    }

    /// None by default: Launchpad had none, and ⌥Space belongs to apps such as
    /// Claude and ChatGPT. Opt in with
    /// `defaults write com.ahmedalghali.Relaunch hotkey "ctrl+opt+l"`.
    private func installHotKey() {
        guard let spec = UserDefaults.standard.string(forKey: "hotkey"), !spec.isEmpty else { return }
        hotKey = HotKey(spec: spec) { [weak self] in self?.toggle() }
        if hotKey == nil { NSLog("Relaunch: could not register hotkey '\(spec)'") }
    }

    /// Pinch in opens, spread out closes, like Launchpad's gesture.
    private func installPinch() {
        guard PinchGesture.enabled else { return }
        PinchGesture.start { [weak self] kind in
            guard let self else { return }
            debugLog("pinch: \(kind)")
            switch kind {
            case .pinchIn: if !self.isShown { self.show() }
            case .spreadOut:
                if self.isShown { self.model.hide() }
                // macOS's spread is off along with its pinch; stand in for it.
                else if !SystemPinch.isEnabled { SystemPinch.showDesktop() }
            }
        }
    }

    /// Optional: `defaults write com.ahmedalghali.Relaunch hotCorner bottomLeft`
    /// (topLeft, topRight, bottomLeft, bottomRight). Mouse-move monitors need
    /// no special permission.
    private func installHotCorner() {
        guard let corner = UserDefaults.standard.string(forKey: "hotCorner"), !corner.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.checkCorner(corner) }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { handler($0); return $0 } as Any)
    }

    private func checkCorner(_ corner: String) {
        let p = NSEvent.mouseLocation
        guard let f = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) })?.frame else { return }
        let left = p.x <= f.minX + 1, right = p.x >= f.maxX - 2
        let bottom = p.y <= f.minY + 1, top = p.y >= f.maxY - 2
        let hit: Bool
        switch corner {
        case "topLeft": hit = top && left
        case "topRight": hit = top && right
        case "bottomLeft": hit = bottom && left
        case "bottomRight": hit = bottom && right
        default: hit = false
        }
        if hit && cornerArmed { cornerArmed = false; toggle() }
        if !hit { cornerArmed = true }
    }

    // MARK: Wallpaper

    /// Re-renders the blurred wallpaper when the user picks a new one, so the
    /// next open never has to wait for it.
    private func watchWallpaper() {
        Wallpaper.prewarm()
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store")
        let fd = open(store.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        var pending: DispatchWorkItem?
        src.setEventHandler {
            pending?.cancel()
            let work = DispatchWorkItem { Wallpaper.prewarm() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers.append(src)
    }

    // MARK: Installs and removals

    private func watchApplicationFolders() {
        for url in AppCatalog.watchedFolders {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleRescan() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    private func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let apps = AppCatalog.scan()
                DispatchQueue.main.async { self?.model.applyCatalog(apps) }
            }
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: Misc

    private static var launchedAsLoginItem: Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return ev.eventID == kAEOpenApplication
            && ev.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Invisible (the window covers the menu bar) but needed so text editing
    /// shortcuts work in the search field.
    private static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Relaunch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

/// Set RELAUNCH_DEBUG=1 to trace show/hide on stderr.
func debugLog(_ s: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["RELAUNCH_DEBUG"] != nil else { return }
    FileHandle.standardError.write(("Relaunch: " + s() + "\n").data(using: .utf8)!)
}
