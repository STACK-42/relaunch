import AppKit
import Observation
import SwiftUI

enum Origin: Equatable {
    case main
    case folder(UUID)
    case search
}

enum PagerContext { case main, search, folder }

struct Slot: Equatable {
    var page: Int
    var index: Int
}

/// Page index plus the live finger offset. A separate observable object so
/// that per-frame offset changes only invalidate the view that applies them.
@Observable
final class Pager {
    var page = 0
    var offset: CGFloat = 0
}

struct DragState {
    var entry: Entry
    var origin: Origin
    var mode: Origin
    /// Cursor minus the dragged icon's center at pickup.
    var grab: CGSize
    /// Main pages with the dragged entry removed.
    var basePages: [[Entry]]
    /// Where the placeholder sits in `basePages`, if anywhere.
    var insert: Slot?
    var folderBase: [String] = []
    var folderInsert = 0
    var mergeTarget: String?
    var landing = false
    var landingScale: CGFloat = 1
}

private enum Candidate: Equatable {
    case none
    case reflow(Slot)
    case merge(String)
    case folder(Int)

    var isMerge: Bool { if case .merge = self { return true }; return false }
}

private struct ScrollTracker {
    var active = false
    var raw: CGFloat = 0
    var velocity: CGFloat = 0
    var lastTime: TimeInterval = 0
    var lastWheel: TimeInterval = 0
}

@Observable
final class RelaunchModel {
    var catalog: [String: AppInfo] = [:]
    var pages: [[Entry]] = [[]]
    var cols = 7
    var rows = 5
    var size = CGSize(width: 1440, height: 900)
    var topInset: CGFloat = 0

    let main = Pager()
    let search = Pager()
    let folderPager = Pager()

    private(set) var query = ""
    var selection: Int?
    var openFolderID: UUID?
    var drag: DragState?
    /// Kept apart from `drag` so cursor motion only redraws the floating icon.
    var dragLocation: CGPoint = .zero
    var appearance = 0.0
    var optionHeld = false
    var focusToken = 0
    var wallpaper: NSImage?
    private(set) var isHiding = false

    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored private var pending: Candidate = .none
    @ObservationIgnored private var pendingWork: DispatchWorkItem?
    @ObservationIgnored private var pendingAnchor: CGPoint = .zero
    @ObservationIgnored private var edgeWork: DispatchWorkItem?
    @ObservationIgnored private var edgeDir = 0
    @ObservationIgnored private var dragMonitor: Any?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var scroll = ScrollTracker()

    private let pageSpring = Animation.spring(response: 0.38, dampingFraction: 0.9)
    private let reflowSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)

    // MARK: Derived state

    var metrics: GridMetrics { GridMetrics(size: size, cols: cols, rows: rows, topInset: topInset) }
    var capacity: Int { cols * rows }
    var isSearching: Bool { !query.isEmpty }
    var isEditing: Bool { drag != nil || optionHeld }
    var results: [AppInfo] { Search.rank(query, in: Array(catalog.values)) }

    /// Pages as currently shown, including the drag placeholder.
    var displayPages: [[Entry]] {
        guard let d = drag, !d.landing, d.mode == .main else { return pages }
        var p = d.basePages
        if let s = d.insert {
            while p.count <= s.page { p.append([]) }
            p[s.page].insert(d.entry, at: min(s.index, p[s.page].count))
        }
        return Layout.normalize(p, capacity: capacity, removeEmpty: false)
    }

    var mainPageCount: Int {
        let n = displayPages.count
        // While dragging, offer one empty page past the end, like Launchpad.
        if let d = drag, !d.landing, d.mode == .main { return n + 1 }
        return n
    }

    var openFolder: Folder? {
        guard let id = openFolderID else { return nil }
        return Layout.folder(id, in: pages)
    }

    func folderApps(_ f: Folder) -> [String] {
        guard let d = drag, !d.landing, d.mode == .folder(f.id), case .app(let a) = d.entry else { return f.apps }
        var apps = d.folderBase
        apps.insert(a, at: min(d.folderInsert, apps.count))
        return apps
    }

    func folderMetrics(_ count: Int) -> FolderMetrics { FolderMetrics(grid: metrics, count: count) }

    func title(of entry: Entry) -> String {
        switch entry {
        case .app(let id): return catalog[id]?.name ?? id
        case .folder(let f): return f.name.isEmpty ? "Untitled" : f.name
        }
    }

    // MARK: Lifecycle

    func bootstrap() {
        let d = UserDefaults.standard
        if d.integer(forKey: "columns") > 0 { cols = min(max(d.integer(forKey: "columns"), 3), 12) }
        if d.integer(forKey: "rows") > 0 { rows = min(max(d.integer(forKey: "rows"), 2), 10) }

        let apps = AppCatalog.scan()
        catalog = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if let saved = LayoutStore.load() {
            pages = saved
        } else if let legacy = LegacyLaunchpad.importLayout() {
            pages = legacy
        } else {
            pages = Layout.defaultLayout(apps, capacity: capacity)
        }
        pages = Layout.reconcile(pages, catalog: catalog, capacity: capacity)
        LayoutStore.save(pages)
        IconCache.shared.prewarm(apps)
    }

    func applyCatalog(_ apps: [AppInfo]) {
        catalog = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard drag == nil else { return }
        withAnimation(reflowSpring) {
            pages = Layout.reconcile(pages, catalog: catalog, capacity: capacity)
        }
        clampPages()
        scheduleSave()
        IconCache.shared.prewarm(apps)
    }

    func importLegacyLayout() {
        guard let legacy = LegacyLaunchpad.importLayout() else { NSSound.beep(); return }
        withAnimation(reflowSpring) {
            pages = Layout.reconcile(legacy, catalog: catalog, capacity: capacity)
            main.page = 0
        }
        scheduleSave()
    }

    func resetLayout() {
        withAnimation(reflowSpring) {
            pages = Layout.defaultLayout(Array(catalog.values), capacity: capacity)
            main.page = 0
        }
        scheduleSave()
    }

    func prepareToShow() {
        isHiding = false
        query = ""
        selection = nil
        openFolderID = nil
        cancelDrag()
        search.page = 0; search.offset = 0
        folderPager.page = 0; folderPager.offset = 0
        main.offset = 0
        clampPages()
        appearance = 0
        focusToken &+= 1
    }

    func animateIn() {
        withAnimation(.easeOut(duration: 0.24)) { appearance = 1 }
    }

    func hide(launching: Bool = false) {
        guard !isHiding else { return }
        isHiding = true
        cancelDrag()
        withAnimation(.easeIn(duration: launching ? 0.22 : 0.16)) {
            appearance = 0
        } completion: { [weak self] in
            guard let self, self.isHiding else { return }
            self.onHide?()
        }
    }

    /// Closes without the fade, for when the screen is about to change under
    /// the grid anyway.
    func hideNow() {
        isHiding = true
        cancelDrag()
        appearance = 0
        onHide?()
    }

    private func clampPages() {
        main.page = min(main.page, max(0, pages.count - 1))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            LayoutStore.save(self.pages)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Actions

    func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        search.page = 0; search.offset = 0
        selection = q.isEmpty ? nil : 0
    }

    func activate(_ entry: Entry) {
        guard drag == nil, !optionHeld else { return }
        switch entry {
        case .app(let id): if let app = catalog[id] { launch(app) }
        case .folder(let f): openFolder(f.id)
        }
    }

    func launch(_ app: AppInfo) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        hide(launching: true)
    }

    func reveal(_ id: String) {
        guard let app = catalog[id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
        hide()
    }

    func openFolder(_ id: UUID) {
        folderPager.page = 0; folderPager.offset = 0
        selection = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { openFolderID = id }
    }

    func closeFolder() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { openFolderID = nil }
        scheduleSave()
    }

    func renameFolder(_ id: UUID, to name: String) {
        pages = Layout.updateFolder(id, in: pages) { $0.name = name }
        scheduleSave()
    }

    func removeFromFolder(_ app: String, folder id: UUID) {
        withAnimation(reflowSpring) {
            var p = Layout.updateFolder(id, in: pages) { $0.apps.removeAll { $0 == app } }
            p = Layout.dissolve(folder: id, in: p)
            p[p.count - 1].append(.app(app))
            pages = Layout.normalize(p, capacity: capacity, removeEmpty: true)
            if Layout.folder(id, in: pages) == nil { openFolderID = nil }
        }
        scheduleSave()
    }

    func ungroup(_ id: UUID) {
        guard let loc = Layout.locate("folder:" + id.uuidString, in: pages),
              case .folder(let f) = pages[loc.page][loc.index] else { return }
        withAnimation(reflowSpring) {
            var p = pages
            p[loc.page].replaceSubrange(loc.index...loc.index, with: f.apps.map { .app($0) })
            pages = Layout.normalize(p, capacity: capacity, removeEmpty: true)
            openFolderID = nil
        }
        scheduleSave()
    }

    func backgroundClicked() {
        if openFolderID != nil { closeFolder() } else { hide() }
    }

    // MARK: Keyboard

    /// Returns true when the key was consumed.
    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        switch e.keyCode {
        case 53: escape(); return true
        case 12 where cmd, 13 where cmd: hide(); return true // ⌘Q / ⌘W close, like Launchpad
        default: break
        }
        if openFolderID != nil || drag != nil { return false }
        switch e.keyCode {
        case 36, 76: activateSelection(); return true
        case 123: cmd ? flip(-1) : moveSelection(dx: -1); return true
        case 124: cmd ? flip(1) : moveSelection(dx: 1); return true
        case 125: moveSelection(dy: 1); return true
        case 126: moveSelection(dy: -1); return true
        case 48: moveSelection(dx: flags.contains(.shift) ? -1 : 1); return true
        default: return false
        }
    }

    private func escape() {
        if drag != nil { cancelDrag() }
        else if openFolderID != nil { closeFolder() }
        else if isSearching { setQuery("") }
        else { hide() }
    }

    private var activeListCount: (page: Int, pages: Int, onPage: Int) {
        if isSearching {
            let n = results.count, page = search.page
            return (page, max(1, (n + capacity - 1) / capacity), max(0, min(capacity, n - page * capacity)))
        }
        let p = displayPages
        return (main.page, p.count, p.indices.contains(main.page) ? p[main.page].count : 0)
    }

    private func moveSelection(dx: Int = 0, dy: Int = 0) {
        let ctx: PagerContext = isSearching ? .search : .main
        let (page, pageCount, n) = activeListCount
        guard n > 0 else { return }
        guard let s = selection else { selection = 0; return }
        if dy != 0 {
            let t = s + dy * cols
            if t >= 0 && t < n { selection = t }
            return
        }
        let t = s + dx
        if t < 0 {
            if page > 0 {
                setPage(page - 1, ctx: ctx)
                selection = activeListCount.onPage - 1
            }
        } else if t >= n {
            if page < pageCount - 1 { setPage(page + 1, ctx: ctx); selection = 0 }
        } else {
            selection = t
        }
    }

    private func activateSelection() {
        if isSearching {
            let r = results, i = search.page * capacity + (selection ?? 0)
            if r.indices.contains(i) { launch(r[i]) }
        } else if let s = selection, displayPages.indices.contains(main.page), displayPages[main.page].indices.contains(s) {
            activate(displayPages[main.page][s])
        }
    }

    private func flip(_ dir: Int) {
        let ctx: PagerContext = isSearching ? .search : .main
        setPage(pager(ctx).page + dir, ctx: ctx)
        selection = nil
    }

    // MARK: Paging

    var activeContext: PagerContext {
        if openFolderID != nil { return .folder }
        return isSearching ? .search : .main
    }

    func pager(_ ctx: PagerContext) -> Pager {
        switch ctx {
        case .main: return main
        case .search: return search
        case .folder: return folderPager
        }
    }

    func pageCount(_ ctx: PagerContext) -> Int {
        switch ctx {
        case .main: return mainPageCount
        case .search: return max(1, (results.count + capacity - 1) / capacity)
        case .folder: return openFolder.map { folderMetrics(folderApps($0).count).pages } ?? 1
        }
    }

    private func pageWidth(_ ctx: PagerContext) -> CGFloat {
        if ctx == .folder, let f = openFolder { return folderMetrics(folderApps(f).count).pageW }
        return size.width
    }

    func setPage(_ p: Int, ctx: PagerContext, animated: Bool = true) {
        let target = max(0, min(p, pageCount(ctx) - 1))
        let pg = pager(ctx)
        let apply = {
            pg.page = target
            pg.offset = 0
        }
        if animated { withAnimation(pageSpring, apply) } else { apply() }
        if ctx == .main, var d = drag, let ins = d.insert, ins.page != target {
            d.insert = nil
            withAnimation(reflowSpring) { drag = d }
        }
    }

    /// Trackpad: content follows the fingers with rubber-banding at the ends
    /// and snaps by distance or flick velocity. Mouse wheel: one page per notch.
    func handleScroll(_ e: NSEvent) {
        let ctx = activeContext
        let pg = pager(ctx)
        let count = pageCount(ctx)
        let w = pageWidth(ctx)

        guard e.hasPreciseScrollingDeltas else {
            let d = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : e.scrollingDeltaX
            guard abs(d) > 0.1, e.timestamp - scroll.lastWheel > 0.3 else { return }
            scroll.lastWheel = e.timestamp
            setPage(pg.page + (d < 0 ? 1 : -1), ctx: ctx)
            return
        }
        if !e.momentumPhase.isEmpty { return }

        if e.phase.contains(.began) {
            scroll = ScrollTracker(active: true, lastTime: e.timestamp, lastWheel: scroll.lastWheel)
        }
        guard scroll.active else { return }

        if e.phase.contains(.changed) {
            let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
            let d = abs(dx) >= abs(dy) ? dx : dy
            scroll.raw += d
            let dt = max(e.timestamp - scroll.lastTime, 1.0 / 240)
            scroll.velocity = scroll.velocity * 0.5 + (d / dt) * 0.5
            scroll.lastTime = e.timestamp
            var off = scroll.raw
            if (pg.page == 0 && off > 0) || (pg.page >= count - 1 && off < 0) {
                off = rubberBand(off, dimension: w)
            }
            pg.offset = off
        }

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            scroll.active = false
            var target = pg.page
            if abs(scroll.velocity) > 450 {
                target += scroll.velocity < 0 ? 1 : -1
            } else if abs(scroll.raw) > w * 0.15 {
                target += scroll.raw < 0 ? 1 : -1
            }
            setPage(target, ctx: ctx)
        }
    }

    private func rubberBand(_ x: CGFloat, dimension d: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        let r = (1 - 1 / (abs(x) * c / d + 1)) * d
        return x < 0 ? -r : r
    }

    // MARK: Drag and drop

    private var dragIconCenter: CGPoint {
        guard let d = drag else { return dragLocation }
        return CGPoint(x: dragLocation.x - d.grab.width, y: dragLocation.y - d.grab.height)
    }

    private func mainIconCenter(of id: String, in pages: [[Entry]]) -> CGPoint? {
        guard let loc = Layout.locate(id, in: pages) else { return nil }
        let m = metrics
        let c = m.iconCenter(loc.index)
        return CGPoint(x: c.x + CGFloat(loc.page - main.page) * m.W + main.offset, y: c.y)
    }

    private func folderIconCenter(index: Int, count: Int) -> CGPoint {
        let fm = folderMetrics(count)
        let c = fm.iconCenter(index % fm.capacity)
        return CGPoint(x: c.x + CGFloat(index / fm.capacity - folderPager.page) * fm.pageW + folderPager.offset, y: c.y)
    }

    /// Called by the cell's DragGesture. Only the first call matters: from
    /// then on an event monitor tracks the mouse, so the drag survives the
    /// cell moving to another page or out of a folder.
    func dragGesture(entry: Entry, origin: Origin, start: CGPoint, current: CGPoint) {
        guard drag == nil, !isHiding, origin != .search else { return }
        var state: DragState
        let center: CGPoint
        switch origin {
        case .main:
            guard let loc = Layout.locate(entry.id, in: pages),
                  let c = mainIconCenter(of: entry.id, in: pages) else { return }
            var base = pages
            base[loc.page].remove(at: loc.index)
            center = c
            state = DragState(entry: entry, origin: .main, mode: .main, grab: .zero,
                              basePages: base, insert: Slot(page: loc.page, index: loc.index))
        case .folder(let fid):
            guard case .app(let a) = entry, let f = openFolder, f.id == fid,
                  let idx = f.apps.firstIndex(of: a) else { return }
            var rest = f.apps
            rest.remove(at: idx)
            center = folderIconCenter(index: idx, count: f.apps.count)
            state = DragState(entry: entry, origin: origin, mode: origin, grab: .zero,
                              basePages: pages, folderBase: rest, folderInsert: idx)
        case .search:
            return
        }
        state.grab = CGSize(width: start.x - center.x, height: start.y - center.y)
        selection = nil
        pending = .none
        dragLocation = current
        drag = state
        installDragMonitor()
    }

    private func installDragMonitor() {
        removeDragMonitor()
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self, let win = e.window else { return e }
            let p = CGPoint(x: e.locationInWindow.x, y: win.frame.height - e.locationInWindow.y)
            if e.type == .leftMouseDragged { self.dragMoved(to: p) } else { self.endDrag() }
            return e
        }
    }

    private func removeDragMonitor() {
        if let m = dragMonitor { NSEvent.removeMonitor(m) }
        dragMonitor = nil
    }

    private func dragMoved(to p: CGPoint) {
        guard let d = drag, !d.landing else { return }
        dragLocation = p
        switch d.mode {
        case .main:
            evaluateMain()
        case .folder(let fid):
            let fm = folderMetrics(d.folderBase.count + 1)
            if fm.panelRect.insetBy(dx: -24, dy: -24).contains(p) {
                evaluateFolder(fm)
            } else {
                leaveFolder(fid)
                evaluateMain()
            }
        case .search:
            break
        }
    }

    private func evaluateMain() {
        guard let d = drag else { return }
        let m = metrics
        if dragLocation.x < m.edgeZone { scheduleEdgeFlip(-1); propose(.none); return }
        if dragLocation.x > m.W - m.edgeZone { scheduleEdgeFlip(1); propose(.none); return }
        cancelEdgeFlip()

        let p = dragIconCenter
        guard let slot = m.slot(at: p) else { propose(.none); return }
        let page = main.page
        let shown = displayPages
        let items = shown.indices.contains(page) ? shown[page] : []
        if slot < items.count {
            let e = items[slot]
            let c = m.iconCenter(slot)
            if e.id == d.entry.id {
                propose(.none)
            } else if d.entry.isApp, hypot(p.x - c.x, p.y - c.y) < m.iconSize * 0.3 {
                propose(.merge(e.id))
            } else {
                propose(.reflow(Slot(page: page, index: slot)))
            }
        } else {
            let baseCount = d.basePages.indices.contains(page) ? d.basePages[page].count : 0
            propose(.reflow(Slot(page: page, index: baseCount)))
        }
    }

    private func evaluateFolder(_ fm: FolderMetrics) {
        guard let d = drag, let slot = fm.slot(at: dragIconCenter) else { propose(.none); return }
        propose(.folder(min(folderPager.page * fm.capacity + slot, d.folderBase.count)))
    }

    /// Changes apply only once the pointer rests briefly, so sweeping across
    /// icons doesn't churn the grid and an icon stays put long enough to be
    /// dropped onto (creating a folder). Moving re-arms the timer.
    private func propose(_ c: Candidate) {
        let moved = hypot(dragLocation.x - pendingAnchor.x, dragLocation.y - pendingAnchor.y)
        guard c != pending || moved > 6 else { return }
        pendingAnchor = dragLocation
        let changed = c != pending
        pending = c
        if !changed {
            if case .none = c { return }
            rearm(c, delay: c.isMerge ? 0.2 : 0.16)
            return
        }
        pendingWork?.cancel()
        if var d = drag, let t = d.mergeTarget, c != .merge(t) {
            d.mergeTarget = nil
            withAnimation(.easeOut(duration: 0.15)) { drag = d }
        }
        if case .none = c { return }
        rearm(c, delay: c.isMerge ? 0.2 : 0.16)
    }

    private func rearm(_ c: Candidate, delay: Double) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commit(c) }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commit(_ c: Candidate) {
        guard pending == c, var d = drag, !d.landing else { return }
        switch c {
        case .reflow(let s): d.insert = s; d.mergeTarget = nil
        case .merge(let id): d.mergeTarget = id
        case .folder(let i): d.folderInsert = i
        case .none: return
        }
        withAnimation(reflowSpring) { drag = d }
    }

    private func scheduleEdgeFlip(_ dir: Int) {
        guard edgeDir != dir else { return }
        edgeDir = dir
        edgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag != nil else { return }
            let target = self.main.page + dir
            if target >= 0 && target < self.mainPageCount { self.setPage(target, ctx: .main) }
            self.edgeDir = 0
            self.evaluateMain() // re-arm while the cursor stays at the edge
        }
        edgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func cancelEdgeFlip() {
        edgeWork?.cancel()
        edgeDir = 0
    }

    private func leaveFolder(_ fid: UUID) {
        guard var d = drag else { return }
        d.basePages = Layout.updateFolder(fid, in: pages) { $0.apps = d.folderBase }
        d.mode = .main
        d.insert = nil
        d.mergeTarget = nil
        pending = .none
        pendingWork?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            drag = d
            openFolderID = nil
        }
    }

    private func endDrag() {
        removeDragMonitor()
        pendingWork?.cancel()
        cancelEdgeFlip()
        pending = .none
        guard var d = drag, !d.landing else { return }

        var result: [[Entry]]
        var landingID = d.entry.id
        var target: CGPoint?
        switch d.mode {
        case .folder(let fid):
            guard case .app(let a) = d.entry else { return }
            var apps = d.folderBase
            let i = min(d.folderInsert, apps.count)
            apps.insert(a, at: i)
            result = Layout.updateFolder(fid, in: pages) { $0.apps = apps }
            target = folderIconCenter(index: i, count: apps.count)
        case .main, .search:
            if let t = d.mergeTarget, case .app(let a) = d.entry {
                (result, landingID) = Layout.merge(app: a, into: t, pages: d.basePages, catalog: catalog)
                d.landingScale = 0.3
            } else if d.insert != nil {
                result = displayPages
            } else {
                result = d.basePages
                let p = min(main.page, result.count)
                if p == result.count { result.append([]) }
                result[p].append(d.entry)
            }
        }
        if case .folder(let ofid) = d.origin { result = Layout.dissolve(folder: ofid, in: result) }
        result = Layout.normalize(Layout.pruneEmptyFolders(result), capacity: capacity, removeEmpty: true)

        d.landing = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            pages = result
            clampPages()
            if d.mode == .main, let c = mainIconCenter(of: landingID, in: result) { target = c }
            drag = d
            if let t = target {
                dragLocation = CGPoint(x: t.x + d.grab.width, y: t.y + d.grab.height)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            if self?.drag?.landing == true { self?.drag = nil }
        }
        scheduleSave()
    }

    func cancelDrag() {
        removeDragMonitor()
        pendingWork?.cancel()
        cancelEdgeFlip()
        pending = .none
        if drag != nil { withAnimation(reflowSpring) { drag = nil } }
    }
}
