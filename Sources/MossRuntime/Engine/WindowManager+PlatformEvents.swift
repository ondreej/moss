import MossCore
import MossConfig
import MossIPC
import Foundation
import os

/// Windows, applications and displays changing underneath the window manager.
extension WindowManager {
    public func handle(_ event: PlatformEvent) {
        guard !isStopping else { return }
        Log.engine.debug("platform event: \(String(describing: event), privacy: .public)")
        let before = world
        var effects: [Effect] = []
        switch event {
        case .windowAppeared(let snapshot):
            observedFrames[snapshot.id] = snapshot.frame
            world.addWindow(snapshot.id, properties: snapshot.properties, frame: snapshot.frame, origin: .opened)
            if let launch = activationSwitch, launch.pid == snapshot.properties.pid, ContinuousClock.now - launch.at < .seconds(1),
               world.windows[snapshot.id]?.workspace != launch.from {
                // Opening a window activated its application first, which switched to that
                // application's workspace. Bring the new window back to where the user was.
                activationSwitch = nil
                effects += (try? world.perform(.moveToWorkspace(.selector(for: launch.from), .id(snapshot.id), follow: true))) ?? []
            }
            if world.windows[snapshot.id] != nil, world.focusedWindowID != snapshot.id {
                // Its application will focus it all the same.
                declinedFocus = declinedFocus.filter { ContinuousClock.now - $0.value < .seconds(1) }
                declinedFocus[snapshot.id] = .now
            }

        case .windowDiscovered(let snapshot):
            adoptExisting(snapshot)

        case .windowDisappeared(let id):
            forget(id)

        case .windowFrameChanged(let id, let frame):
            observedFrames[id] = frame
            if coveringWindows.contains(id) {
                if !coversDisplay(frame) {
                    coveringWindows.remove(id)
                    leaveFullscreen(id)
                }
                break
            }
            if !isPaused, lastArrangement?.hidden[id] != nil, !animator.isAnimating(id),
               let parked = appliedFrames[id], !parked.isApproximatelyEqual(to: frame, tolerance: 2) {
                // macOS brought a window of a hidden workspace back into view, as it does to an
                // application's other windows around fullscreen: it goes back out of sight.
                scheduleRepark(id)
                break
            }
            // Frames reported while a window is animated are Moss's own steps, and only
            // Moss moves windows that are out of sight.
            guard !isPaused, world.windows[id] != nil, lastArrangement?.frames[id] != nil,
                  world.interaction?.window != id, !animator.isAnimating(id) else { break }
            if let applied = appliedFrames[id], applied.isApproximatelyEqual(to: frame, tolerance: 2) { break }
            if coversDisplay(frame) {
                // Fullscreen drawn by the application itself, over the whole display. Its tile,
                // not the display, is where it returns to.
                observedFrames[id] = appliedFrames[id]
                coveringWindows.insert(id)
                enterFullscreen(id)
                break
            }
            frameChangedExternally(id, to: frame)

        case .windowPropertiesChanged(let id, let properties):
            if dormant[id] != nil {
                dormant[id]?.snapshot.properties = properties
            } else {
                world.updateWindow(id, properties: properties)
            }

        case .windowMinimized(let id, let minimized):
            // A window brought back from the Dock is wanted here and now.
            if minimized { setAside(id) } else { wake([id], onCurrentWorkspace: true) }

        case .windowNativeFullscreen(let id, let fullscreen):
            if fullscreen { enterFullscreen(id) } else { leaveFullscreen(id) }

        case .focusChanged(let id):
            if let pending = pendingFocus, ContinuousClock.now - pending.since < .milliseconds(400) {
                if id != pending.window {
                    // A stale notification from before Moss's focus request; ignore it.
                    Log.engine.debug("ignoring stale focus change to \(String(describing: id), privacy: .public)")
                    break
                }
                if world.focusedWindowID != id {
                    // The system confirming Moss's request after focus moved on, as when a
                    // window is focused and sent away at once: it must not be followed.
                    pendingFocus = nil
                    break
                }
            }
            if let id, let asked = focusRequests[id], ContinuousClock.now - asked < .seconds(1),
               world.focusedWindowID != id, world.windows[id] != nil, !world.isVisible(window: id) {
                // Moss focused it, or brought it forward, for a workspace left since, and the
                // system carried that out late. Focus goes back where it belongs.
                Log.engine.debug("ignoring late focus of \(id.address, privacy: .public), asked for on a workspace left since")
                appliedFocus = nil
                break
            }
            if let id, let raised = broughtForward[id], ContinuousClock.now - raised < .seconds(1),
               world.focusedWindowID != id, lastClick.map({ $0 < raised }) ?? true {
                // Focused only to bring it forward; applications report focus each on their own,
                // so this report may come after the one for the window that was to have focus.
                Log.engine.debug("ignoring focus of \(id.address, privacy: .public), only brought forward")
                appliedFocus = nil
                break
            }
            if let id, world.windows[id] != nil, !world.isVisible(window: id), followedFocus.remove(id) == nil,
               let current = world.focusedWindowID, current != id,
               world.windows[current]?.properties.pid == world.windows[id]?.properties.pid {
                // The application gave focus to one of its windows out of sight, as it does when
                // the one that had it closes, often before saying it closed. Followed only if
                // that window is still open in a moment.
                Task { @EngineActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, world.windows[current] != nil, world.windows[id] != nil else { return }
                    followedFocus.insert(id)
                    handle(PlatformEvent.focusChanged(id))
                }
                break
            }
            pendingFocus = nil
            appliedFocus = id
            // The newly focused window was raised, perhaps above its own border.
            decorations.restack()
            // Other applications' windows cannot be ordered above the focused one, but Moss's
            // own floating windows, such as settings, can.
            if let id, world.windows[id]?.isTiled == true { onTileFocused?() }
            if let id, let opened = declinedFocus.removeValue(forKey: id), ContinuousClock.now - opened < .seconds(1),
               world.focusedWindowID != nil, world.focusedWindowID != id {
                // The application focused a window Moss opened without focus, behind a
                // fullscreen window or on another workspace: focus goes back where it was.
                appliedFocus = nil
                break
            }
            if let id, let workspace = world.windows[id]?.workspace, !world.isVisible(workspace),
               let departure = lastDeparture, ContinuousClock.now - departure < .seconds(1) {
                // The system activated another application because a window closed. Keep focus
                // on the current workspace instead of following it elsewhere.
                Log.engine.debug("ignoring system activation of \(id.address, privacy: .public) after a window closed")
                break
            }
            let workspaceBefore = world.activeWorkspaceID
            let wasVisible = id.map(world.isVisible(window:)) ?? true
            world.handleFocusChange(to: id)
            if let id, let workspaceBefore, !wasVisible, let pid = world.windows[id]?.properties.pid {
                // Activating the application brought one of its hidden workspaces into view.
                activationSwitch = (pid, workspaceBefore, .now)
            }

        case .applicationTerminated(let pid):
            for window in world.windows.values where window.properties.pid == pid { forget(window.id) }
            for (id, window) in dormant where window.snapshot.properties.pid == pid { dormant[id] = nil }

        case .applicationHidden(let pid, let hidden):
            if hidden {
                for window in world.windows.values where window.properties.pid == pid { setAside(window.id) }
            } else {
                // Shown again: every window goes back to the workspace it was on.
                wake(dormant.keys.filter { dormant[$0]?.snapshot.properties.pid == pid }, onCurrentWorkspace: false)
            }

        case .displaysChanged(let displays):
            world.updateDisplays(displays)
            appliedFrames.removeAll()
            updateErrorBar()
        }
        commit(from: before, effects: effects)
    }

    func forget(_ id: WindowID) {
        if world.windows[id] != nil { lastDeparture = .now }
        animator.cancel(id)
        world.removeWindow(id)
        dormant[id] = nil
        coveringWindows.remove(id)
        appliedFrames[id] = nil
        observedFrames[id] = nil
        fittedFrames[id] = nil
        fitOffers[id] = nil
        declinedFocus[id] = nil
        if floatingDrag == id { floatingDrag = nil }
        if userDrag?.window == id { userDrag = nil }
    }

    /// A window went fullscreen by itself, in a Space of its own or over a whole display. It
    /// leaves the layout and keeps focus: focusing another window would take the user away.
    func enterFullscreen(_ id: WindowID) {
        let hadFocus = world.focusedWindowID == id
        setAside(id)
        if hadFocus {
            world.releaseFocus()
            appliedFocus = id
        }
    }

    /// The window left fullscreen and returns to its place, keeping focus if it has it.
    func leaveFullscreen(_ id: WindowID) {
        wake([id], onCurrentWorkspace: false)
        if appliedFocus == id { world.handleFocusChange(to: id) }
        // macOS puts the window back at its frame from before, at the end of an animation and
        // without reporting it, so its tile is applied now and again once that is over.
        observedFrames[id] = nil
        Task { @EngineActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, world.windows[id] != nil, !coveringWindows.contains(id) else { return }
            observedFrames[id] = nil
            appliedFrames[id] = nil
            reconcile()
        }
    }

    /// Whether `frame` is exactly a whole display, menu bar included.
    func coversDisplay(_ frame: Rect) -> Bool {
        world.monitors.contains { $0.frame.isApproximatelyEqual(to: frame, tolerance: 2) }
    }

    /// Takes a window out of the layout, remembering where it was.
    func setAside(_ id: WindowID) {
        guard let window = world.windows[id], let placement = world.placement(of: id) else { return }
        lastDeparture = .now
        // A parked window's frame is a corner of the screen; its model frame is the useful one.
        let frame = world.isVisible(window: id) ? observedFrames[id] ?? window.floatingFrame : window.floatingFrame
        dormantOrder += 1
        dormant[id] = DormantWindow(
            snapshot: WindowSnapshot(id: id, properties: window.properties, frame: frame),
            placement: placement,
            layout: window.isTiled ? world.workspaces[window.workspace].map { SavedLayout($0.tiling) } : nil,
            group: world.group(of: id).map { SessionState.Group(members: $0.members, active: $0.active) },
            order: dormantOrder
        )
        animator.cancel(id)
        world.removeWindow(id)
        appliedFrames[id] = nil
        if userDrag?.window == id { userDrag = nil }
    }

    /// Brings set-aside windows back where they were, or to the current workspace, with their
    /// tab groups. A workspace they return to gets its layout back as it was before the first
    /// of them left, unless other windows came in the meantime.
    func wake(_ ids: [WindowID], onCurrentWorkspace: Bool) {
        let returning = ids.compactMap { id in dormant.removeValue(forKey: id).map { (id: id, window: $0) } }
            .sorted { $0.window.order < $1.window.order }
        guard !returning.isEmpty else { return }
        var placements: [SessionState.Placement] = []
        var groups: [SessionState.Group] = []
        var layouts: [WorkspaceID: SavedLayout] = [:]
        for (id, window) in returning {
            let snapshot = window.snapshot
            world.addWindow(id, properties: snapshot.properties, frame: snapshot.frame, origin: .existing)
            var placement = window.placement
            if onCurrentWorkspace, let current = world.activeWorkspaceID { placement.workspace = current }
            placements.append(placement)
            // The first window to leave saw its group and layout whole; later ones saw less.
            if let group = window.group, !groups.contains(where: { !Set($0.members).isDisjoint(with: group.members) }) {
                groups.append(group)
            }
            if let layout = window.layout, placement.workspace == window.placement.workspace, layouts[placement.workspace] == nil {
                layouts[placement.workspace] = layout
            }
        }
        world.restore(SessionState(placements: placements, focusedWindow: onCurrentWorkspace ? returning.last?.id : nil, groups: groups))
        for (workspace, layout) in layouts {
            world.reinstate(layout, on: workspace, addingOthers: false)
        }
    }

    /// Parks a window of a hidden workspace again once macOS is done moving it.
    func scheduleRepark(_ id: WindowID) {
        guard pendingReparks.insert(id).inserted else { return }
        Task { @EngineActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            pendingReparks.remove(id)
            guard !isPaused, lastArrangement?.hidden[id] != nil else { return }
            appliedFrames[id] = nil
            reconcile()
        }
    }

    /// Once a window's own change of frame settles, fits the layout to it: room is made for a
    /// window its application keeps larger than its tile, and the window is fitted to its tile
    /// otherwise.
    func scheduleSettleCheck(_ id: WindowID) {
        guard pendingSettleChecks.insert(id).inserted else { return }
        Task { @EngineActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            pendingSettleChecks.remove(id)
            guard !isPaused, world.interaction == nil, userDrag == nil, !animator.isAnimating(id),
                  let tile = lastArrangement?.frames[id], let observed = observedFrames[id] else { return }
            let before = world
            if world.learnMinimumSize(of: id, observed: observed.size, requested: tile.size) {
                Log.engine.info("\(id.address, privacy: .public) needs at least \(Int(observed.width))×\(Int(observed.height)); making room")
                commit(from: before)
                // With no room left to make, the tile stays as it was and the window is fitted.
                guard let now = lastArrangement?.frames[id], now.isApproximatelyEqual(to: tile, tolerance: 1) else { return }
            }
            fit(id, observed: observed, in: tile)
        }
    }

    /// Places a window its application keeps at another size than its tile. One kept clearly
    /// smaller, as fixed-size and fixed-aspect windows are, is centered in its tile, so the space
    /// around it stays even. One larger than the layout could make room for is centered over its
    /// tile and kept on the display. Either way its border hugs it.
    ///
    /// A resizable window that seems smaller is first offered its whole tile once more: the frame
    /// it reported may be one it has since left, as when it was resized many times in a row. One
    /// that is larger has refused its tile already, its minimum size learned.
    private func fit(_ id: WindowID, observed: Rect, in tile: Rect) {
        let smaller = observed.width < tile.width - Self.fillTolerance || observed.height < tile.height - Self.fillTolerance
        let larger = observed.width > tile.width + 2 || observed.height > tile.height + 2
        guard smaller || larger else {
            // It fills its tile after all.
            fitOffers[id] = nil
            if fittedFrames.removeValue(forKey: id) != nil { reconcile() }
            return
        }
        if smaller, !larger, world.windows[id]?.properties.isResizable == true, fittedFrames[id] == nil,
           fitOffers[id].map({ !$0.isApproximatelyEqual(to: tile) }) ?? true {
            fitOffers[id] = tile
            appliedFrames[id] = tile
            windowSystem.setFrames([id: tile])
            scheduleSettleCheck(id)
            return
        }
        fitOffers[id] = nil
        var frame = tile.centered(observed.size)
        if let monitor = world.monitor(of: id), let workspace = world.windows[id]?.workspace {
            // Within the margins where it fits, as tiles are, and on the display regardless.
            let area = world.tilingArea(on: monitor)
            frame = frame.moved(inside: area.inset(by: world.settings(for: workspace).layout.margins)).moved(inside: area)
        }
        frame = frame.integral
        fittedFrames[id] = FittedFrame(tile: tile, frame: frame)
        if appliedFrames[id].map({ !$0.isApproximatelyEqual(to: frame, tolerance: 1) }) ?? true {
            appliedFrames[id] = frame
            windowSystem.setFrames([id: frame])
        }
        updateDecorations()
    }

    /// A window moved or resized without Moss asking for it.
    func frameChangedExternally(_ id: WindowID, to frame: Rect) {
        guard let window = world.windows[id] else { return }
        if window.isFloating {
            // A late report of the window being parked is not where it floats.
            if HiddenPlacement.isParked(frame, in: world.monitors.map(\.frame)) { return }
            world.handleFrameChange(of: id, to: frame)
            appliedFrames[id] = frame
            // Dragged by its title bar, it snaps into place once the button is released.
            if windowSystem.isPrimaryButtonDown() { floatingDrag = id }
            return
        }
        guard windowSystem.isPrimaryButtonDown() else {
            // The application changed its own frame, often because it cannot be as small as
            // its tile. Accept what it chose: the requested frame stays recorded, so it is sent
            // again only when the layout changes. Once the frame settles, the layout learns the
            // window's minimum size and makes room for it.
            scheduleSettleCheck(id)
            return
        }
        // The user is dragging the window's title bar or edges.
        let target = world.arrangement().frames[id] ?? frame
        let resized = abs(frame.width - target.width) > 2 || abs(frame.height - target.height) > 2
        userDrag = (id, resized || userDrag?.resized == true)
        if resized {
            world.handleFrameChange(of: id, to: frame)
        }
        // The user owns this window's frame until the button is released.
        appliedFrames[id] = frame
    }
}

/// The frame a window settled on inside a tile it would not fill.
struct FittedFrame {
    var tile: Rect
    var frame: Rect
}

/// A window out of the layout for now, with where to put it back.
struct DormantWindow {
    var snapshot: WindowSnapshot
    var placement: SessionState.Placement
    /// The layout as the window left it.
    var layout: SavedLayout?
    /// Its tab group as it left it.
    var group: SessionState.Group?
    /// When it left, counting up.
    var order: Int
}
