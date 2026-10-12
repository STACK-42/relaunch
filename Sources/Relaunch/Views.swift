import AppKit
import SwiftUI

struct RootView: View {
    let model: RelaunchModel

    var body: some View {
        let m = model.metrics
        let folder = model.openFolder
        ZStack(alignment: .topLeading) {
            BackgroundView(model: model)
                .opacity(model.appearance)

            ZStack(alignment: .topLeading) {
                Group {
                    if model.isSearching { SearchGrid(model: model) } else { MainGrid(model: model) }
                }
                .blur(radius: folder == nil ? 0 : 16)
                .opacity(folder == nil ? 1 : 0.55)

                SearchBar(model: model)
                    .position(x: m.W / 2, y: m.searchY)
                    .opacity(folder == nil ? 1 : 0)

                if folder == nil {
                    let ctx: PagerContext = model.isSearching ? .search : .main
                    PageDots(count: model.pageCount(ctx), pager: model.pager(ctx)) {
                        model.setPage($0, ctx: ctx)
                    }
                    .position(x: m.W / 2, y: m.dotsY)
                }

                if let f = folder {
                    FolderOverlay(model: model, folder: f)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                DragOverlay(model: model)
            }
            .scaleEffect(1 + 0.08 * (1 - model.appearance))
            .opacity(model.appearance)
        }
        .frame(width: m.W, height: m.H)
    }
}

// MARK: Background

struct BackgroundView: View {
    let model: RelaunchModel

    var body: some View {
        ZStack {
            VisualEffectBackground()
            if let img = model.wallpaper {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: model.size.width, height: model.size.height)
                    .clipped()
            }
            Color.black.opacity(0.2)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.backgroundClicked() }
        .contextMenu { BackgroundMenu(model: model) }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct BackgroundMenu: View {
    let model: RelaunchModel

    var body: some View {
        Toggle("Open at Login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
        Divider()
        if LegacyLaunchpad.databaseURL != nil {
            Button("Restore Launchpad Layout") { model.importLegacyLayout() }
        }
        Button("Reset to Default Layout") { model.resetLayout() }
        Divider()
        Button("Quit Relaunch") { NSApp.terminate(nil) }
    }
}

// MARK: Grids

/// Applies the pager translation in its own view so per-frame offset
/// changes don't re-evaluate the grid.
struct PagedOffset: ViewModifier {
    let pager: Pager
    let width: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: -CGFloat(pager.page) * width + pager.offset)
    }
}

private struct Placement: Identifiable {
    let entry: Entry
    let page: Int
    let slot: Int
    var id: String { entry.id }
}

struct MainGrid: View {
    let model: RelaunchModel

    var body: some View {
        let m = model.metrics
        let current = model.main.page
        let selection = model.selection
        let editing = model.isEditing
        let placements = model.displayPages.enumerated().flatMap { p, page in
            page.enumerated().map { Placement(entry: $1, page: p, slot: $0) }
        }
        ZStack(alignment: .topLeading) {
            ForEach(placements) { pl in
                let c = m.cellCenter(pl.slot)
                EntryCell(model: model, entry: pl.entry, origin: .main, metrics: m,
                          selected: pl.page == current && pl.slot == selection,
                          jiggle: editing && pl.page == current)
                    .position(x: CGFloat(pl.page) * m.W + c.x, y: c.y)
            }
        }
        .frame(width: m.W, height: m.H, alignment: .topLeading)
        .modifier(PagedOffset(pager: model.main, width: m.W))
    }
}

struct SearchGrid: View {
    let model: RelaunchModel

    var body: some View {
        let m = model.metrics
        let results = model.results
        let current = model.search.page
        let selection = model.selection
        ZStack(alignment: .topLeading) {
            ForEach(Array(results.enumerated()), id: \.element.id) { i, app in
                let page = i / m.capacity, slot = i % m.capacity
                let c = m.cellCenter(slot)
                EntryCell(model: model, entry: .app(app.id), origin: .search, metrics: m,
                          selected: page == current && slot == selection)
                    .position(x: CGFloat(page) * m.W + c.x, y: c.y)
            }
            if results.isEmpty {
                Text("No Results")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .position(x: m.W / 2, y: m.H / 2)
            }
        }
        .frame(width: m.W, height: m.H, alignment: .topLeading)
        .modifier(PagedOffset(pager: model.search, width: m.W))
    }
}

// MARK: Cells

struct EntryCell: View {
    let model: RelaunchModel
    let entry: Entry
    let origin: Origin
    let metrics: GridMetrics
    var selected = false
    var jiggle = false

    var body: some View {
        let m = metrics
        let hidden = model.drag?.entry.id == entry.id
        let isTarget = model.drag?.mergeTarget == entry.id
        VStack(spacing: m.spacing) {
            EntryIcon(model: model, entry: entry, size: m.iconSize)
                .background {
                    if selected || isTarget {
                        RoundedRectangle(cornerRadius: m.iconSize * 0.27, style: .continuous)
                            .fill(.white.opacity(isTarget ? 0.3 : 0.2))
                            .frame(width: m.iconSize * 1.24, height: m.iconSize * 1.24)
                    }
                }
                .scaleEffect(isTarget ? 1.1 : 1)
                .modifier(Jiggle(active: jiggle))
            Text(model.title(of: entry))
                .font(.system(size: m.labelFont, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .frame(width: m.cellW * 0.9, height: m.labelH)
        }
        .contentShape(Rectangle())
        .frame(width: m.cellW, height: m.cellH)
        .opacity(hidden ? 0 : 1)
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .global).onChanged { v in
                model.dragGesture(entry: entry, origin: origin, start: v.startLocation, current: v.location)
            }
        )
        .onTapGesture { model.activate(entry) }
        .contextMenu { EntryMenu(model: model, entry: entry, origin: origin) }
    }
}

struct EntryMenu: View {
    let model: RelaunchModel
    let entry: Entry
    let origin: Origin

    var body: some View {
        switch entry {
        case .app(let id):
            Button("Open") { model.activate(entry) }
            Button("Show in Finder") { model.reveal(id) }
            if case .folder(let fid) = origin {
                Divider()
                Button("Remove from Folder") { model.removeFromFolder(id, folder: fid) }
            }
        case .folder(let f):
            Button("Open Folder") { model.openFolder(f.id) }
            Button("Ungroup Folder") { model.ungroup(f.id) }
        }
    }
}

struct EntryIcon: View {
    let model: RelaunchModel
    let entry: Entry
    let size: CGFloat

    var body: some View {
        switch entry {
        case .app(let id): AppIconView(app: model.catalog[id], size: size)
        case .folder(let f): FolderIconView(model: model, folder: f, size: size)
        }
    }
}

struct AppIconView: View {
    let app: AppInfo?
    let size: CGFloat

    var body: some View {
        Image(nsImage: app.map { IconCache.shared.image(for: $0) } ?? NSImage(named: NSImage.applicationIconName)!)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// A glass tile with a 3×3 preview of its first apps, sized to the art box
/// of a standard macOS icon (~80% of the canvas).
struct FolderIconView: View {
    let model: RelaunchModel
    let folder: Folder
    let size: CGFloat

    var body: some View {
        let inner = size * 0.8
        let mini = inner * 0.26, gap = inner * 0.055
        let apps = Array(folder.apps.prefix(9))
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { c in
                        let i = r * 3 + c
                        if i < apps.count {
                            AppIconView(app: model.catalog[apps[i]], size: mini)
                        } else {
                            Color.clear.frame(width: mini, height: mini)
                        }
                    }
                }
            }
        }
        .frame(width: inner, height: inner)
        .glass(RoundedRectangle(cornerRadius: inner * 0.225, style: .continuous))
        .frame(width: size, height: size)
    }
}

struct Jiggle: ViewModifier {
    let active: Bool
    @ViewState private var seed = Double.random(in: 0..<1)

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                content.rotationEffect(.degrees(sin((t * 3.4 + seed) * .pi * 2) * 1.6))
            }
        } else {
            content
        }
    }
}

// MARK: Chrome

struct SearchBar: View {
    let model: RelaunchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("", text: Binding(get: { model.query }, set: { model.setQuery($0) }),
                      prompt: Text("Search").foregroundStyle(.white.opacity(0.55)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($focused)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(width: 240, height: 28)
        .glass(Capsule())
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
        .onChange(of: model.openFolderID) { _, id in focused = id == nil }
    }
}

struct PageDots: View {
    let count: Int
    let pager: Pager
    let onSelect: (Int) -> Void

    var body: some View {
        if count > 1 {
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(i == pager.page ? 0.95 : 0.32))
                        .frame(width: 7, height: 7)
                        .padding(4)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(i) }
                }
            }
        }
    }
}

struct FolderOverlay: View {
    let model: RelaunchModel
    let folder: Folder

    var body: some View {
        let apps = model.folderApps(folder)
        let fm = model.folderMetrics(apps.count)
        let m = fm.grid
        let rect = fm.panelRect
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { model.closeFolder() }

            VStack(spacing: 0) {
                FolderTitleField(model: model, folder: folder)
                    .frame(height: fm.titleH)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(apps.enumerated()), id: \.element) { i, id in
                        let page = i / fm.capacity, slot = i % fm.capacity
                        let c = fm.cellCenterLocal(slot)
                        EntryCell(model: model, entry: .app(id), origin: .folder(folder.id), metrics: m,
                                  jiggle: model.isEditing && page == model.folderPager.page)
                            .position(x: CGFloat(page) * fm.pageW + c.x, y: c.y)
                    }
                }
                .frame(width: fm.pageW, height: fm.gridH, alignment: .topLeading)
                .modifier(PagedOffset(pager: model.folderPager, width: fm.pageW))
                .frame(width: fm.pageW, height: fm.gridH)
                .clipped()
                PageDots(count: fm.pages, pager: model.folderPager) { model.setPage($0, ctx: .folder) }
                    .frame(height: fm.dotsH)
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .onTapGesture {}
            .glass(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: m.W, height: m.H, alignment: .topLeading)
    }
}

struct FolderTitleField: View {
    let model: RelaunchModel
    let folder: Folder
    @ViewState private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("Untitled").foregroundStyle(.white.opacity(0.4)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 40)
            .onAppear { text = folder.name }
            .onChange(of: text) { _, v in if v != folder.name { model.renameFolder(folder.id, to: v) } }
    }
}

struct DragOverlay: View {
    let model: RelaunchModel

    var body: some View {
        if let d = model.drag {
            let loc = model.dragLocation
            EntryIcon(model: model, entry: d.entry, size: model.metrics.iconSize)
                .scaleEffect(d.landing ? d.landingScale : 1.08)
                .opacity(d.landing && d.landingScale < 1 ? 0 : 1)
                .shadow(color: .black.opacity(d.landing ? 0 : 0.35), radius: 12, y: 6)
                .position(x: loc.x - d.grab.width, y: loc.y - d.grab.height)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Glass

extension View {
    /// Liquid Glass on macOS 26+, a material on earlier systems.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// The macOS 27 SDK declares `@State` as a macro whose plugin ships only with
/// Xcode. The property wrapper is unchanged, so alias it to build with the
/// Command Line Tools as well.
typealias ViewState<Value> = SwiftUI.State<Value>
