import AppKit
import ServiceManagement

/// Removes Relaunch and undoes what it changed, so installing it again later
/// starts exactly like the first time (including the Launchpad import).
///
/// From the background menu, or from Terminal:
/// `/Applications/Relaunch.app/Contents/MacOS/Relaunch --uninstall`
enum Uninstaller {
    static func confirmAndRun() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Relaunch?"
        var removes = "This removes Relaunch, its layout and its settings"
        if SystemPinch.relaunchTurnedItOff { removes += ", and turns macOS's own pinch back on" }
        alert.informativeText = removes + """
            .

            You can install it again any time. It will start fresh and can bring back your \
            Launchpad layout again.
            """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.unhide(nil)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    static func run() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ahmedalghali.Relaunch"

        // Other copies (an older install, one opened from a disk image) would
        // otherwise keep running or re-register themselves.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app != NSRunningApplication.current {
            app.terminate()
        }

        if SystemPinch.relaunchTurnedItOff { SystemPinch.set(true, wait: true) }
        do { try SMAppService.mainApp.unregister() } catch {
            debugLog("uninstall: login item: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: LayoutStore.directory)
        UserDefaults.standard.removePersistentDomain(forName: bundleID)

        let app = Bundle.main.bundleURL
        do {
            try FileManager.default.trashItem(at: app, resultingItemURL: nil)
            debugLog("uninstall: moved \(app.path) to the Trash")
        } catch {
            // A read-only disk image, or a copy macOS runs from a temporary location.
            let alert = NSAlert()
            alert.messageText = "Relaunch is uninstalled"
            alert.informativeText = "Its settings are gone, but the app couldn't be moved to the Trash. "
                + "Drag Relaunch to the Trash to finish."
            NSApp.activate()
            alert.runModal()
        }
        NSApp.terminate(nil)
    }
}
