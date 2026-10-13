import Foundation

/// A folder groups apps on the grid. Apps are stored flat; paging inside the
/// folder is derived from the folder panel's capacity.
struct Folder: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var apps: [String]
}

/// One slot on a page: either an app (by catalog id) or a folder.
enum Entry: Hashable, Identifiable {
    case app(String)
    case folder(Folder)

    var id: String {
        switch self {
        case .app(let a): return "app:" + a
        case .folder(let f): return "folder:" + f.id.uuidString
        }
    }

    var isApp: Bool {
        if case .app = self { return true }
        return false
    }
}

extension Entry: Codable {
    private enum Key: String, CodingKey { case app, folder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let a = try c.decodeIfPresent(String.self, forKey: .app) {
            self = .app(a)
        } else {
            self = .folder(try c.decode(Folder.self, forKey: .folder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .app(let a): try c.encode(a, forKey: .app)
        case .folder(let f): try c.encode(f, forKey: .folder)
        }
    }
}

/// Pure functions over `[[Entry]]` (pages of entries).
enum Layout {
    /// Cascades overflow onto following pages, iOS/Launchpad style.
    static func normalize(_ pages: [[Entry]], capacity: Int, removeEmpty: Bool) -> [[Entry]] {
        var out = pages
        var i = 0
        while i < out.count {
            if out[i].count > capacity {
                let overflow = Array(out[i][capacity...])
                out[i].removeSubrange(capacity...)
                if i + 1 == out.count { out.append([]) }
                out[i + 1].insert(contentsOf: overflow, at: 0)
            }
            i += 1
        }
        if removeEmpty { out.removeAll { $0.isEmpty } }
        return out.isEmpty ? [[]] : out
    }

    static func locate(_ id: String, in pages: [[Entry]]) -> (page: Int, index: Int)? {
        for (p, page) in pages.enumerated() {
            if let i = page.firstIndex(where: { $0.id == id }) { return (p, i) }
        }
        return nil
    }

    static func folder(_ id: UUID, in pages: [[Entry]]) -> Folder? {
        for page in pages {
            for e in page { if case .folder(let f) = e, f.id == id { return f } }
        }
        return nil
    }

    static func updateFolder(_ id: UUID, in pages: [[Entry]], _ change: (inout Folder) -> Void) -> [[Entry]] {
        pages.map { page in
            page.map { e in
                guard case .folder(var f) = e, f.id == id else { return e }
                change(&f)
                return .folder(f)
            }
        }
    }

    /// Drops unknown/duplicate apps, removes empty folders and appends newly
    /// installed apps to the end, the way Launchpad did.
    static func reconcile(_ pages: [[Entry]], catalog: [String: AppInfo], capacity: Int) -> [[Entry]] {
        var seen = Set<String>()
        var out: [[Entry]] = pages.map { page in
            page.compactMap { e -> Entry? in
                switch e {
                case .app(let a):
                    guard catalog[a] != nil, seen.insert(a).inserted else { return nil }
                    return e
                case .folder(var f):
                    f.apps = f.apps.filter { catalog[$0] != nil && seen.insert($0).inserted }
                    return f.apps.isEmpty ? nil : .folder(f)
                }
            }
        }
        let missing = catalog.values
            .filter { !seen.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !missing.isEmpty {
            if out.isEmpty { out = [[]] }
            out[out.count - 1].append(contentsOf: missing.map { .app($0.id) })
        }
        return normalize(out, capacity: capacity, removeEmpty: true)
    }

    /// Drops `app` onto the entry `target`: joins a folder or creates one.
    /// Returns the new pages and the id of the entry the app landed in.
    static func merge(app: String, into target: String, pages: [[Entry]], catalog: [String: AppInfo]) -> ([[Entry]], String) {
        var pages = pages
        guard let loc = locate(target, in: pages) else {
            if pages.isEmpty { pages = [[]] }
            pages[pages.count - 1].append(.app(app))
            return (pages, Entry.app(app).id)
        }
        let result: Entry
        switch pages[loc.page][loc.index] {
        case .folder(var f):
            f.apps.append(app)
            result = .folder(f)
        case .app(let other):
            result = .folder(Folder(name: suggestedName(for: [other, app], catalog: catalog), apps: [other, app]))
        }
        pages[loc.page][loc.index] = result
        return (pages, result.id)
    }

    /// After an app is dragged out of a folder, a folder left with one app
    /// turns back into that app; an empty folder disappears.
    static func dissolve(folder id: UUID, in pages: [[Entry]]) -> [[Entry]] {
        pages.map { page in
            page.compactMap { e -> Entry? in
                guard case .folder(let f) = e, f.id == id else { return e }
                if f.apps.isEmpty { return nil }
                if f.apps.count == 1 { return .app(f.apps[0]) }
                return e
            }
        }
    }

    static func pruneEmptyFolders(_ pages: [[Entry]]) -> [[Entry]] {
        pages.map { page in
            page.filter { if case .folder(let f) = $0 { return !f.apps.isEmpty }; return true }
        }
    }

    static func suggestedName(for apps: [String], catalog: [String: AppInfo]) -> String {
        let cats = apps.compactMap { catalog[$0]?.category }
        if let first = cats.first, cats.allSatisfy({ $0 == first }) { return first }
        return cats.first ?? "Untitled"
    }

    // MARK: Default layout (no saved layout and no Launchpad database)

    /// Apple's apps first in Launchpad's familiar order, remaining Apple apps
    /// alphabetically, Utilities in an "Other" folder, then everything else.
    static let appleOrder = [
        "com.apple.AppStore", "com.apple.Safari", "com.apple.mail", "com.apple.AddressBook",
        "com.apple.iCal", "com.apple.reminders", "com.apple.Notes", "com.apple.FaceTime",
        "com.apple.MobileSMS", "com.apple.Maps", "com.apple.findmy", "com.apple.PhotoBooth",
        "com.apple.Photos", "com.apple.Preview", "com.apple.Music", "com.apple.podcasts",
        "com.apple.TV", "com.apple.VoiceMemos", "com.apple.iBooksX", "com.apple.news",
        "com.apple.stocks", "com.apple.Home", "com.apple.weather", "com.apple.clock",
        "com.apple.freeform", "com.apple.journal", "com.apple.Passwords", "com.apple.games",
        "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
        "com.apple.iMovieApp", "com.apple.garageband10", "com.apple.shortcuts",
        "com.apple.Siri", "com.apple.systempreferences",
    ]

    static func defaultLayout(_ apps: [AppInfo], capacity: Int) -> [[Entry]] {
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var used = Set<String>()
        var entries: [Entry] = []

        for id in appleOrder {
            guard let a = byID[id], !a.isUtility else { continue }
            entries.append(.app(id)); used.insert(id)
        }
        for a in sorted where a.isApple && !a.isUtility && !used.contains(a.id) {
            entries.append(.app(a.id)); used.insert(a.id)
        }
        let utilities = sorted.filter { $0.isUtility && !used.contains($0.id) }
        if !utilities.isEmpty {
            entries.append(.folder(Folder(name: "Other", apps: utilities.map(\.id))))
            used.formUnion(utilities.map(\.id))
        }
        for a in sorted where !used.contains(a.id) { entries.append(.app(a.id)) }

        return normalize([entries], capacity: capacity, removeEmpty: true)
    }
}

/// Persists the layout as JSON in Application Support.
enum LayoutStore {
    private struct File: Codable {
        var version = 1
        var pages: [[Entry]]
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relaunch", isDirectory: true)
    }

    static var url: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("layout.json")
    }

    static func load() -> [[Entry]]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return file.pages
    }

    static func save(_ pages: [[Entry]]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(File(pages: pages)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
