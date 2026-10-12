import Foundation
import SQLite3

/// Reads the layout Apple's Launchpad left behind (macOS 10.7 – 15) so the
/// user's pages and folders come back exactly as they were.
///
/// The database lives in `$(getconf DARWIN_USER_DIR)/com.apple.dock.launchpad/db/db`.
/// Item tree (`items` table): type 1 = root, 3 = page, 2 = folder, 4 = app,
/// 5 = app still downloading. Folders hold their own type-3 pages.
/// See docs/RESEARCH.md for how this was established.
enum LegacyLaunchpad {
    private enum ItemType: Int64 { case root = 1, folder = 2, page = 3, app = 4 }

    static var databaseURL: URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 else { return nil }
        let url = URL(fileURLWithPath: String(cString: buf))
            .appendingPathComponent("com.apple.dock.launchpad/db/db")
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    static func importLayout() -> [[Entry]]? {
        guard let url = databaseURL else { return nil }
        // immutable=1: never touch Apple's file (no locks, no WAL/SHM writes).
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = url.path
        comps.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = comps.string else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let root = scalar(db, "SELECT value FROM dbinfo WHERE key='launchpad_root'") ?? ItemType.root.rawValue

        var pages: [[Entry]] = []
        for page in children(db, of: root) where page.type == ItemType.page.rawValue {
            var entries: [Entry] = []
            for item in children(db, of: page.rowid) {
                switch item.type {
                case ItemType.app.rawValue:
                    if let b = item.bundleID { entries.append(.app(b)) }
                case ItemType.folder.rawValue:
                    var apps: [String] = []
                    for sub in children(db, of: item.rowid) where sub.type == ItemType.page.rawValue {
                        apps += children(db, of: sub.rowid)
                            .filter { $0.type == ItemType.app.rawValue }
                            .compactMap(\.bundleID)
                    }
                    if !apps.isEmpty {
                        entries.append(.folder(Folder(name: item.title ?? "Untitled", apps: apps)))
                    }
                default:
                    break
                }
            }
            pages.append(entries)
        }
        return pages.contains { !$0.isEmpty } ? pages : nil
    }

    private struct Row {
        let rowid: Int64
        let type: Int64
        let bundleID: String?
        let title: String?
    }

    private static func children(_ db: OpaquePointer?, of parent: Int64) -> [Row] {
        let sql = """
            SELECT i.rowid, i.type, a.bundleid, g.title FROM items i
            LEFT JOIN apps a ON a.item_id = i.rowid
            LEFT JOIN groups g ON g.item_id = i.rowid
            WHERE i.parent_id = ? ORDER BY i.ordering
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, parent)
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Row(
                rowid: sqlite3_column_int64(stmt, 0),
                type: sqlite3_column_int64(stmt, 1),
                bundleID: text(stmt, 2),
                title: text(stmt, 3)
            ))
        }
        return rows
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let s = text(stmt, 0) else { return nil }
        return Int64(s)
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: p)
    }
}
