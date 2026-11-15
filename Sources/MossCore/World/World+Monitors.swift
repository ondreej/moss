extension World {
    /// Reconciles monitors with the displays currently connected.
    public mutating func updateDisplays(_ displays: [DisplayDescription]) {
        let connected = Set(displays.map(\.id))

        // Update known displays and add new ones.
        for display in displays.sorted(by: { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }) {
            if let index = monitorIndex(display.id) {
                monitors[index].name = display.name
                monitors[index].frame = display.frame
                monitors[index].visibleFrame = display.visibleFrame
                monitors[index].scale = display.scale
                monitors[index].isBuiltin = display.isBuiltin
                monitors[index].isMain = display.isMain
            } else {
                addMonitor(display)
            }
        }

        // Move workspaces off disconnected displays, remembering where they came from.
        let removed = monitors.filter { !connected.contains($0.id) }
        monitors.removeAll { !connected.contains($0.id) }
        sortMonitors()
        if let fallback = monitors.first {
            for monitor in removed {
                for id in workspaces.keys.sorted() where workspaces[id]?.monitor == monitor.id {
                    if workspaces[id]?.home == nil {
                        workspaces[id]?.home = Workspace.Home(monitor: monitor.id, name: monitor.name, wasActive: monitor.activeWorkspace == id)
                    }
                    moveFloatingWindows(of: id, from: monitor.frame, to: fallback)
                    workspaces[id]?.monitor = fallback.id
                }
                if focusedMonitorID == monitor.id { focusedMonitorID = nil }
            }
        }

        if focusedMonitorID == nil {
            focusedMonitorID = displays.first(where: \.isMain)?.id ?? monitors.first?.id
        }
        refreshMonitorReservations()
        for id in Array(workspaces.keys) { removeWorkspaceIfUnused(id) }
    }

    private mutating func addMonitor(_ display: DisplayDescription) {
        let returning = workspaces.values
            .filter { $0.home.map { $0.monitor == display.id || $0.name == display.name } ?? false }
            .sorted { $0.id < $1.id }
        let workspace = returning.first { $0.home?.wasActive == true }?.id ?? returning.first?.id ?? initialWorkspace(for: display)
        var monitor = Monitor(
            id: display.id,
            name: display.name,
            frame: display.frame,
            visibleFrame: display.visibleFrame,
            scale: display.scale,
            isBuiltin: display.isBuiltin,
            activeWorkspace: workspace
        )
        monitor.isMain = display.isMain
        monitor.reserved = reservedInsets(for: monitor)
        monitors.append(monitor)
        sortMonitors()
        for returned in returning { bringHome(returned.id, to: display.id) }
        if workspaces[workspace] == nil {
            createWorkspace(workspace, on: display.id)
        } else {
            workspaces[workspace]?.monitor = display.id
        }
        createPersistentWorkspaces()
    }

    /// Moves a workspace back to the monitor it was on before that monitor was disconnected.
    private mutating func bringHome(_ id: WorkspaceID, to monitorID: MonitorID) {
        guard let workspace = workspaces[id], let target = monitor(monitorID) else { return }
        let hostID = workspace.monitor
        if let host = monitor(hostID) { moveFloatingWindows(of: id, from: host.frame, to: target) }
        workspaces[id]?.monitor = monitorID
        workspaces[id]?.home = nil
        // The monitor that hosted it while it was away needs something else to show.
        if let hostIndex = monitorIndex(hostID), monitors[hostIndex].activeWorkspace == id {
            let replacement = previousWorkspaceByMonitor[hostID].flatMap { workspaces[$0]?.monitor == hostID ? $0 : nil }
                ?? sortedWorkspaces.first { $0.monitor == hostID && !$0.id.isScratchpad }?.id
                ?? firstFreeWorkspace()
            createWorkspace(replacement, on: hostID)
            monitors[hostIndex].activeWorkspace = replacement
        }
    }

    private mutating func moveFloatingWindows(of id: WorkspaceID, from source: Rect, to monitor: Monitor) {
        for window in workspaces[id]?.floating ?? [] {
            guard let frame = windows[window]?.floatingFrame else { continue }
            let relocated = relocate(frame, from: source, to: monitor)
            windows[window]?.floatingFrame = relocated
        }
    }

    private mutating func sortMonitors() {
        monitors.sort { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    /// Picks the workspace a newly connected display starts on: one bound to it with
    /// `default = true`, any workspace bound to it, or the lowest free workspace number.
    private func initialWorkspace(for display: DisplayDescription) -> WorkspaceID {
        let candidate = Monitor(id: display.id, name: display.name, frame: display.frame, isBuiltin: display.isBuiltin, activeWorkspace: .numbered(0))
        let bound = workspaceRules.filter { rule in
            rule.display.map { matches($0, candidate) } ?? false
        }
        if let rule = bound.first(where: \.isDefault) ?? bound.first, !isShownOnOtherMonitor(rule.workspace, than: display.id) {
            return rule.workspace
        }
        let taken = Set(monitors.map(\.activeWorkspace))
        var number = 1
        while taken.contains(.numbered(number)) || workspaces[.numbered(number)].map({ !$0.isEmpty }) == true || boundElsewhere(.numbered(number), than: candidate) {
            number += 1
        }
        return .numbered(number)
    }

    private func isShownOnOtherMonitor(_ workspace: WorkspaceID, than monitor: MonitorID) -> Bool {
        monitors.contains { $0.id != monitor && $0.activeWorkspace == workspace }
    }

    private func boundElsewhere(_ workspace: WorkspaceID, than monitor: Monitor) -> Bool {
        workspaceRules.contains { rule in
            rule.workspace == workspace && rule.display.map { !matches($0, monitor) } == true
        }
    }

    /// Whether a monitor selector written in a rule refers to `monitor`.
    func matches(_ selector: MonitorSelector, _ monitor: Monitor) -> Bool {
        switch selector {
        case .id(let id):
            return monitor.id == id || monitorIndex(monitor.id).map { $0 + 1 } == Int(id.rawValue)
        case .name(let name):
            return Self.monitor(monitor, matchesName: name)
        case .main:
            return monitor.isMain
        case .current, .direction, .relative:
            return false
        }
    }

    /// Whether a display is the one `query` names: `built-in`, `external`, or its name or part of it.
    static func monitor(_ monitor: Monitor, matchesName query: String) -> Bool {
        let name = monitor.name.lowercased(), needle = query.lowercased()
        switch needle {
        case "built-in", "builtin": return monitor.isBuiltin
        case "external": return !monitor.isBuiltin
        default: return name == needle || name.replacingSpaces == needle.replacingSpaces || name.contains(needle)
        }
    }

    /// Resolves a monitor selector relative to the focused monitor.
    public func resolve(_ selector: MonitorSelector) -> Monitor? {
        guard let current = focusedMonitor ?? monitors.first else { return nil }
        switch selector {
        case .current:
            return current
        case .direction(let direction):
            return monitor(from: current, toward: direction)
        case .relative(let delta):
            guard let index = monitorIndex(current.id) else { return nil }
            let count = monitors.count
            return monitors[((index + delta) % count + count) % count]
        case .id, .name, .main:
            return monitors.first { matches(selector, $0) }
        }
    }

    /// The nearest monitor in `direction`, preferring ones that overlap on the other axis.
    public func monitor(from origin: Monitor, toward direction: Direction) -> Monitor? {
        let frame = origin.frame
        let candidates = monitors.filter { other in
            guard other.id != origin.id else { return false }
            switch direction {
            case .left: return other.frame.midX < frame.minX || other.frame.maxX <= frame.minX + 1
            case .right: return other.frame.midX > frame.maxX || other.frame.minX >= frame.maxX - 1
            case .up: return other.frame.midY < frame.minY || other.frame.maxY <= frame.minY + 1
            case .down: return other.frame.midY > frame.maxY || other.frame.minY >= frame.maxY - 1
            }
        }
        func overlap(_ other: Monitor) -> Double {
            direction.axis == .horizontal
                ? min(frame.maxY, other.frame.maxY) - max(frame.minY, other.frame.minY)
                : min(frame.maxX, other.frame.maxX) - max(frame.minX, other.frame.minX)
        }
        return candidates.min { a, b in
            let (oa, ob) = (overlap(a) > 0, overlap(b) > 0)
            if oa != ob { return oa }
            return a.frame.center.distanceSquared(to: frame.center) < b.frame.center.distanceSquared(to: frame.center)
        }
    }

    mutating func refreshMonitorReservations() {
        for index in monitors.indices {
            monitors[index].reserved = reservedInsets(for: monitors[index])
        }
    }

    func reservedInsets(for monitor: Monitor) -> Insets {
        configuredReservation(for: monitor) + (overlayReservations[monitor.id] ?? .zero)
    }

    /// Space the configuration reserves at a monitor's edges, for a status bar for example.
    private func configuredReservation(for monitor: Monitor) -> Insets {
        var result = Insets.zero
        for reservation in monitorReservations where reservation.monitor.map({ matches($0, monitor) }) ?? true {
            result = reservation.insets
        }
        return result
    }

    /// Where Moss's own notices and bars go on a monitor: clear of the menu bar, the Dock
    /// and space reserved for a status bar, but not of those notices and bars themselves.
    public func overlayArea(on monitor: Monitor) -> Rect {
        monitor.visibleFrame.inset(by: configuredReservation(for: monitor))
    }

    /// Keeps windows clear of Moss's own overlays, replacing earlier overlay reservations.
    public mutating func reserveForOverlays(_ reservations: [MonitorID: Insets]) {
        guard reservations != overlayReservations else { return }
        overlayReservations = reservations
        refreshMonitorReservations()
    }
}

extension String {
    var replacingSpaces: String { replacing(" ", with: "") }
}

/// Space reserved at a monitor's edges, e.g. for a status bar, from `reserve` in a `[displays.NAME]` table.
public struct MonitorReservation: Hashable, Sendable {
    /// The monitor it applies to; `nil` applies to every monitor.
    public var monitor: MonitorSelector?
    public var insets: Insets

    public init(monitor: MonitorSelector?, insets: Insets) {
        self.monitor = monitor
        self.insets = insets
    }
}
