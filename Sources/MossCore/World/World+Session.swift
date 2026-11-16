/// Where windows were, so a restarted window manager can put them back.
///
/// Window identifiers stay valid for as long as their applications run, so a session saved
/// when Moss quits can be restored when it starts again.
public struct SessionState: Hashable, Sendable, Codable {
    public struct Placement: Hashable, Sendable, Codable {
        public var window: WindowID
        public var workspace: WorkspaceID
        public var isFloating: Bool
        public var floatingFrame: Rect
        public var isPinned: Bool
        /// Where a tiled window's tile was, so it can return to the same place.
        public var tile: Rect?
        public var fullscreen: FullscreenMode?

        public init(window: WindowID, workspace: WorkspaceID, isFloating: Bool, floatingFrame: Rect, isPinned: Bool, tile: Rect? = nil, fullscreen: FullscreenMode? = nil) {
            self.window = window
            self.workspace = workspace
            self.isFloating = isFloating
            self.floatingFrame = floatingFrame
            self.isPinned = isPinned
            self.tile = tile
            self.fullscreen = fullscreen
        }
    }

    /// Groups as their members in tab order, with the active member.
    public struct Group: Hashable, Sendable, Codable {
        public var members: [WindowID]
        public var active: WindowID

        public init(members: [WindowID], active: WindowID) {
            self.members = members
            self.active = active
        }
    }

    public var placements: [Placement]
    /// The workspace each monitor was showing.
    public var activeWorkspaces: [MonitorID: WorkspaceID]
    public var focusedWindow: WindowID?
    public var groups: [Group]
    /// Monitors that workspaces return to when they are connected again.
    public var homes: [WorkspaceID: Workspace.Home]
    /// Each workspace's layout, so its windows go back exactly where they were.
    public var layouts: [WorkspaceID: SavedLayout]
    /// Layouts chosen with the `layout` action in place of the configured ones.
    public var layoutOverrides: [WorkspaceID: LayoutKind]
    /// The window each workspace last focused, which gets focus when it is shown again.
    public var lastFocused: [WorkspaceID: WindowID]
    /// Windows in macOS fullscreen, with the workspace each belongs to.
    public var fullscreenSpaces: [WindowID: WorkspaceID]

    public init(
        placements: [Placement] = [],
        activeWorkspaces: [MonitorID: WorkspaceID] = [:],
        focusedWindow: WindowID? = nil,
        groups: [Group] = [],
        homes: [WorkspaceID: Workspace.Home] = [:],
        layouts: [WorkspaceID: SavedLayout] = [:],
        layoutOverrides: [WorkspaceID: LayoutKind] = [:],
        lastFocused: [WorkspaceID: WindowID] = [:],
        fullscreenSpaces: [WindowID: WorkspaceID] = [:]
    ) {
        self.placements = placements
        self.activeWorkspaces = activeWorkspaces
        self.focusedWindow = focusedWindow
        self.groups = groups
        self.homes = homes
        self.layouts = layouts
        self.layoutOverrides = layoutOverrides
        self.lastFocused = lastFocused
        self.fullscreenSpaces = fullscreenSpaces
    }

    private enum CodingKeys: String, CodingKey {
        case placements, activeWorkspaces, focusedWindow, groups, homes, layouts, layoutOverrides, lastFocused, fullscreenSpaces
    }

    /// Tolerates sessions written by other versions: anything missing is treated as empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        placements = try container.decodeIfPresent([Placement].self, forKey: .placements) ?? []
        activeWorkspaces = try container.decodeIfPresent([MonitorID: WorkspaceID].self, forKey: .activeWorkspaces) ?? [:]
        focusedWindow = try container.decodeIfPresent(WindowID.self, forKey: .focusedWindow)
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
        homes = try container.decodeIfPresent([WorkspaceID: Workspace.Home].self, forKey: .homes) ?? [:]
        // A layout of an unknown shape only loses where windows were, not the rest.
        layouts = (try? container.decodeIfPresent([WorkspaceID: SavedLayout].self, forKey: .layouts)) ?? [:]
        layoutOverrides = (try? container.decodeIfPresent([WorkspaceID: LayoutKind].self, forKey: .layoutOverrides)) ?? [:]
        lastFocused = (try? container.decodeIfPresent([WorkspaceID: WindowID].self, forKey: .lastFocused)) ?? [:]
        fullscreenSpaces = (try? container.decodeIfPresent([WindowID: WorkspaceID].self, forKey: .fullscreenSpaces)) ?? [:]
    }
}

extension World {
    /// The current placement of every window, in layout order.
    public func sessionState() -> SessionState {
        var placements: [SessionState.Placement] = []
        for workspace in sortedWorkspaces {
            // Group members waiting behind the active one are saved with their group.
            for id in workspace.windows + stashedMembers(on: workspace.id) {
                if let placement = placement(of: id) { placements.append(placement) }
            }
        }
        var active: [MonitorID: WorkspaceID] = [:]
        for monitor in monitors { active[monitor.id] = monitor.activeWorkspace }
        let groups = self.groups.values.sorted { $0.id < $1.id }.map {
            SessionState.Group(members: $0.members, active: $0.active)
        }
        let homes = workspaces.compactMapValues(\.home)
        let layouts = workspaces.filter { !$0.value.tiling.isEmpty }.mapValues { SavedLayout($0.tiling) }
        return SessionState(
            placements: placements,
            activeWorkspaces: active,
            focusedWindow: focusedWindowID,
            groups: groups,
            homes: homes,
            layouts: layouts,
            layoutOverrides: workspaces.compactMapValues(\.layoutOverride),
            lastFocused: workspaces.compactMapValues(\.lastFocused),
            fullscreenSpaces: fullscreenSpaces
        )
    }

    /// Where a window is, so it can be put back there later.
    public func placement(of id: WindowID) -> SessionState.Placement? {
        guard let window = windows[id] else { return nil }
        return SessionState.Placement(
            window: id,
            workspace: window.workspace,
            isFloating: window.isFloating,
            floatingFrame: window.floatingFrame,
            isPinned: window.isPinned,
            tile: tileBox(of: id),
            fullscreen: window.fullscreen
        )
    }

    /// The tiles of a workspace's layout, before gaps.
    private func tileBoxes(on workspace: WorkspaceID) -> [WindowID: Rect] {
        guard let ws = workspaces[workspace] else { return [:] }
        return ws.tiling.boxes(in: layoutArea(for: workspace), settings: settings(for: workspace))
    }

    private func tileBox(of id: WindowID) -> Rect? {
        guard let window = windows[id], window.isTiled else { return nil }
        return tileBoxes(on: window.workspace)[id]
    }

    private func stashedMembers(on workspace: WorkspaceID) -> [WindowID] {
        groups.values.flatMap { group in group.members.filter { $0 != group.active && windows[$0]?.workspace == workspace } }
    }

    /// Puts windows that still exist back on the workspaces they were on.
    public mutating func restore(_ state: SessionState) {
        for placement in state.placements {
            guard var window = windows[placement.window] else { continue }
            detach(window.id)
            if workspaces[placement.workspace] == nil {
                let monitor = boundMonitor(for: placement.workspace)
                    ?? state.activeWorkspaces.first { $0.value == placement.workspace }.flatMap { monitor($0.key)?.id }
                    ?? focusedMonitorID
                    ?? monitors.first?.id
                guard let monitor else { continue }
                createWorkspace(placement.workspace, on: monitor)
            }
            window.workspace = placement.workspace
            window.isFloating = placement.isFloating
            window.isPinned = placement.isPinned && placement.isFloating
            if placement.isFloating { window.floatingFrame = placement.floatingFrame }
            windows[window.id] = window
            if placement.isFloating {
                workspaces[placement.workspace]?.floating.append(window.id)
            } else if let tile = placement.tile {
                // Back beside the window that now covers where its tile was.
                let center = tile.center
                let neighbor = tileBoxes(on: placement.workspace).first { $0.value.contains(center) }?.key
                insertTiled(window.id, into: placement.workspace, focalPoint: center, target: neighbor ?? workspaces[placement.workspace]?.tiling.windows.last)
            } else {
                insertTiled(window.id, into: placement.workspace, target: workspaces[placement.workspace]?.tiling.windows.last)
            }
        }
        for saved in state.groups {
            let present = saved.members.filter { windows[$0] != nil }
            let loose = present.filter { windows[$0]?.group == nil }
            // Members still together, as when one tab comes back alone, take the others in.
            let id: GroupID
            if let existing = present.compactMap({ windows[$0]?.group }).first {
                id = existing
            } else {
                guard let first = loose.first(where: { $0 == saved.active }) ?? loose.first else { continue }
                toggleTabs(first)
                guard let made = windows[first]?.group else { continue }
                id = made
            }
            for member in loose where windows[member]?.group == nil { addToGroup(member, group: id) }
            if present.contains(saved.active) { activateGroupMember(saved.active) }
            // The saved tab order, then any tabs that joined since.
            if let members = groups[id]?.members {
                groups[id]?.members = saved.members.filter(members.contains) + members.filter { !saved.members.contains($0) }
            }
        }
        for (monitorID, workspace) in state.activeWorkspaces {
            guard let index = monitorIndex(monitorID) else { continue }
            if workspaces[workspace] == nil { createWorkspace(workspace, on: monitorID) }
            workspaces[workspace]?.monitor = monitorID
            monitors[index].activeWorkspace = workspace
        }
        for (id, home) in state.homes where workspaces[id] != nil && monitor(home.monitor) == nil && !monitors.contains(where: { $0.name == home.name }) {
            workspaces[id]?.home = home
        }
        for (id, kind) in state.layoutOverrides where workspaces[id] != nil && kind != settings(for: id).layout.style {
            workspaces[id]?.layoutOverride = kind
            let (area, effective) = (layoutArea(for: id), settings(for: id))
            workspaces[id]?.switchLayout(to: kind, area: area, settings: effective)
        }
        for (id, saved) in state.layouts where workspaces[id] != nil {
            reinstate(saved, on: id, addingOthers: true)
        }
        for (window, workspace) in state.fullscreenSpaces where fullscreenSpaces[window] != nil {
            // Found in fullscreen again: back on the workspace it belonged to.
            if workspaces[workspace] == nil, let monitor = boundMonitor(for: workspace) ?? focusedMonitorID ?? monitors.first?.id {
                createWorkspace(workspace, on: monitor)
            }
            if workspaces[workspace] != nil { fullscreenSpaces[window] = workspace }
        }
        for (id, window) in state.lastFocused where windows[window]?.workspace == id || fullscreenSpaces[window] == id {
            workspaces[id]?.lastFocused = window
        }
        for placement in state.placements {
            guard let mode = placement.fullscreen, let window = windows[placement.window], window.fullscreen == nil,
                  workspaces[window.workspace]?.fullscreenWindow == nil else { continue }
            setFullscreen(placement.window, mode)
        }
        for id in Array(workspaces.keys) { removeWorkspaceIfUnused(id) }
        if let focused = state.focusedWindow, windows[focused] != nil {
            focus(focused)
        } else if let focused = focusedWindowID, !isVisible(window: focused) {
            // Focus from before the session was restored, on a workspace now out of sight.
            focusedWindowID = nil
        }
        refreshDynamicRules()
    }
}
