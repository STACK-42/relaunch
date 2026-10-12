import AppKit
import AVFoundation
import CoreImage
import ImageIO
import ServiceManagement

/// Launchpad showed a heavily blurred desktop picture rather than the windows
/// behind it. We blur a small thumbnail once per wallpaper and cache it;
/// at 800 px a 18 px sigma reads like a ~60 px blur on a full-size image.
enum Wallpaper {
    private static var cache: [String: NSImage] = [:]
    private static let context = CIContext()

    enum Source {
        case image(URL)
        case video(URL)

        var url: URL {
            switch self { case .image(let u), .video(let u): return u }
        }
    }

    static func blurred(for screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        guard let source = current(for: screen) else { completion(nil); return }
        let key = source.url.path
        if let hit = cache[key] { completion(hit); return }
        frame(of: source) { cg in
            let image = cg.flatMap(blur)
            DispatchQueue.main.async {
                if let image { cache[key] = image }
                completion(image)
            }
        }
    }

    /// `desktopImageURL` only knows classic still pictures. Since macOS 14 the
    /// real choice lives in the wallpaper agent's store, and for the default
    /// dynamic wallpapers (aerials) the API just returns DefaultDesktop.heic.
    static func current(for screen: NSScreen) -> Source? {
        if let choice = StoreChoice.mostRecentDesktop() {
            switch choice {
            case .image(let url) where FileManager.default.fileExists(atPath: url.path):
                return .image(url)
            case .aerial(let id):
                if let src = Aerials.source(for: id) { return src }
            default: break
            }
        }
        return NSWorkspace.shared.desktopImageURL(for: screen).map(Source.image)
    }

    private static func frame(of source: Source, completion: @escaping (CGImage?) -> Void) {
        switch source {
        case .image(let url):
            DispatchQueue.global(qos: .userInitiated).async {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { completion(nil); return }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 800,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                completion(CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary))
            }
        case .video(let url):
            // Aerial wallpapers loop, and the desktop rests on the first frame.
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.maximumSize = CGSize(width: 800, height: 800)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            gen.generateCGImageAsynchronously(for: .zero) { cg, _, _ in completion(cg) }
        }
    }

    private static func blur(_ cg: CGImage) -> NSImage? {
        let input = CIImage(cgImage: cg)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 18)
            .cropped(to: input.extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.15,
                kCIInputBrightnessKey: -0.04,
            ])
        guard let out = context.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: .zero)
    }
}

/// Reads ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist.
/// Each Space and display has a "Desktop" entry; the one used most recently
/// is the one on screen.
private enum StoreChoice {
    case image(URL)
    case aerial(String)

    static func mostRecentDesktop() -> StoreChoice? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }

        var best: (Date, [String: Any])?
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let desktop = dict["Desktop"] as? [String: Any],
                   let content = desktop["Content"] as? [String: Any],
                   let choice = (content["Choices"] as? [[String: Any]])?.first {
                    let used = desktop["LastUse"] as? Date ?? .distantPast
                    if best == nil || used > best!.0 { best = (used, choice) }
                }
                dict.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)

        guard let choice = best?.1, let provider = choice["Provider"] as? String,
              let configData = choice["Configuration"] as? Data,
              let config = try? PropertyListSerialization.propertyList(from: configData, format: nil) as? [String: Any]
        else { return nil }
        switch provider {
        case "com.apple.wallpaper.choice.image":
            guard let rel = (config["url"] as? [String: Any])?["relative"] as? String,
                  let url = URL(string: rel) else { return nil }
            return .image(url)
        case "com.apple.wallpaper.choice.aerials":
            return (config["assetID"] as? String).map(StoreChoice.aerial)
        default:
            return nil
        }
    }
}

/// Aerial wallpapers are videos the agent caches under
/// ~/Library/Application Support/com.apple.wallpaper/aerials/videos. The ID in
/// the store can name one video or a group (the default macOS wallpaper is a
/// group with light and dark, landscape and portrait variants).
private enum Aerials {
    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")

    static func source(for id: String) -> Wallpaper.Source? {
        for candidate in [id] + variants(of: id) {
            let video = dir.appendingPathComponent("videos/\(candidate).mov")
            if FileManager.default.fileExists(atPath: video.path) { return .video(video) }
        }
        let thumb = dir.appendingPathComponent("thumbnails/\(id).png")
        return FileManager.default.fileExists(atPath: thumb.path) ? .image(thumb) : nil
    }

    /// Variants of a group, best match for the current appearance first.
    private static func variants(of group: String) -> [String] {
        let manifests = [
            dir.appendingPathComponent("manifest/entries.json"),
            URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json"),
        ]
        guard let data = manifests.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return [] }

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let wanted = dark ? "dark" : "light"
        func score(_ a: [String: Any]) -> Int {
            let v = a["variant"] as? [String: String] ?? [:]
            return (v["appearance"] == wanted ? 2 : 0) + (v["orientation"] != "portrait" ? 1 : 0)
        }
        return assets
            .filter { ($0["subcategories"] as? [String])?.contains(group) == true }
            .sorted { score($0) > score($1) }
            .compactMap { $0["id"] as? String }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
            NSLog("Relaunch: login item change failed: \(error.localizedDescription)")
        }
    }
}
