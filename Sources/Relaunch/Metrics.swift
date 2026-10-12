import CoreGraphics

/// Screen-relative grid geometry. Everything is derived from the screen size
/// so the grid fills any display the way Launchpad's did.
struct GridMetrics {
    let size: CGSize
    let cols: Int
    let rows: Int
    /// Height of the camera housing on notched displays (0 elsewhere).
    var topInset: CGFloat = 0

    var W: CGFloat { size.width }
    var H: CGFloat { size.height }
    var capacity: Int { cols * rows }

    var top: CGFloat { max(96, H * 0.115, searchY + 52) }
    var bottom: CGFloat { H - max(84, H * 0.10) }
    var side: CGFloat { W * 0.105 }
    var cellW: CGFloat { (W - 2 * side) / CGFloat(cols) }
    var cellH: CGFloat { (bottom - top) / CGFloat(rows) }

    var iconSize: CGFloat { floor(min(cellW * 0.54, cellH * 0.58, 136)) }
    var labelFont: CGFloat { max(11, min(14, (iconSize * 0.14).rounded())) }
    var labelH: CGFloat { ceil(labelFont * 1.35) }
    var spacing: CGFloat { max(4, (iconSize * 0.07).rounded()) }

    var edgeZone: CGFloat { max(36, side * 0.45) }
    var searchY: CGFloat { max(44, H * 0.05, topInset + 30) }
    var dotsY: CGFloat { H - max(44, H * 0.055) }

    func cellCenter(_ slot: Int) -> CGPoint {
        let c = slot % cols, r = slot / cols
        return CGPoint(x: side + cellW * (CGFloat(c) + 0.5), y: top + cellH * (CGFloat(r) + 0.5))
    }

    func iconCenter(_ slot: Int) -> CGPoint {
        var p = cellCenter(slot)
        p.y -= (labelH + spacing) / 2
        return p
    }

    func slot(at p: CGPoint) -> Int? {
        guard p.x >= side, p.x < W - side, p.y >= top, p.y < bottom else { return nil }
        let c = Int((p.x - side) / cellW), r = Int((p.y - top) / cellH)
        return min(r, rows - 1) * cols + min(c, cols - 1)
    }
}

/// The open-folder panel: a centered, full-width strip of up to three rows.
struct FolderMetrics {
    let grid: GridMetrics
    let count: Int

    var cols: Int { min(grid.cols, 7) }
    var maxRows: Int { 3 }
    var capacity: Int { cols * maxRows }
    var pages: Int { max(1, (count + capacity - 1) / capacity) }
    var rows: Int { pages > 1 ? maxRows : max(1, min(maxRows, (count + cols - 1) / cols)) }

    var pad: CGFloat { grid.cellW * 0.3 }
    var titleH: CGFloat { 72 }
    var dotsH: CGFloat { pages > 1 ? 34 : 16 }
    var pageW: CGFloat { CGFloat(cols) * grid.cellW }
    var gridH: CGFloat { CGFloat(rows) * grid.cellH }

    var panelRect: CGRect {
        let w = pageW + 2 * pad, h = titleH + gridH + dotsH
        return CGRect(x: (grid.W - w) / 2, y: (grid.H - h) / 2, width: w, height: h)
    }

    var gridOrigin: CGPoint { CGPoint(x: panelRect.minX + pad, y: panelRect.minY + titleH) }

    /// Cell center relative to the folder grid's origin.
    func cellCenterLocal(_ slot: Int) -> CGPoint {
        let c = slot % cols, r = slot / cols
        return CGPoint(x: grid.cellW * (CGFloat(c) + 0.5), y: grid.cellH * (CGFloat(r) + 0.5))
    }

    /// Icon center in window coordinates for a slot on the visible page.
    func iconCenter(_ slot: Int) -> CGPoint {
        let l = cellCenterLocal(slot)
        return CGPoint(x: gridOrigin.x + l.x, y: gridOrigin.y + l.y - (grid.labelH + grid.spacing) / 2)
    }

    func slot(at p: CGPoint) -> Int? {
        let x = p.x - gridOrigin.x, y = p.y - gridOrigin.y
        guard x >= 0, x < pageW, y >= 0, y < gridH else { return nil }
        return min(Int(y / grid.cellH), rows - 1) * cols + min(Int(x / grid.cellW), cols - 1)
    }
}
