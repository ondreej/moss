extension World {
    // MARK: - Focus

    /// Records `window` as focused without switching workspaces. Unless `reveal` is `false`,
    /// a layout that scrolls brings the window into view.
    mutating func setFocus(_ window: WindowID?, reveal: Bool = true) {
        guard let window, let workspace = windows[window]?.workspace else {
            focusedWindowID = nil
            return
        }
        if let current = focusedWindowID, current != window, windows[current]?.overrides.keepsFocus == true, isVisible(window: current) {
            // `keep-focus`: the window keeps focus for as long as it is visible.
            return
        }
        focusClock += 1
        windows[window]?.focusStamp = focusClock
        workspaces[workspace]?.lastFocused = window
        focusedWindowID = window
        if let monitor = workspaces[workspace]?.monitor { focusedMonitorID = monitor }
        if reveal { self.reveal(window) }
    }

    /// Scrolls the layout holding `window` so the window is in view.
    mutating func reveal(_ window: WindowID) {
        guard let workspace = windows[window]?.workspace, workspaces[workspace]?.tiling.contains(window) == true else { return }
        let (area, settings) = (layoutArea(for: workspace), settings(for: workspace))
        workspaces[workspace]?.tiling.reveal(window, area: area, settings: settings)
    }

    /// Whether focusing `window` brings it to the front. Floating windows stay above the tiles:
    /// a tile that one of them overlaps takes focus where it is in the stacking order, unless
    /// it is fullscreen.
    public func raisesOnFocus(_ id: WindowID, in arrangement: Arrangement) -> Bool {
        guard let window = windows[id], window.isTiled, window.fullscreen == nil, !window.workspace.isScratchpad,
              let frame = arrangement.frames[id] else { return true }
        return !arrangement.stack.contains { other in
            guard other != id, let above = windows[other], above.isFloating || above.workspace.isScratchpad else { return false }
            return arrangement.frames[other]?.intersects(frame) == true
        }
    }

    /// Focuses `window`, switching to its workspace first when it is hidden.
    mutating func focus(_ window: WindowID, reveal: Bool = true) {
        if isStashed(window) { activateGroupMember(window) }
        guard let workspace = windows[window]?.workspace, let ws = workspaces[workspace] else { return }
        if !isVisible(workspace) {
            if workspace.isScratchpad {
                showScratchpad(workspace, on: ws.monitor)
            } else {
                activate(workspace, focus: false)
            }
        }
        setFocus(window, reveal: reveal)
    }

    /// Focuses the most appropriate window on `workspace`, or nothing when it is empty.
    public mutating func restoreFocus(on workspace: WorkspaceID) {
        guard let ws = workspaces[workspace] else {
            focusedWindowID = nil
            return
        }
        let members = Set(ws.windows)
        let candidate = ws.fullscreenWindow
            ?? ws.lastFocused.flatMap { members.contains($0) ? $0 : nil }
            ?? focusHistory.first(where: members.contains)
            ?? ws.windows.first
        setFocus(candidate)
        if candidate == nil { focusedMonitorID = ws.monitor }
    }

    /// Focus moved because of something outside Moss (a click, Cmd-Tab, an app activating).
    public mutating func handleFocusChange(to window: WindowID?) {
        guard let window, windows[window] != nil else {
            // Focus went to something Moss does not arrange, such as a window in fullscreen
            // in a Space of its own. Leave it there instead of taking focus back.
            releaseFocus()
            return
        }
        // The system confirming focus Moss gave, by hovering for example, leaves the view be.
        focus(window, reveal: window != focusedWindowID)
        refreshDynamicRules()
    }

    /// No arranged window has focus; the display keeps its place as the focused one.
    public mutating func releaseFocus() {
        guard focusedWindowID != nil else { return }
        focusedWindowID = nil
        refreshDynamicRules()
    }

    /// The cursor came to rest on `window` with `focus.follows-mouse` on. A tile barely in
    /// view is left alone (`layout.scrolling.hover-min-visible`), and focus that comes from
    /// hovering never scrolls the view.
    public mutating func handleHover(over window: WindowID) {
        guard let state = windows[window], window != focusedWindowID else { return }
        if state.isTiled, visibleFraction(of: window) < settings(for: state.workspace).layout.scrolling.hoverMinimumVisible { return }
        focus(window, reveal: false)
        refreshDynamicRules()
    }

    /// The primary button went down at `point`: a tile clicked there scrolls fully into view.
    public mutating func handleClick(at point: Point) {
        guard let window = visibleWindow(at: point), windows[window]?.isTiled == true else { return }
        reveal(window)
    }

    /// How much of `window` is on its monitor, from `0` to `1`.
    public func visibleFraction(of window: WindowID) -> Double {
        guard let workspace = windows[window]?.workspace, let monitor = workspaces[workspace].flatMap({ self.monitor($0.monitor) }),
              let frame = arrangement().frames[window], frame.area > 0 else { return 0 }
        return frame.intersection(monitor.frame).area / frame.area
    }

    /// The cursor moved onto another monitor.
    public mutating func handleCursorEntered(monitor id: MonitorID) {
        guard focusedMonitorID != id, let monitor = monitor(id) else { return }
        focusedMonitorID = id
        restoreFocus(on: monitor.activeScratchpad ?? monitor.activeWorkspace)
    }

    mutating func focusMonitor(_ id: MonitorID) {
        guard let monitor = monitor(id) else { return }
        focusedMonitorID = id
        restoreFocus(on: monitor.activeScratchpad ?? monitor.activeWorkspace)
    }

    // MARK: - Spatial navigation

    /// Layout boxes (before gaps) of the windows that can be navigated to, keyed by window.
    /// Workspaces showing a fullscreen window only expose that window. Tiles scrolled out of
    /// view are only reachable from their own workspace, `scrolledFrom`.
    func navigableBoxes(scratchpad: Bool, scrolledFrom: WorkspaceID? = nil) -> [WindowID: Rect] {
        var result: [WindowID: Rect] = [:]
        for monitor in monitors {
            let workspaceID = scratchpad ? monitor.activeScratchpad : monitor.activeWorkspace
            guard let workspaceID, let workspace = workspaces[workspaceID] else { continue }
            if let fullscreen = workspace.fullscreenWindow, let frame = fullscreenFrame(for: fullscreen, on: monitor) {
                result[fullscreen] = frame
                continue
            }
            let area = layoutArea(on: monitor, settings: settings(for: workspaceID))
            for (window, box) in workspace.tiling.boxes(in: area, settings: settings(for: workspaceID)) {
                guard workspaceID == scrolledFrom || box.intersects(area) else { continue }
                result[window] = box
            }
            for window in workspace.floating {
                result[window] = windows[window]?.floatingFrame
            }
        }
        return result
    }

    /// The window adjacent to `source` in `direction`:
    /// tiled windows must share an edge, floating windows use the nearest one in that direction.
    public func window(in direction: Direction, from source: WindowID) -> WindowID? {
        guard let window = windows[source] else { return nil }
        let boxes = navigableBoxes(scratchpad: window.workspace.isScratchpad, scrolledFrom: window.workspace)
        guard let origin = boxes[source] else { return nil }
        let candidates = boxes.filter { $0.key != source }

        if window.isFloating {
            return nearestFloatingCandidate(from: origin, toward: direction, among: candidates)
        }

        let tiled = candidates.filter { windows[$0.key]?.isFloating == false || workspaces[windows[$0.key]!.workspace]?.fullscreenWindow == $0.key }
        func sticks(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 2 }
        var best: (window: WindowID, score: Double, isLocal: Bool)?
        for (candidate, box) in tiled {
            let overlap: Double
            switch direction {
            case .left: overlap = sticks(origin.minX, box.maxX) ? min(origin.maxY, box.maxY) - max(origin.minY, box.minY) : 0
            case .right: overlap = sticks(origin.maxX, box.minX) ? min(origin.maxY, box.maxY) - max(origin.minY, box.minY) : 0
            case .up: overlap = sticks(origin.minY, box.maxY) ? min(origin.maxX, box.maxX) - max(origin.minX, box.minX) : 0
            case .down: overlap = sticks(origin.maxY, box.minY) ? min(origin.maxX, box.maxX) - max(origin.minX, box.minX) : 0
            }
            guard overlap > 0 else { continue }
            // Between several windows along the edge, the most recently focused one wins.
            let score = Double(windows[candidate]?.focusStamp ?? 0)
            // A neighbour on the same workspace wins over one on another monitor sharing the
            // edge, as when a scrolled layout's next column meets the next display.
            let isLocal = windows[candidate]?.workspace == window.workspace
            if let current = best, current.isLocal && !isLocal { continue }
            if best == nil || (isLocal && !best!.isLocal) || score > best!.score || (score == best!.score && candidate < best!.window) {
                best = (candidate, score, isLocal)
            }
        }
        return best?.window ?? nearestFloatingCandidate(from: origin, toward: direction, among: tiled)
    }

    private func nearestFloatingCandidate(from origin: Rect, toward direction: Direction, among candidates: [WindowID: Rect]) -> WindowID? {
        let center = origin.center
        var best: (window: WindowID, score: Double)?
        for (candidate, box) in candidates {
            let delta = box.center - center
            let along: Double, across: Double
            switch direction {
            case .left: (along, across) = (-delta.x, delta.y)
            case .right: (along, across) = (delta.x, delta.y)
            case .up: (along, across) = (-delta.y, delta.x)
            case .down: (along, across) = (delta.y, delta.x)
            }
            guard along > 0 else { continue }
            // Penalise candidates far off the axis of movement.
            let score = along + abs(across) * 2
            if best == nil || score < best!.score { best = (candidate, score) }
        }
        return best?.window
    }

    /// Moves focus in `direction`, crossing to the neighbouring monitor at the edge.
    mutating func moveFocus(_ direction: Direction) {
        if let current = focusedWindowID, let target = window(in: direction, from: current) {
            focus(target)
            return
        }
        guard let origin = focusedMonitor, let next = monitor(from: origin, toward: direction) else { return }
        focusMonitor(next.id)
    }
}
