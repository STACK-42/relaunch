import AppKit
import Sparkle

/// Sparkle checks the appcast on GitHub Releases once a day and downloads new
/// versions in the background. Sparkle normally installs on quit, but
/// Relaunch almost never quits, so the update goes in as soon as the launcher
/// is closed and the app comes back in the background.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private static let relaunchingKey = "relaunchingAfterUpdate"

    /// Whether the launcher is on screen; installing then would yank it away.
    var isShown: () -> Bool = { false }

    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?

    /// True once, on the first launch after Sparkle relaunched the app.
    static func consumeRelaunchFlag() -> Bool {
        let flag = UserDefaults.standard.bool(forKey: relaunchingKey)
        if flag { UserDefaults.standard.removeObject(forKey: relaunchingKey) }
        return flag
    }

    /// Only an installed copy updates itself, so a build in build/ is never
    /// replaced by the latest release.
    func start() {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var canCheck: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Called when the launcher closes.
    func installIfPending() {
        guard let install = pendingInstall, !isShown() else { return }
        pendingInstall = nil
        install()
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        debugLog("update \(item.displayVersionString) downloaded")
        pendingInstall = immediateInstallHandler
        installIfPending()
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        UserDefaults.standard.set(true, forKey: Self.relaunchingKey)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Relaunch has no Dock or menu bar presence to steal focus from, so a
    /// scheduled update that needs the user shows its window without
    /// interrupting what they're doing.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
