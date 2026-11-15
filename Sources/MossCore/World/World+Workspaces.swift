extension World {
    /// Applies a (re)loaded configuration.
    public mutating func configure(
        settings: Settings,
        windowRules: [WindowRule] = [],
        workspaceRules: [WorkspaceRule] = [],
        monitorReservations: [MonitorReservation] = [],
        modes: Set<String> = []
    ) {
        self.settings = settings
        self.modes = modes
        if let mode, !modes.contains(mode) { self.mode = nil }
        self.windowRules = windowRules
        self.workspaceRules = workspaceRules
        self.monitorReservations = monitorReservations
        refreshMonitorReservations()

        for id in Array(workspaces.keys) {
            let effective = self.settings(for: id)
            let area = layoutArea(for: id)
            let persistent = isPersistent(id)
            workspaces[id]?.switchLayout(to: effective.layout.style, area: area, settings: effective)
            workspaces[id]?.isPersistent = persistent
        }
        createPersistentWorkspaces()
        for id in Array(workspaces.keys) { removeWorkspaceIfUnused(id) }
        refreshDynamicRules(force: true)
    }

    func isPersistent(_ workspace: WorkspaceID) -> Bool {
        workspaceRules.contains { $0.workspace == workspace && $0.isPersistent }
    }

    /// The monitor a workspace rule binds the workspace to, if connected.
    func boundMonitor(for workspace: WorkspaceID) -> MonitorID? {
        for rule in workspaceRules where rule.workspace == workspace {
            if let selector = rule.display, let monitor = monitors.first(where: { matches(selector, $0) }) {
                return monitor.id
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    mutating func createWorkspace(_ id: WorkspaceID, on monitor: MonitorID) {
        guard workspaces[id] == nil else { return }
        var workspace = Workspace(id: id, monitor: monitor, layout: settings(for: id).layout.style)
        workspace.isPersistent = isPersistent(id)
        workspaces[id] = workspace
    }

    mutating func createPersistentWorkspaces() {
        guard let fallback = focusedMonitorID ?? monitors.first?.id else { return }
        for rule in workspaceRules where rule.isPersistent && workspaces[rule.workspace] == nil {
            createWorkspace(rule.workspace, on: boundMonitor(for: rule.workspace) ?? fallback)
        }
    }

    /// Destroys a workspace that is empty, hidden and not persistent.
    mutating func removeWorkspaceIfUnused(_ id: WorkspaceID) {
        guard let workspace = workspaces[id], workspace.isEmpty, !workspace.isPersistent, !isVisible(id) else { return }
        workspaces[id] = nil
        for monitor in monitors.indices where monitors[monitor].activeScratchpad == id {
            monitors[monitor].activeScratchpad = nil
        }
    }

    // MARK: - Selection

    /// Resolves a workspace selector to a concrete workspace, which may not exist yet.
    public func resolve(_ selector: WorkspaceSelector) throws(ActionError) -> WorkspaceID {
        let monitor = focusedMonitor
        let current = monitor?.activeWorkspace
        let currentNumber = current?.number ?? 1

        switch selector {
        case .id(let number):
            guard number >= 1 else { throw .invalidArgument("workspace numbers start at 1") }
            return .numbered(number)
        case .named(let name):
            return .named(name)
        case .scratchpad(let name):
            return .scratchpad(name)
        case .relative(let delta):
            return .numbered(max(1, currentNumber + delta))
        case .adjacent(let delta):
            let candidates = sortedWorkspaces.filter { !$0.id.isScratchpad && $0.monitor == monitor?.id }.map(\.id)
            return cycle(candidates, from: current, by: delta) ?? current ?? .numbered(1)
        case .empty:
            var number = 1
            while let existing = workspaces[.numbered(number)], !existing.isEmpty { number += 1 }
            return .numbered(number)
        case .last:
            guard let previous = previousWorkspace else { throw .noSuchWorkspace("last") }
            return previous
        }
    }

    private func cycle(_ candidates: [WorkspaceID], from current: WorkspaceID?, by delta: Int) -> WorkspaceID? {
        guard !candidates.isEmpty else { return nil }
        let index = current.flatMap(candidates.firstIndex(of:)) ?? 0
        let count = candidates.count
        return candidates[((index + delta) % count + count) % count]
    }

    // MARK: - Switching

    /// Shows `target` and focuses it. Existing workspaces are shown on their own monitor;
    /// new ones are created on their bound monitor or on `preferredMonitor`.
    mutating func activate(_ target: WorkspaceID, preferredMonitor: MonitorID? = nil, focus: Bool = true) {
        guard !target.isScratchpad else {
            showScratchpad(target, on: preferredMonitor ?? focusedMonitorID)
            return
        }
        guard let monitorID = workspaces[target]?.monitor ?? boundMonitor(for: target) ?? preferredMonitor ?? focusedMonitorID,
              let monitorIndex = monitorIndex(monitorID) else { return }

        let previouslyFocused = activeWorkspaceID
        createWorkspace(target, on: monitorID)

        let old = monitors[monitorIndex].activeWorkspace
        if old != target {
            previousWorkspaceByMonitor[monitorID] = old
            monitors[monitorIndex].activeWorkspace = target
            movePinnedWindows(from: old, to: target)
            if settings.scratchpads.hidesOnWorkspaceSwitch {
                monitors[monitorIndex].activeScratchpad = nil
            }
            removeWorkspaceIfUnused(old)
            for id in Array(workspaces.keys) where id.isScratchpad { removeWorkspaceIfUnused(id) }
        }

        if focus {
            focusedMonitorID = monitorID
            restoreFocus(on: monitors[monitorIndex].activeScratchpad ?? target)
        }
        if let previouslyFocused, activeWorkspaceID != previouslyFocused {
            previousWorkspace = previouslyFocused
        }
    }

    /// Moves `workspace` onto `monitor`, showing it there.
    mutating func move(workspace id: WorkspaceID, to monitorID: MonitorID) {
        guard var workspace = workspaces[id], workspace.monitor != monitorID, let targetIndex = monitorIndex(monitorID) else { return }
        let sourceID = workspace.monitor
        workspace.monitor = monitorID
        workspaces[id] = workspace

        if let sourceIndex = monitorIndex(sourceID), monitors[sourceIndex].activeWorkspace == id {
            // The source monitor needs something else to show.
            let replacement = sortedWorkspaces.first { $0.monitor == sourceID && $0.id != id && !$0.id.isScratchpad }?.id
                ?? firstFreeWorkspace()
            createWorkspace(replacement, on: sourceID)
            monitors[sourceIndex].activeWorkspace = replacement
        }
        let previous = monitors[targetIndex].activeWorkspace
        monitors[targetIndex].activeWorkspace = id
        previousWorkspaceByMonitor[monitorID] = previous
        removeWorkspaceIfUnused(previous)
    }

    func firstFreeWorkspace() -> WorkspaceID {
        var number = 1
        while workspaces[.numbered(number)] != nil { number += 1 }
        return .numbered(number)
    }

    private mutating func movePinnedWindows(from old: WorkspaceID, to new: WorkspaceID) {
        guard let pinned = workspaces[old]?.floating.filter({ windows[$0]?.isPinned == true }), !pinned.isEmpty else { return }
        workspaces[old]?.floating.removeAll { pinned.contains($0) }
        workspaces[new]?.floating.append(contentsOf: pinned)
        for window in pinned { windows[window]?.workspace = new }
    }

    // MARK: - Scratchpads

    mutating func toggleScratchpad(_ name: String) {
        let id = WorkspaceID.scratchpad(name)
        guard let monitorID = focusedMonitorID, let index = monitorIndex(monitorID) else { return }
        if monitors[index].activeScratchpad == id {
            hideScratchpad(on: monitorID)
        } else {
            showScratchpad(id, on: monitorID)
        }
    }

    mutating func showScratchpad(_ id: WorkspaceID, on monitorID: MonitorID?) {
        guard let monitorID, let index = monitorIndex(monitorID) else { return }
        // A scratchpad is shown on one monitor at a time.
        for other in monitors.indices where monitors[other].activeScratchpad == id {
            monitors[other].activeScratchpad = nil
        }
        createWorkspace(id, on: monitorID)
        workspaces[id]?.monitor = monitorID
        let previous = monitors[index].activeScratchpad
        monitors[index].activeScratchpad = id
        if let previous, previous != id { removeWorkspaceIfUnused(previous) }
        focusedMonitorID = monitorID
        restoreFocus(on: id)
    }

    mutating func hideScratchpad(on monitorID: MonitorID) {
        guard let index = monitorIndex(monitorID), let special = monitors[index].activeScratchpad else { return }
        monitors[index].activeScratchpad = nil
        removeWorkspaceIfUnused(special)
        if focusedMonitorID == monitorID {
            restoreFocus(on: monitors[index].activeWorkspace)
        }
    }

    /// Hides a visible scratchpad that has just become empty.
    mutating func closeScratchpadIfEmpty(_ id: WorkspaceID) {
        guard id.isScratchpad, workspaces[id]?.isEmpty == true,
              let monitor = monitors.first(where: { $0.activeScratchpad == id }) else { return }
        hideScratchpad(on: monitor.id)
    }

    // MARK: - Renaming

    mutating func rename(workspaceNumber number: Int, to name: String?) {
        // The workspace keeps its number; the name is only shown.
        workspaceLabels[.numbered(number)] = name
    }
}
