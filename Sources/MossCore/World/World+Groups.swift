extension World {
    /// The group a window belongs to.
    public func group(of window: WindowID) -> WindowGroup? {
        windows[window]?.group.flatMap { groups[$0] }
    }

    /// Whether the window is a group member waiting behind the active one.
    public func isStashed(_ window: WindowID) -> Bool {
        guard let group = group(of: window) else { return false }
        return group.active != window
    }

    /// Whether a window may become or join a tab group (a rule can keep it out with `tabs = "never"`).
    func mayJoinGroups(_ window: WindowID) -> Bool { windows[window]?.isDeniedFromGroups == false }

    // MARK: - Creating and dissolving

    /// `tabs`: puts the window into a new tab group, or dissolves the group it is in.
    mutating func toggleTabs(_ window: WindowID) {
        guard windows[window] != nil else { return }
        if let id = windows[window]?.group {
            dissolveGroup(id)
            return
        }
        let id = GroupID(nextGroupID)
        nextGroupID += 1
        groups[id] = WindowGroup(id: id, members: [window], active: window)
        windows[window]?.group = id
    }

    /// Turns every member of a group back into a window of its own, next to the active one.
    mutating func dissolveGroup(_ id: GroupID) {
        guard let group = groups[id] else { return }
        groups[id] = nil
        for member in group.members { windows[member]?.group = nil }
        for member in group.members where member != group.active {
            place(member, besides: group.active, direction: nil)
        }
    }

    // MARK: - Membership

    /// Makes `window`, a member of a group, the one shown in the group's place.
    mutating func activateGroupMember(_ window: WindowID) {
        guard let id = windows[window]?.group, var group = groups[id], group.active != window,
              let previous = windows[group.active] else { return }
        let workspace = previous.workspace
        windows[window]?.workspace = workspace
        if previous.isFloating {
            if let index = workspaces[workspace]?.floating.firstIndex(of: previous.id) {
                workspaces[workspace]?.floating[index] = window
            }
            windows[window]?.isFloating = true
            windows[window]?.floatingFrame = previous.floatingFrame
        } else {
            workspaces[workspace]?.tiling.replace(previous.id, with: window)
            windows[window]?.isFloating = false
        }
        if workspaces[workspace]?.fullscreenWindow == previous.id {
            workspaces[workspace]?.fullscreenWindow = window
            windows[window]?.fullscreen = previous.fullscreen
            windows[previous.id]?.fullscreen = nil
        }
        if workspaces[workspace]?.lastFocused == previous.id {
            workspaces[workspace]?.lastFocused = window
        }
        group.active = window
        groups[id] = group
    }

    /// Moves `window` into a group, where it becomes the active member.
    mutating func addToGroup(_ window: WindowID, group id: GroupID) {
        guard var group = groups[id], windows[window]?.group == nil, let active = windows[group.active] else { return }
        let source = windows[window]?.workspace
        detach(window)
        windows[window]?.workspace = active.workspace
        windows[window]?.isPinned = false
        group.members.insert(window, at: group.activeIndex + 1)
        groups[id] = group
        windows[window]?.group = id
        activateGroupMember(window)
        if let source, source != active.workspace {
            closeScratchpadIfEmpty(source)
            removeWorkspaceIfUnused(source)
        }
    }

    /// Takes `window` out of its group and gives it its own place next to the group.
    mutating func removeFromGroup(_ window: WindowID, direction: Direction? = nil) {
        guard let id = windows[window]?.group, var group = groups[id] else { return }
        guard group.members.count > 1 else {
            groups[id] = nil
            windows[window]?.group = nil
            return
        }
        if group.active == window {
            activateGroupMember(group.member(offsetFromActive: 1))
            group = groups[id]!
        }
        group.members.removeAll { $0 == window }
        groups[id] = group
        windows[window]?.group = nil
        place(window, besides: group.active, direction: direction)
    }

    /// Forgets a window that is going away, keeping its group's place in the layout.
    mutating func leaveGroup(_ window: WindowID) {
        guard let id = windows[window]?.group, var group = groups[id] else { return }
        if group.active == window && group.members.count > 1 {
            activateGroupMember(group.member(offsetFromActive: 1))
            group = groups[id]!
        }
        group.members.removeAll { $0 == window }
        windows[window]?.group = nil
        groups[id] = group.members.isEmpty ? nil : group
    }

    /// Lays out a window that is not part of any layout next to `neighbor`.
    private mutating func place(_ window: WindowID, besides neighbor: WindowID, direction: Direction?) {
        guard let anchor = windows[neighbor] else { return }
        windows[window]?.workspace = anchor.workspace
        if anchor.isFloating {
            windows[window]?.isFloating = true
            var frame = anchor.floatingFrame
            frame.origin = frame.origin + Point(x: 30, y: 30)
            windows[window]?.floatingFrame = frame
            workspaces[anchor.workspace]?.floating.append(window)
        } else {
            windows[window]?.isFloating = false
            insertTiled(window, into: anchor.workspace, target: neighbor, direction: direction)
        }
    }

    // MARK: - Actions

    mutating func switchTab(_ target: Action.TabTarget) {
        guard let focused = focusedWindowID, let group = group(of: focused), group.members.count > 1 else { return }
        let next: WindowID
        switch target {
        case .next: next = group.member(offsetFromActive: 1)
        case .previous: next = group.member(offsetFromActive: -1)
        case .index(let index):
            guard group.members.indices.contains(index - 1) else { return }
            next = group.members[index - 1]
        }
        activateGroupMember(next)
        setFocus(next)
    }

    mutating func moveGroupWindow(forward: Bool) {
        guard let focused = focusedWindowID, let id = windows[focused]?.group, var group = groups[id], group.members.count > 1 else { return }
        let index = group.activeIndex
        let target = (index + (forward ? 1 : -1) + group.members.count) % group.members.count
        group.members.swapAt(index, target)
        groups[id] = group
    }

    mutating func moveIntoGroup(_ direction: Direction) {
        guard let focused = focusedWindowID, windows[focused]?.group == nil, mayJoinGroups(focused),
              let neighbor = window(in: direction, from: focused),
              let target = group(of: neighbor) else { return }
        addToGroup(focused, group: target.id)
        setFocus(focused)
    }

    mutating func moveOutOfGroup(_ window: WindowID, direction: Direction? = nil) {
        guard group(of: window) != nil else { return }
        removeFromGroup(window, direction: direction)
        setFocus(window)
    }
}
