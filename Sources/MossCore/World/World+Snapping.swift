extension World {
    /// Where a floating window moved to `frame` comes to rest with `floating.snap`: an edge that
    /// comes within `floating.snap-distance` of an edge of the display's tiling area, of the
    /// tiles' margins, or of another window in view joins it. Windows side by side keep the
    /// layout's gap between them.
    public func snapped(_ frame: Rect, moving id: WindowID) -> Rect {
        guard let state = windows[id] else { return frame }
        let settings = settings(for: state.workspace)
        let distance = settings.floating.snapDistance
        guard settings.floating.snaps, distance > 0,
              let monitor = monitor(at: frame.center) ?? workspaces[state.workspace].flatMap({ self.monitor($0.monitor) }) else { return frame }

        let area = tilingArea(on: monitor)
        let margins = settings.layout.margins
        let gaps = settings.layout.gaps
        let across = (gaps.left + gaps.right) / 2
        let down = (gaps.top + gaps.bottom) / 2
        var lefts = [area.minX, area.minX + margins.left]
        var rights = [area.maxX, area.maxX - margins.right]
        var tops = [area.minY, area.minY + margins.top]
        var bottoms = [area.maxY, area.maxY - margins.bottom]
        for (other, box) in arrangement().frames where other != id && box.intersects(area) {
            // Only windows alongside can be joined, not ones far above or below.
            if box.maxY >= frame.minY - distance && box.minY <= frame.maxY + distance {
                lefts += [box.maxX + across, box.minX]
                rights += [box.minX - across, box.maxX]
            }
            if box.maxX >= frame.minX - distance && box.minX <= frame.maxX + distance {
                tops += [box.maxY + down, box.minY]
                bottoms += [box.minY - down, box.maxY]
            }
        }

        func nearest(_ starts: [Double], _ ends: [Double], start: Double, end: Double) -> Double {
            let offsets = starts.map { $0 - start } + ends.map { $0 - end }
            return offsets.filter { abs($0) <= distance }.min { abs($0) < abs($1) } ?? 0
        }
        var result = frame
        result.origin.x += nearest(lefts, rights, start: frame.minX, end: frame.maxX)
        result.origin.y += nearest(tops, bottoms, start: frame.minY, end: frame.maxY)
        return result
    }

    /// A floating window the user moved comes to rest, snapping into place.
    public mutating func settleFloatingWindow(_ id: WindowID) {
        guard let state = windows[id], state.isFloating, state.fullscreen == nil else { return }
        let frame = snapped(state.floatingFrame, moving: id)
        windows[id]?.floatingFrame = frame
    }
}
