/// Where every managed window should be: the output of the window manager's model.
public struct Arrangement: Hashable, Sendable {
    /// Target frames of visible windows.
    public var frames: [WindowID: Rect] = [:]
    /// Windows on hidden workspaces, with the monitor they belong to.
    public var hidden: [WindowID: MonitorID] = [:]
    /// Visible windows from bottom to top.
    public var stack: [WindowID] = []
    /// Tiles the layout scrolled out of view, with where it put them. They are also `hidden`.
    public var outOfView: [WindowID: Rect] = [:]

    public init() {}
}

extension World {
    /// Computes the target frame of every window.
    public func arrangement() -> Arrangement {
        var result = Arrangement()
        var visible: Set<WorkspaceID> = []

        for monitor in monitors {
            visible.insert(monitor.activeWorkspace)
            place(monitor.activeWorkspace, on: monitor, scratchpad: false, into: &result)
            if let scratchpad = monitor.activeScratchpad {
                visible.insert(scratchpad)
                place(scratchpad, on: monitor, scratchpad: true, into: &result)
            }
        }

        for (id, workspace) in workspaces where !visible.contains(id) {
            for window in workspace.windows {
                result.hidden[window] = workspace.monitor
            }
        }
        // Group members behind the active one are kept out of sight.
        for group in groups.values {
            for member in group.members where member != group.active {
                guard let workspace = windows[member].flatMap({ workspaces[$0.workspace] }) else { continue }
                result.hidden[member] = workspace.monitor
            }
        }

        if let interaction, result.frames[interaction.window] != nil {
            result.stack.removeAll { $0 == interaction.window }
            result.stack.append(interaction.window)
        }
        return result
    }

    /// Where a workspace's windows go when it is shown, whether or not it is shown.
    /// Group members waiting behind the active one share its frame.
    public func layoutFrames(of workspaceID: WorkspaceID) -> [WindowID: Rect] {
        guard let workspace = workspaces[workspaceID], let monitor = monitor(workspace.monitor) else { return [:] }
        var result = Arrangement()
        place(workspaceID, on: monitor, scratchpad: workspaceID.isScratchpad, into: &result)
        var frames = result.frames.merging(result.outOfView) { shown, _ in shown }
        for group in groups.values {
            guard let frame = frames[group.active] else { continue }
            for member in group.members where frames[member] == nil { frames[member] = frame }
        }
        return frames
    }

    private func place(_ workspaceID: WorkspaceID, on monitor: Monitor, scratchpad: Bool, into result: inout Arrangement) {
        guard let workspace = workspaces[workspaceID] else { return }
        let settings = settings(for: workspaceID)
        let area = tilingArea(on: monitor)
        let boxes = workspace.tiling.boxes(in: layoutArea(on: monitor, settings: settings), settings: settings, minimumSizes: minimumBoxSizes(on: workspace, settings: settings))
        let scale = workspace.tiling.kind == .scrolling ? 1 : settings.scratchpads.scale

        for window in workspace.tiling.windows {
            guard let box = boxes[window], let state = windows[window] else { continue }
            var frame = TileGeometry.contentFrame(for: box, gaps: settings.layout.gaps, border: borderSize(of: state, settings: settings))
            if state.keepsSize && !state.floatingFrame.isEmpty {
                let size = Size(width: min(state.floatingFrame.width, frame.width), height: min(state.floatingFrame.height, frame.height))
                frame = frame.centered(size).integral
            }
            if state.group != nil, settings.tabs.showsBar {
                // Make room for the group's tab bar above the window.
                let bar = tabBarHeight(settings)
                frame.origin.y += bar
                frame.size.height = max(0, frame.height - bar)
            }
            if scratchpad {
                frame = TileGeometry.scaled(frame, by: scale)
            }
            guard isInView(frame, on: monitor) else {
                // Scrolled out of view: parked like the windows of a hidden workspace.
                result.hidden[window] = monitor.id
                result.outOfView[window] = frame
                continue
            }
            result.frames[window] = frame
            result.stack.append(window)
        }

        for window in workspace.floating {
            guard let state = windows[window] else { continue }
            var frame = state.floatingFrame
            let bar = tabBarHeight(settings)
            if state.group != nil, settings.tabs.showsBar, frame.intersects(area), frame.minY < area.minY + bar {
                // Its tab bar goes above it, below the menu bar or a status bar.
                frame.origin.y = area.minY + bar
            }
            result.frames[window] = frame
            result.stack.append(window)
        }

        if let fullscreen = workspace.fullscreenWindow, let frame = fullscreenFrame(for: fullscreen, on: monitor) {
            result.frames[fullscreen] = frame
            result.stack.removeAll { $0 == fullscreen }
            result.stack.append(fullscreen)
        }
    }

    /// Whether a tile the layout put partly or wholly off its monitor is shown there.
    ///
    /// A tile that runs off the screen stays when enough of it is in view; otherwise macOS
    /// moves it back. Part of a window over another display is not drawn there while most of
    /// the window is on its own, so a tile reaching onto another display must be mostly in view.
    /// Nothing may reach above the menu bar, which macOS does not allow.
    private func isInView(_ frame: Rect, on monitor: Monitor) -> Bool {
        let screen = monitor.frame
        guard frame.minX < screen.minX || frame.maxX > screen.maxX || frame.minY < screen.minY || frame.maxY > screen.maxY else { return true }
        guard frame.minY >= monitor.visibleFrame.minY - 1, frame.area > 0 else { return false }
        let shown = frame.intersection(screen).area / frame.area
        let reachesAnotherDisplay = monitors.contains { $0.id != monitor.id && $0.frame.intersects(frame) }
        return shown >= (reachesAnotherDisplay ? 0.6 : 0.1)
    }

    /// The least room a tile gets while others grow to their windows' minimum sizes. A window
    /// whose minimum is not known yet stays in sight, so its application can show how small it
    /// can be.
    static let smallestTile = Size(width: 100, height: 100)

    /// Minimum window sizes as layout boxes, which also hold gaps and borders.
    private func minimumBoxSizes(on workspace: Workspace, settings: Settings) -> [WindowID: Size] {
        var result: [WindowID: Size] = [:]
        let halfGap = settings.layout.gaps * 0.5
        let smallest = Self.smallestTile
        for id in workspace.tiling.windows {
            guard let window = windows[id] else { continue }
            let known = window.minimumTileSize ?? smallest
            let minimum = Size(width: max(known.width, smallest.width), height: max(known.height, smallest.height))
            let border = borderSize(of: window, settings: settings) * 2
            result[id] = Size(
                width: minimum.width + border + halfGap.left + halfGap.right,
                height: minimum.height + border + halfGap.top + halfGap.bottom
            )
        }
        return result
    }

    func fullscreenFrame(for window: WindowID, on monitor: Monitor) -> Rect? {
        guard let state = windows[window], let mode = state.fullscreen else { return nil }
        let settings = settings(for: state.workspace)
        switch mode {
        case .fullscreen:
            return monitor.visibleFrame
        case .maximized:
            let border = borderSize(of: state, settings: settings)
            return tilingArea(on: monitor).inset(by: settings.layout.margins + Insets(all: border)).integral
        }
    }

    /// The vertical space a group's tab bar takes above its window.
    public func tabBarHeight(_ settings: Settings) -> Double {
        settings.tabs.barHeight + 2
    }

    /// The border width drawn around a window.
    public func borderSize(of window: Window, settings: Settings? = nil) -> Double {
        let overrides = window.overrides
        if overrides.noBorder { return 0 }
        return overrides.borderWidth ?? (settings ?? self.settings(for: window.workspace)).borders.width
    }
}
