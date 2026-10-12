import AppKit
import Observation

struct AppInfo: Identifiable, Hashable {
    /// Bundle identifier, or the path for bundles without one.
    let id: String
    let name: String
    let url: URL
    /// Human-readable App Store category, used to name new folders.
    let category: String?
    let isApple: Bool
    let isUtility: Bool
}

enum AppCatalog {
    static var roots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    /// Folders whose contents we watch for installs and removals.
    static var watchedFolders: [URL] {
        roots + [
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
    }

    static func scan() -> [AppInfo] {
        var urls: [URL] = []
        for root in roots { collect(root, depth: 2, into: &urls) }

        let own = Bundle.main.bundleIdentifier
        var seenPaths = Set<String>()
        var seenIDs = Set<String>()
        var apps: [AppInfo] = []
        for url in urls {
            let path = url.resolvingSymlinksInPath().path
            guard seenPaths.insert(path).inserted, let app = info(for: url), app.id != own else { continue }
            guard seenIDs.insert(app.id).inserted else { continue }
            apps.append(app)
        }
        return apps
    }

    private static func collect(_ dir: URL, depth: Int, into urls: inout [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys) else { return }
        // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink into the
        // Safari Cryptex that carries the hidden flag.
        for url in items where !url.lastPathComponent.hasPrefix(".") {
            if url.pathExtension == "app" {
                urls.append(url)
            } else if depth > 0,
                      let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isDirectory == true, v.isPackage != true {
                collect(url, depth: depth - 1, into: &urls)
            }
        }
    }

    private static func info(for url: URL) -> AppInfo? {
        let plist = Bundle(url: url)?.infoDictionary ?? [:]
        if (plist["LSBackgroundOnly"] as? Bool) == true { return nil }
        let bundleID = plist["CFBundleIdentifier"] as? String
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return AppInfo(
            id: bundleID ?? url.path,
            name: name,
            url: url.resolvingSymlinksInPath(), // no alias badge on Safari's icon
            category: (plist["LSApplicationCategoryType"] as? String).flatMap(categoryName),
            isApple: bundleID?.hasPrefix("com.apple.") == true,
            isUtility: url.deletingLastPathComponent().lastPathComponent == "Utilities"
        )
    }

    /// "public.app-category.developer-tools" -> "Developer Tools"
    static func categoryName(_ uti: String) -> String? {
        guard let raw = uti.split(separator: ".").last.map(String.init), !raw.isEmpty else { return nil }
        if raw.hasSuffix("games") { return "Games" }
        let special = [
            "graphics-design": "Graphics & Design",
            "healthcare-fitness": "Health & Fitness",
            "social-networking": "Social Networking",
            "photography": "Photo & Video",
            "video": "Photo & Video",
        ]
        if let s = special[raw] { return s }
        return raw.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

/// Icons rendered once to bitmaps in the background, so paging never
/// re-rasterizes icon art.
@Observable
final class IconCache {
    static let shared = IconCache()
    private(set) var images: [String: NSImage] = [:]

    func image(for app: AppInfo) -> NSImage {
        images[app.id] ?? NSWorkspace.shared.icon(forFile: app.url.path)
    }

    func prewarm(_ apps: [AppInfo], pixels: Int = 256) {
        let todo = apps.filter { images[$0.id] == nil }
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let lock = NSLock()
            var out: [String: NSImage] = [:]
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                let app = todo[i]
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                let side = CGFloat(pixels)
                var rect = CGRect(x: 0, y: 0, width: side, height: side)
                guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
                let image = NSImage(cgImage: cg, size: NSSize(width: side / 2, height: side / 2))
                lock.lock(); out[app.id] = image; lock.unlock()
            }
            DispatchQueue.main.async { self.images.merge(out) { $1 } }
        }
    }
}
