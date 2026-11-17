extension World {
    // MARK: - Fullscreen Spaces

    // A window in macOS fullscreen is in a Space of its own, outside every layout. It still
    // belongs to the workspace it left: the workspace counts it, and switching there goes to it
    // when it was the last window used there, or the workspace has no other. While it has
    // focus, its workspace is the one shown on its display.

    /// `id` went into macOS fullscreen. It leaves the layout, and keeps focus if it had it.
    public mutating func moveToFullscreenSpace(_ id: WindowID) {
        guard let window = windows[id] else { return }
        let hadFocus = focusedWindowID == id
        fullscreenSpaces[id] = window.workspace
        removeWindow(id)
        if hadFocus { focusFullscreenSpace(id) }
    }

    /// `id` left its fullscreen Space, or closed there. Returns the workspace it belongs to.
    @discardableResult
    public mutating func removeFullscreenSpace(_ id: WindowID) -> WorkspaceID? {
        guard let workspace = fullscreenSpaces.removeValue(forKey: id) else { return nil }
        if workspaces[workspace]?.lastFocused == id { workspaces[workspace]?.lastFocused = nil }
        if focusedFullscreenSpace == id {
            focusedFullscreenSpace = nil
            if isVisible(workspace) { restoreFocus(on: workspace) }
        }
        removeWorkspaceIfUnused(workspace)
        return workspace
    }

    /// Moves a window in a fullscreen Space to another workspace. It stays in its Space, which
    /// that workspace now leads to. Following it, focus stays in the Space; otherwise it goes
    /// back to the workspace the window left, and the desktop comes back.
    mutating func moveFullscreenSpace(_ id: WindowID, to selector: WorkspaceSelector, follow: Bool) throws(ActionError) {
        let target = try resolve(selector)
        guard let source = fullscreenSpaces[id], source != target else { return }
        if workspaces[target] == nil {
            guard let monitor = boundMonitor(for: target) ?? focusedMonitorID ?? workspaces[source]?.monitor else { return }
            createWorkspace(target, on: monitor)
        }
        fullscreenSpaces[id] = target
        if workspaces[source]?.lastFocused == id { workspaces[source]?.lastFocused = nil }
        // Switching to the workspace leads to it.
        workspaces[target]?.lastFocused = id
        if follow {
            activate(target, preferredMonitor: focusedMonitorID, focus: false)
            focusFullscreenSpace(id)
        } else if focusedFullscreenSpace == id {
            focusedFullscreenSpace = nil
            restoreFocus(on: source)
        }
        removeWorkspaceIfUnused(source)
    }

    /// Gives focus to the window in a fullscreen Space, showing its workspace.
    mutating func focusFullscreenSpace(_ id: WindowID) {
        guard let workspace = fullscreenSpaces[id], let monitor = workspaces[workspace]?.monitor else { return }
        if !isVisible(workspace) { activate(workspace, focus: false) }
        focusedWindowID = nil
        focusedFullscreenSpace = id
        focusedMonitorID = monitor
        workspaces[workspace]?.lastFocused = id
    }

    /// The window in a fullscreen Space that showing `workspace` gives focus to, if any.
    func fullscreenSpaceToFocus(on workspace: WorkspaceID) -> WindowID? {
        guard let ws = workspaces[workspace] else { return nil }
        if let last = ws.lastFocused, fullscreenSpaces[last] == workspace { return last }
        guard ws.isEmpty else { return nil }
        return fullscreenSpaces.filter { $0.value == workspace }.keys.min()
    }
}
