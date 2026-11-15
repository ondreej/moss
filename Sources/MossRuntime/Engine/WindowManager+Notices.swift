import MossConfig
import MossCore
import Foundation
import os

/// Notices, and the error bar that lists problems in the configuration.
extension WindowManager {
    /// Shows a notice on the focused monitor.
    func post(_ notice: Notice) {
        guard let monitor = world.focusedMonitor ?? world.monitors.first else { return }
        notices.post(notice, within: world.overlayArea(on: monitor))
    }

    /// After the focused monitor switched workspaces, shows where the user is (`workspaces.show-name`).
    func showWorkspaceSwitch(from before: World) {
        guard hasStarted, world.settings.workspaces.showsName, let monitor = world.focusedMonitor,
              let previous = before.monitor(monitor.id), previous.activeWorkspace != monitor.activeWorkspace,
              world.workspaces[monitor.activeWorkspace] != nil else { return }
        let items = world.sortedWorkspaces
            .filter { $0.monitor == monitor.id && !$0.id.isScratchpad }
            .map { WorkspaceHUD.Item(name: world.displayName(of: $0.id), windows: world.windowCount(on: $0.id), isActive: $0.id == monitor.activeWorkspace) }
        notices.showWorkspaces(WorkspaceHUD(items: items), within: world.overlayArea(on: monitor))
    }

    func dismissNotices(oldest count: Int?) {
        notices.dismiss(oldest: count)
    }

    func setError(_ bar: ErrorBar?) {
        let before = world
        customError = bar
        updateErrorBar()
        commit(from: before)
    }

    /// Shows the message set with `moss error`, or else the configuration's errors, on
    /// the main display.
    func updateErrorBar() {
        var bar = customError
        if bar == nil, world.settings.errors.isShown, !configuration.errors.isEmpty {
            bar = ErrorBar(lines: errorLines(limit: 5))
        }
        let main = world.monitors.first { $0.frame.origin == .zero } ?? world.monitors.first
        guard let bar, let main else {
            world.reserveForOverlays([:])
            if appliedErrorBar != nil { notices.showErrorBar(nil, within: .zero) }
            appliedErrorBar = nil
            return
        }
        // Windows make room for the bar.
        world.reserveForOverlays([main.id: bar.reservation])
        let area = world.overlayArea(on: main)
        if let applied = appliedErrorBar, applied.bar == bar, applied.area == area { return }
        appliedErrorBar = (bar, area)
        notices.showErrorBar(bar, within: area)
    }

    /// The configuration's errors, those over `limit` summarised.
    private func errorLines(limit: Int) -> [String] {
        let errors = configuration.errors
        let shown = max(1, limit)
        var lines = errors.prefix(shown).map { error -> String in
            guard let file = error.location.file else { return error.message }
            return "\(file.lastPathComponent), line \(error.location.line + 1): \(error.message)"
        }
        if errors.count > shown { lines.append("(\(errors.count - shown) more…)") }
        return lines
    }
}
