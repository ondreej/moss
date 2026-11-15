extension World {
    /// How a newly discovered window should be placed.
    public enum WindowOrigin: Hashable, Sendable {
        /// The window just opened: place it on the focused workspace and apply rules.
        case opened
        /// The window already existed when Moss started: keep it on the monitor it is on.
        case existing
    }

    /// Starts managing a window. Returns `false` when the window is already managed.
    @discardableResult
    public mutating func addWindow(_ id: WindowID, properties: WindowProperties, frame: Rect, origin: WindowOrigin = .opened) -> Bool {
        guard windows[id] == nil, let focusedMonitor = focusedMonitor ?? monitors.first else { return false }

        var window = Window(id: id, properties: properties, workspace: focusedMonitor.activeWorkspace, isFloating: properties.prefersFloating, floatingFrame: frame)
        // Tags come first, so the other rules can match them.
        window.ruleTags = ruleTags(for: window, focused: false)
        var effects = windowRules.filter { $0.effect.isStatic && $0.matches(window, focused: false) }.map(\.effect)
        if origin == .opened, let index = pendingRunRules.firstIndex(where: { $0.matches(properties) }) {
            effects += pendingRunRules.remove(at: index).effects
        }

        // Decide the workspace.
        var silent = origin == .existing
        var targetMonitor = origin == .existing ? (monitor(at: frame.center) ?? focusedMonitor) : focusedMonitor
        var workspace = origin == .existing
            ? targetMonitor.activeWorkspace
            : (targetMonitor.activeScratchpad ?? targetMonitor.activeWorkspace)
        for effect in effects {
            switch effect {
            case .display(let selector):
                if let monitor = resolve(selector) {
                    targetMonitor = monitor
                    workspace = monitor.activeWorkspace
                }
            case .workspace(let selector, let isSilent):
                if let resolved = try? resolve(selector) {
                    workspace = resolved
                    silent = silent || isSilent
                }
            default:
                break
            }
        }
        if workspaces[workspace] == nil {
            createWorkspace(workspace, on: boundMonitor(for: workspace) ?? targetMonitor.id)
        }
        window.workspace = workspace

        // Decide floating and geometry.
        for effect in effects {
            switch effect {
            case .float: window.isFloating = true
            case .tile: window.isFloating = false
            case .keepSize: window.keepsSize = true
            default: break
            }
        }
        let monitorFrame = workspaces[workspace].flatMap { monitor($0.monitor) }?.usableFrame ?? targetMonitor.usableFrame
        window.floatingFrame = initialFloatingFrame(for: frame, effects: effects, in: monitorFrame)
        var tabs: WindowRule.TabsRule?
        for effect in effects {
            switch effect {
            case .minSize(let width, let height): window.sizeLimits.minimum = Size(width: width, height: height)
            case .maxSize(let width, let height): window.sizeLimits.maximum = Size(width: width, height: height)
            case .tabs(let rule): tabs = rule
            default: break
            }
        }
        window.isDeniedFromGroups = tabs == .never
        windows[id] = window

        // Insert into the workspace, or into the focused window's tab group (`tabs.auto-join`).
        let focusedOnWorkspace = workspaces[workspace]?.lastFocused
        let joinable = origin == .opened && tabs == nil && !effects.contains(.float) && !properties.prefersFloating
        if joinable, settings.tabs.autoJoin, let anchor = focusedOnWorkspace, let group = group(of: anchor) {
            addToGroup(id, group: group.id)
        } else if window.isFloating {
            workspaces[workspace]?.floating.append(id)
            if effects.contains(.pin) { windows[id]?.isPinned = true }
        } else {
            insertTiled(id, into: workspace)
        }

        if tabs == .own, windows[id]?.group == nil {
            toggleTabs(id)
        }

        if effects.contains(.fullscreen) {
            setFullscreen(id, .fullscreen)
        } else if effects.contains(.maximize) {
            setFullscreen(id, .maximized)
        } else {
            resolveFullscreenConflict(newWindow: id, on: workspace)
        }

        // Focus.
        let wantsFocus = origin == .opened && !effects.contains(.noInitialFocus)
        if wantsFocus {
            if silent && !isVisible(workspace) {
                // Focus stays where it is.
            } else if workspaces[workspace]?.fullscreenWindow.map({ $0 != id }) == true && settings.fullscreen.newWindow == .behind {
                // The new window opens behind the fullscreen one.
            } else {
                focus(id)
            }
        }
        refreshDynamicRules()
        return true
    }

    private func initialFloatingFrame(for frame: Rect, effects: [WindowRule.Effect], in area: Rect) -> Rect {
        var result = frame
        for effect in effects {
            switch effect {
            case .size(let width, let height):
                result.size = Size(width: width.resolve(relativeTo: area.width), height: height.resolve(relativeTo: area.height))
            case .position(let x, let y):
                result.origin = Point(x: area.minX + x.resolve(relativeTo: area.width), y: area.minY + y.resolve(relativeTo: area.height))
            default:
                break
            }
        }
        if effects.contains(.center) {
            result = area.centered(result.size)
        }
        return result
    }

    /// Inserts a tiled window into a workspace's layout, next to `target` or else the
    /// workspace's focused window.
    mutating func insertTiled(_ id: WindowID, into workspace: WorkspaceID, focalPoint: Point? = nil, target: WindowID? = nil, direction: Direction? = nil) {
        guard var ws = workspaces[workspace] else { return }
        let neighbor = (target ?? ws.lastFocused).flatMap { ws.tiling.contains($0) ? $0 : nil }
        ws.tiling.insert(id, context: InsertionContext(
            target: neighbor,
            cursor: cursor,
            focalPoint: focalPoint,
            direction: direction,
            area: layoutArea(for: workspace),
            settings: settings(for: workspace)
        ))
        workspaces[workspace] = ws
    }

    /// Decides what a fullscreen window does when another window opens on its workspace.
    private mutating func resolveFullscreenConflict(newWindow id: WindowID, on workspace: WorkspaceID) {
        guard let fullscreen = workspaces[workspace]?.fullscreenWindow, fullscreen != id,
              let mode = windows[fullscreen]?.fullscreen else { return }
        switch settings.fullscreen.newWindow {
        case .takeOver:
            clearFullscreen(on: workspace)
            setFullscreen(id, mode)
        case .exit:
            clearFullscreen(on: workspace)
        case .behind:
            break
        }
    }

    /// Stops managing a window.
    public mutating func removeWindow(_ id: WindowID) {
        guard let window = windows[id] else { return }
        let wasFocused = focusedWindowID == id
        if interaction?.window == id { interaction = nil }
        leaveGroup(id)
        detach(id)
        windows[id] = nil

        if wasFocused {
            focusedWindowID = nil
            if isVisible(window.workspace) {
                restoreFocus(on: window.workspace)
            }
        }
        closeScratchpadIfEmpty(window.workspace)
        removeWorkspaceIfUnused(window.workspace)
        if wasFocused, focusedWindowID == nil, let monitor = focusedMonitor {
            restoreFocus(on: monitor.activeScratchpad ?? monitor.activeWorkspace)
        }
    }

    /// Removes a window from its workspace's layout and floating list, keeping the window itself.
    mutating func detach(_ id: WindowID) {
        guard let workspace = windows[id]?.workspace else { return }
        workspaces[workspace]?.tiling.remove(id)
        workspaces[workspace]?.floating.removeAll { $0 == id }
        if workspaces[workspace]?.fullscreenWindow == id {
            workspaces[workspace]?.fullscreenWindow = nil
            windows[id]?.fullscreen = nil
        }
        if workspaces[workspace]?.lastFocused == id {
            workspaces[workspace]?.lastFocused = nil
        }
    }

    /// Updates what the platform reports about a window (title changes, mostly).
    public mutating func updateWindow(_ id: WindowID, properties: WindowProperties) {
        guard windows[id] != nil else { return }
        windows[id]?.properties = properties
        applyDynamicRules(to: id)
    }

    /// Re-evaluates the rules that can change during every window's lifetime: tags, decorations
    /// and focus. With `force`, windows are cleared even when no such rule is left.
    public mutating func refreshDynamicRules(force: Bool = false) {
        guard force || windowRules.contains(where: \.effect.isDynamic) else { return }
        for id in windows.keys { applyDynamicRules(to: id) }
    }

    mutating func applyDynamicRules(to id: WindowID) {
        guard var window = windows[id] else { return }
        let focused = focusedWindowID == id
        window.ruleTags = ruleTags(for: window, focused: focused)
        var overrides = WindowOverrides()
        for rule in windowRules where rule.effect.isDynamic && rule.matches(window, focused: focused) {
            switch rule.effect {
            case .noBorder: overrides.noBorder = true
            case .noFocus: overrides.noFocus = true
            case .noDim: overrides.noDim = true
            case .keepFocus: overrides.keepsFocus = true
            case .cornerRadius(let radius): overrides.cornerRadius = radius
            case .borderWidth(let width): overrides.borderWidth = width
            case .borderColor(let active, let inactive):
                overrides.activeBorder = active
                overrides.inactiveBorder = inactive
            default: break
            }
        }
        window.overrides = overrides
        if window != windows[id] { windows[id] = window }
    }

    /// The tags `tag` rules give a window, applied in order so later rules see earlier tags.
    func ruleTags(for window: Window, focused: Bool) -> Set<String> {
        var probe = window
        probe.ruleTags = []
        for rule in windowRules {
            guard case .tag(let name) = rule.effect, rule.matches(probe, focused: focused) else { continue }
            probe.ruleTags.insert(name)
        }
        return probe.ruleTags
    }

    /// The window whose visible frame contains `point`, topmost first.
    public func visibleWindow(at point: Point) -> WindowID? {
        let arrangement = arrangement()
        return arrangement.stack.reversed().first { arrangement.frames[$0]?.contains(point) == true }
    }

    // MARK: - Moving between workspaces

    /// Moves `window` to `target`, keeping its floating or tiled state.
    mutating func moveWindow(_ id: WindowID, to target: WorkspaceID, focalPoint: Point? = nil) {
        guard let window = windows[id], window.workspace != target else { return }
        let source = window.workspace
        if workspaces[target] == nil {
            createWorkspace(target, on: boundMonitor(for: target) ?? focusedMonitorID ?? workspaces[source]!.monitor)
        }
        let wasFullscreen = window.fullscreen
        detach(id)
        windows[id]?.workspace = target
        windows[id]?.isPinned = false

        if window.isFloating {
            workspaces[target]?.floating.append(id)
            // Keep the window's position relative to its monitor when changing monitors.
            if let from = workspaces[source].flatMap({ monitor($0.monitor) }), let to = workspaces[target].flatMap({ monitor($0.monitor) }), from.id != to.id {
                let relocated = relocate(window.floatingFrame, from: from.frame, to: to)
                windows[id]?.floatingFrame = relocated
            }
        } else {
            insertTiled(id, into: target, focalPoint: focalPoint)
        }
        if let wasFullscreen, workspaces[target]?.fullscreenWindow == nil {
            setFullscreen(id, wasFullscreen)
        }
        // A group travels as a whole.
        if let group = group(of: id) {
            for member in group.members where member != id { windows[member]?.workspace = target }
        }
        closeScratchpadIfEmpty(source)
    }

    /// A floating frame moved from one monitor to another, keeping its place relative to the
    /// monitor's corner and staying within the new monitor.
    func relocate(_ frame: Rect, from source: Rect, to monitor: Monitor) -> Rect {
        var moved = frame
        moved.origin = monitor.frame.origin + (frame.origin - source.origin)
        return clamp(moved, to: monitor.usableFrame)
    }

    func clamp(_ frame: Rect, to area: Rect) -> Rect {
        var result = frame
        result.size.width = min(frame.width, area.width)
        result.size.height = min(frame.height, area.height)
        result.origin.x = min(max(frame.minX, area.minX), area.maxX - result.width)
        result.origin.y = min(max(frame.minY, area.minY), area.maxY - result.height)
        return result
    }

    // MARK: - Floating, fullscreen and pinning

    mutating func setFloating(_ id: WindowID, _ floating: Bool) {
        guard let window = windows[id], window.isFloating != floating else { return }
        let workspace = window.workspace
        if floating {
            // Restore the last floating size, centred on the tile the window leaves.
            let tile = arrangement().frames[id] ?? window.floatingFrame
            let size = window.floatingFrame.isEmpty ? tile.size : window.floatingFrame.size
            workspaces[workspace]?.tiling.remove(id)
            workspaces[workspace]?.floating.append(id)
            windows[id]?.isFloating = true
            var frame = tile.centered(size).integral
            if let monitor = monitor(of: id) { frame = clamp(frame, to: monitor.usableFrame) }
            windows[id]?.floatingFrame = frame
        } else {
            workspaces[workspace]?.floating.removeAll { $0 == id }
            windows[id]?.isFloating = false
            windows[id]?.isPinned = false
            insertTiled(id, into: workspace)
        }
    }

    mutating func setFullscreen(_ id: WindowID, _ mode: FullscreenMode?) {
        guard let workspace = windows[id]?.workspace else { return }
        if let mode {
            clearFullscreen(on: workspace)
            windows[id]?.fullscreen = mode
            workspaces[workspace]?.fullscreenWindow = id
        } else if workspaces[workspace]?.fullscreenWindow == id {
            clearFullscreen(on: workspace)
        }
    }

    mutating func clearFullscreen(on workspace: WorkspaceID) {
        guard let current = workspaces[workspace]?.fullscreenWindow else { return }
        windows[current]?.fullscreen = nil
        workspaces[workspace]?.fullscreenWindow = nil
    }

    // MARK: - External geometry changes

    /// The user moved or resized a window with the system's own controls.
    public mutating func handleFrameChange(of id: WindowID, to frame: Rect) {
        guard let window = windows[id], isVisible(window.workspace), interaction?.window != id else { return }
        if window.isFloating {
            windows[id]?.floatingFrame = frame
            return
        }
        guard window.fullscreen == nil, let expected = arrangement().frames[id] else { return }
        let sizeChanged = abs(frame.width - expected.width) > 1 || abs(frame.height - expected.height) > 1
        guard sizeChanged else { return }

        // Work out which edges moved to emulate a corner drag.
        let leftMoved = abs(frame.minX - expected.minX) > 1
        let topMoved = abs(frame.minY - expected.minY) > 1
        let corner: Corner = switch (leftMoved, topMoved) {
        case (true, true): .topLeft
        case (true, false): .bottomLeft
        case (false, true): .topRight
        case (false, false): .bottomRight
        }
        let delta = Size(
            width: leftMoved ? frame.minX - expected.minX : frame.maxX - expected.maxX,
            height: topMoved ? frame.minY - expected.minY : frame.maxY - expected.maxY
        )
        resizeTiled(id, by: delta, corner: corner)
    }

    mutating func resizeTiled(_ id: WindowID, by delta: Size, corner: Corner?) {
        guard let workspace = windows[id]?.workspace, var ws = workspaces[workspace] else { return }
        ws.tiling.resize(id, by: delta, corner: corner, area: layoutArea(for: workspace), settings: settings(for: workspace))
        workspaces[workspace] = ws
    }

    /// Records that a tiled window stayed larger than its tile: its application will not go
    /// smaller. Returns whether anything new was learned.
    @discardableResult
    public mutating func learnMinimumSize(of id: WindowID, observed: Size, requested: Size, tolerance: Double = 8) -> Bool {
        guard let window = windows[id], window.isTiled else { return false }
        var minimum = window.minimumTileSize ?? Size(width: 0, height: 0)
        if observed.width > requested.width + tolerance { minimum.width = max(minimum.width, observed.width) }
        if observed.height > requested.height + tolerance { minimum.height = max(minimum.height, observed.height) }
        guard minimum != (window.minimumTileSize ?? Size(width: 0, height: 0)) else { return false }
        windows[id]?.minimumTileSize = minimum
        return true
    }

    /// The tiled window a dragged window trades places with when dropped at `point`: the one
    /// whose tile's middle `point` is in. Nearer a tile's edges, it goes in beside that tile.
    func swapPartner(for id: WindowID, at point: Point) -> WindowID? {
        guard let monitor = monitor(at: point) else { return nil }
        let workspace = monitor.activeScratchpad ?? monitor.activeWorkspace
        guard let tiled = workspaces[workspace]?.tiling.windows else { return nil }
        let frames = arrangement().frames
        for other in tiled where other != id {
            guard let frame = frames[other], frame.contains(point) else { continue }
            let middle = frame.inset(by: Insets(top: frame.height / 4, right: frame.width / 4, bottom: frame.height / 4, left: frame.width / 4))
            return middle.contains(point) ? other : nil
        }
        return nil
    }

    /// Where a tiled window being dragged would land if dropped at `point`: its tile once the
    /// drop is done. `nil` for windows that would not go back into the layout.
    public func dropTarget(for id: WindowID, at point: Point) -> Rect? {
        var preview = self
        if let interaction, interaction.window == id {
            guard case .move = interaction.kind, interaction.wasTiled else { return nil }
            preview.endInteraction(cursor: point)
        } else {
            guard windows[id]?.isTiled == true else { return nil }
            preview.drop(id, at: point)
        }
        return preview.arrangement().frames[id]
    }

    /// Drops a tiled window at `point`, putting it back into the layout under the cursor, on
    /// whichever monitor `point` is on.
    public mutating func drop(_ id: WindowID, at point: Point) {
        guard let window = windows[id], window.isTiled, let monitor = monitor(at: point) else { return }
        let target = monitor.activeScratchpad ?? monitor.activeWorkspace
        if window.workspace == target, let other = swapPartner(for: id, at: point) {
            // Dropped in the middle of another tile: the two trade places, and every split stays.
            workspaces[target]?.tiling.swap(id, other)
        } else if window.workspace == target {
            detach(id)
            insertTiled(id, into: target, focalPoint: point)
        } else {
            moveWindow(id, to: target, focalPoint: point)
        }
        setFocus(id)
    }
}
