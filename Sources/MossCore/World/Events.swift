/// Something that happened, for scripts and status bars following the event stream. Each event
/// is sent as a JSON object on a line of its own, such as
/// `{"event":"workspace-shown","workspace":"2","name":"2","display":"Built-in Retina Display"}`.
public enum Event: Hashable, Sendable {
    /// A workspace was shown on the focused display; `name` is the name shown for it.
    case workspaceShown(workspace: String, name: String, display: String)
    case displayFocused(display: String, workspace: String)
    case windowFocused(WindowID?, bundleID: String, title: String)
    case fullscreenChanged(WindowID?, isFullscreen: Bool)
    case displayAdded(String)
    case displayRemoved(String)
    case workspaceCreated(String)
    case workspaceRemoved(String)
    case workspaceMoved(String, display: String)
    case workspaceRenamed(String, name: String)
    /// A scratchpad was shown on a display, or hidden (`nil`).
    case scratchpadShown(String?, display: String)
    case windowOpened(WindowID, workspace: String, bundleID: String, title: String)
    case windowClosed(WindowID)
    case windowMoved(WindowID, workspace: String)
    case windowRetitled(WindowID, title: String)
    case floatingChanged(WindowID, isFloating: Bool)
    case pinnedChanged(WindowID, isPinned: Bool)
    case tabsCreated([WindowID])
    case tabsDissolved([WindowID])
    case windowJoinedTabs(WindowID)
    case windowLeftTabs(WindowID)
    /// The mode of shortcuts changed; `nil` is the default one.
    case modeChanged(String?)
    case configReloaded
    /// Sent by the `emit` action.
    case custom(String)
    case tilingPaused(Bool)

    /// The event's name, e.g. `workspace-shown`.
    public var name: String {
        switch self {
        case .workspaceShown: "workspace-shown"
        case .displayFocused: "display-focused"
        case .windowFocused: "window-focused"
        case .fullscreenChanged: "fullscreen-changed"
        case .displayAdded: "display-added"
        case .displayRemoved: "display-removed"
        case .workspaceCreated: "workspace-created"
        case .workspaceRemoved: "workspace-removed"
        case .workspaceMoved: "workspace-moved"
        case .workspaceRenamed: "workspace-renamed"
        case .scratchpadShown: "scratchpad-shown"
        case .windowOpened: "window-opened"
        case .windowClosed: "window-closed"
        case .windowMoved: "window-moved"
        case .windowRetitled: "window-retitled"
        case .floatingChanged: "floating-changed"
        case .pinnedChanged: "pinned-changed"
        case .tabsCreated: "tabs-created"
        case .tabsDissolved: "tabs-dissolved"
        case .windowJoinedTabs: "window-joined-tabs"
        case .windowLeftTabs: "window-left-tabs"
        case .modeChanged: "mode-changed"
        case .configReloaded: "config-reloaded"
        case .custom: "custom"
        case .tilingPaused: "tiling-paused"
        }
    }

    /// Every event name, for documentation.
    public static let names = [
        "workspace-shown", "display-focused", "window-focused", "fullscreen-changed", "display-added", "display-removed",
        "workspace-created", "workspace-removed", "workspace-moved", "workspace-renamed", "scratchpad-shown",
        "window-opened", "window-closed", "window-moved", "window-retitled", "floating-changed", "pinned-changed",
        "tabs-created", "tabs-dissolved", "window-joined-tabs", "window-left-tabs", "mode-changed", "config-reloaded",
        "custom", "tiling-paused",
    ]
}

extension Event: Encodable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        func put(_ key: String, _ value: some Encodable) throws { try container.encode(value, forKey: Key(key)) }
        /// Windows are written by their address, as everywhere else, such as `"0x1d"`.
        func put(window: WindowID?) throws { try container.encode(window?.address, forKey: Key("window")) }
        try put("event", name)
        switch self {
        case .workspaceShown(let workspace, let name, let display):
            try put("workspace", workspace)
            try put("name", name)
            try put("display", display)
        case .displayFocused(let display, let workspace):
            try put("display", display)
            try put("workspace", workspace)
        case .windowFocused(let window, let bundleID, let title):
            try put(window: window)
            try put("bundleID", bundleID)
            try put("title", title)
        case .fullscreenChanged(let window, let isFullscreen):
            try put(window: window)
            try put("fullscreen", isFullscreen)
        case .displayAdded(let display), .displayRemoved(let display):
            try put("display", display)
        case .workspaceCreated(let workspace), .workspaceRemoved(let workspace):
            try put("workspace", workspace)
        case .workspaceMoved(let workspace, let display):
            try put("workspace", workspace)
            try put("display", display)
        case .workspaceRenamed(let workspace, let name):
            try put("workspace", workspace)
            try put("name", name)
        case .scratchpadShown(let scratchpad, let display):
            try put("scratchpad", scratchpad)
            try put("display", display)
        case .windowOpened(let window, let workspace, let bundleID, let title):
            try put(window: window)
            try put("workspace", workspace)
            try put("bundleID", bundleID)
            try put("title", title)
        case .windowClosed(let window), .windowJoinedTabs(let window), .windowLeftTabs(let window):
            try put(window: window)
        case .windowMoved(let window, let workspace):
            try put(window: window)
            try put("workspace", workspace)
        case .windowRetitled(let window, let title):
            try put(window: window)
            try put("title", title)
        case .floatingChanged(let window, let isFloating):
            try put(window: window)
            try put("floating", isFloating)
        case .pinnedChanged(let window, let isPinned):
            try put(window: window)
            try put("pinned", isPinned)
        case .tabsCreated(let windows), .tabsDissolved(let windows):
            try put("windows", windows.map(\.address))
        case .modeChanged(let mode):
            try put("mode", mode ?? "default")
        case .configReloaded:
            break
        case .custom(let text):
            try put("text", text)
        case .tilingPaused(let paused):
            try put("paused", paused)
        }
    }
}

extension World {
    /// Derives the events describing how the world changed since `old`.
    public func events(since old: World) -> [Event] {
        var events: [Event] = []
        let oldMonitors = Dictionary(uniqueKeysWithValues: old.monitors.map { ($0.id, $0) })
        let newMonitors = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })

        for monitor in monitors where oldMonitors[monitor.id] == nil {
            events.append(.displayAdded(monitor.name))
        }
        for monitor in old.monitors where newMonitors[monitor.id] == nil {
            events.append(.displayRemoved(monitor.name))
        }
        for workspace in sortedWorkspaces where old.workspaces[workspace.id] == nil {
            events.append(.workspaceCreated(workspace.id.name))
        }

        for window in sortedWindows {
            guard let previous = old.windows[window.id] else {
                events.append(.windowOpened(window.id, workspace: window.workspace.name, bundleID: window.properties.appID, title: window.properties.title))
                continue
            }
            if previous.workspace != window.workspace {
                events.append(.windowMoved(window.id, workspace: window.workspace.name))
            }
            if previous.isFloating != window.isFloating {
                events.append(.floatingChanged(window.id, isFloating: window.isFloating))
            }
            if previous.properties.title != window.properties.title {
                events.append(.windowRetitled(window.id, title: window.properties.title))
            }
            if previous.isPinned != window.isPinned {
                events.append(.pinnedChanged(window.id, isPinned: window.isPinned))
            }
        }

        for workspace in sortedWorkspaces {
            if let previous = old.workspaces[workspace.id], previous.monitor != workspace.monitor, let monitor = monitor(workspace.monitor) {
                events.append(.workspaceMoved(workspace.id.name, display: monitor.name))
            }
            if old.displayName(of: workspace.id) != displayName(of: workspace.id) {
                events.append(.workspaceRenamed(workspace.id.name, name: displayName(of: workspace.id)))
            }
        }

        for monitor in monitors where oldMonitors[monitor.id]?.activeScratchpad != monitor.activeScratchpad {
            events.append(.scratchpadShown(monitor.activeScratchpad?.name, display: monitor.name))
        }

        if let workspace = activeWorkspaceID, workspace != old.activeWorkspaceID, let monitor = focusedMonitor {
            events.append(.workspaceShown(workspace: workspace.name, name: displayName(of: workspace), display: monitor.name))
        }
        if focusedMonitorID != old.focusedMonitorID, let monitor = focusedMonitor {
            events.append(.displayFocused(display: monitor.name, workspace: monitor.activeWorkspace.name))
        }

        for window in sortedWindows where (window.fullscreen != nil) != (old.windows[window.id]?.fullscreen != nil) {
            events.append(.fullscreenChanged(window.id, isFullscreen: window.fullscreen != nil))
        }
        if focusedWindowID != old.focusedWindowID {
            let window = focusedWindow
            events.append(.windowFocused(window?.id, bundleID: window?.properties.appID ?? "", title: window?.properties.title ?? ""))
        }

        for window in old.sortedWindows where windows[window.id] == nil {
            events.append(.windowClosed(window.id))
        }
        for workspace in old.sortedWorkspaces where workspaces[workspace.id] == nil {
            events.append(.workspaceRemoved(workspace.id.name))
        }

        if mode != old.mode {
            events.append(.modeChanged(mode))
        }
        events += tabEvents(since: old)
        return events
    }

    private func tabEvents(since old: World) -> [Event] {
        var events: [Event] = []
        for group in groups.values.sorted(by: { $0.id < $1.id }) where old.groups[group.id] == nil {
            events.append(.tabsCreated(group.members))
        }
        for group in old.groups.values.sorted(by: { $0.id < $1.id }) where groups[group.id] == nil {
            events.append(.tabsDissolved(group.members))
        }
        for window in sortedWindows {
            let before = old.windows[window.id]?.group
            if let now = window.group, now != before, old.groups[now] != nil {
                events.append(.windowJoinedTabs(window.id))
            } else if let before, window.group != before, groups[before] != nil {
                events.append(.windowLeftTabs(window.id))
            }
        }
        return events
    }
}
