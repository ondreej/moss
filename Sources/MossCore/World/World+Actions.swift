extension World {
    /// Performs an action, returning the side effects the runtime must carry out.
    @discardableResult
    public mutating func perform(_ action: Action) throws(ActionError) -> [Effect] {
        let focusBefore = focusedWindowID
        let monitorBefore = focusedMonitorID
        let workspacesBefore = Set(workspaces.keys)
        var effects: [Effect] = []

        switch action {
        case .run(let text):
            effects += try run(text)
        case .close(let selector):
            effects.append(.close(try targetWindow(selector)))
        case .quitApp(let selector):
            if let window = windows[try targetWindow(selector)] { effects.append(.quit(pid: window.properties.pid)) }
        case .signal(let number, let selector):
            if let window = windows[try targetWindow(selector)] { effects.append(.signal(pid: window.properties.pid, number)) }
        case .sendKeys(let chord, let selector):
            effects.append(.sendKeys(chord, pid: try keyRecipient(selector)))

        case .workspace(let selector):
            try switchWorkspace(selector)
        case .moveToWorkspace(let selector, let windowSelector, let follow):
            try moveToWorkspace(try targetWindow(windowSelector), selector, follow: follow)
        case .bringWorkspace(let selector):
            let target = try resolve(selector)
            guard let monitor = focusedMonitorID else { break }
            if target.isScratchpad {
                showScratchpad(target, on: monitor)
            } else {
                if workspaces[target] != nil { move(workspace: target, to: monitor) }
                activate(target, preferredMonitor: monitor)
            }
        case .renameWorkspace(let number, let name):
            guard workspaces[.numbered(number)] != nil else { throw .noSuchWorkspace(String(number)) }
            rename(workspaceNumber: number, to: name)
        case .scratchpad(let name):
            toggleScratchpad(name ?? WorkspaceID.defaultScratchpadName)

        case .float(let change, let selector):
            let window = try targetWindow(selector)
            setFloating(window, change.apply(to: windows[window]?.isFloating ?? false))
        case .fullscreen(let change):
            try changeFullscreen(.fullscreen, change)
        case .maximize(let change):
            try changeFullscreen(.maximized, change)
        case .keepSize(let change, let selector):
            let window = try targetWindow(selector)
            let keepsSize = windows[window]?.keepsSize ?? false
            windows[window]?.keepsSize = change.apply(to: keepsSize)
        case .pin(let change, let selector):
            let window = try targetWindow(selector)
            guard let state = windows[window], state.isFloating else { break }
            windows[window]?.isPinned = change.apply(to: state.isPinned)
        case .center:
            let window = try requireFocusedWindow()
            guard let state = windows[window], state.isFloating, let monitor = monitor(of: window) else { break }
            windows[window]?.floatingFrame = monitor.usableFrame.centered(state.floatingFrame.size).integral
        case .tag(let change, let selector):
            let window = try targetWindow(selector)
            if var tags = windows[window]?.tags, let present = windows[window]?.allTags {
                change.apply(to: &tags, present: present)
                windows[window]?.tags = tags
            }
        case .bringToFront:
            let window = try requireFocusedWindow()
            guard let workspace = windows[window]?.workspace, workspaces[workspace]?.floating.contains(window) == true else { break }
            workspaces[workspace]?.floating.removeAll { $0 == window }
            workspaces[workspace]?.floating.append(window)

        case .focus(let direction):
            moveFocus(direction)
        case .focusLast:
            if let last = focusHistory.first(where: { $0 != focusedWindowID }) { focus(last) }
        case .focusWindow(let selector):
            focus(try findWindow(selector))
        case .cycle(let options):
            if let next = cycleTarget(options) { focus(next) }
        case .move(let direction):
            try moveWindow(direction)
        case .moveToDisplay(let selector):
            guard let monitor = resolve(selector) else { throw .noSuchMonitor(selector.description) }
            moveWindow(try requireFocusedWindow(), toMonitor: monitor.id)
        case .swap(let direction):
            let window = try requireFocusedWindow()
            if let other = self.window(in: direction, from: window) { swap(window, other) }
        case .swapInOrder(let forward):
            let options = Action.CycleOptions(previous: !forward, tiledOnly: focusedWindow?.isTiled == true)
            if let current = focusedWindowID, let next = cycleTarget(options) { swap(current, next) }

        case .resize(let parameter):
            resize(try requireFocusedWindow(), parameter)
        case .position(let parameter):
            reposition(try requireFocusedWindow(), parameter)
        case .splitRatio(let change):
            let window = try requireFocusedWindow()
            guard let workspace = windows[window]?.workspace, windows[window]?.isTiled == true else { break }
            let (area, effective) = (layoutArea(for: workspace), settings(for: workspace))
            workspaces[workspace]?.tiling.alterSplitRatio(window, change, area: area, settings: effective)
        case .useLayout(let choice):
            useLayout(choice)
        case .layout(let message):
            try sendLayoutMessage(message)

        case .focusDisplay(let selector):
            guard let monitor = resolve(selector) else { throw .noSuchMonitor(selector.description) }
            focusMonitor(monitor.id)
        case .moveWorkspaceToDisplay(let monitorSelector, let workspaceSelector):
            guard let monitor = resolve(monitorSelector) else { throw .noSuchMonitor(monitorSelector.description) }
            guard let workspace = try workspaceSelector.map(resolve) ?? activeWorkspaceID else { break }
            guard workspaces[workspace] != nil else { throw .noSuchWorkspace(workspaceSelector?.description ?? workspace.name) }
            let wasActive = workspace == activeWorkspaceID
            move(workspace: workspace, to: monitor.id)
            if wasActive {
                focusedMonitorID = monitor.id
                restoreFocus(on: workspace)
            }
        case .swapWorkspaces(let first, let second):
            guard let a = resolve(first) else { throw .noSuchMonitor(first.description) }
            guard let b = resolve(second) else { throw .noSuchMonitor(second.description) }
            swapActiveWorkspaces(a.id, b.id)

        case .tabs:
            let window = try requireFocusedWindow()
            if windows[window]?.group != nil || mayJoinGroups(window) { toggleTabs(window) }
        case .tab(let target):
            switchTab(target)
        case .joinTabs(let direction):
            moveIntoGroup(direction)
        case .leaveTabs:
            moveOutOfGroup(try requireFocusedWindow())
        case .moveTab(let forward):
            moveGroupWindow(forward: forward)

        case .mode(let name):
            if let name, !modes.contains(name) { throw .noSuchMode(name) }
            mode = name
        case .emit(let text):
            effects.append(.emit(.custom(text)))
        case .show(let surface):
            effects.append(.show(surface))
        case .pause(let change):
            effects.append(.pause(change))
        case .reload:
            effects.append(.reload)
        case .quit:
            effects.append(.quitMoss)
        }

        // Opening a workspace that had no windows runs its `when-empty` command.
        for id in workspaces.keys.sorted() where !workspacesBefore.contains(id) && workspaces[id]?.isEmpty == true && isVisible(id) {
            if let command = workspaceRules.last(where: { $0.workspace == id && $0.whenEmpty != nil })?.whenEmpty {
                effects += try run(command)
            }
        }
        refreshDynamicRules()
        if let warp = cursorWarp(after: action, focusBefore: focusBefore, monitorBefore: monitorBefore) {
            effects.append(.warpCursor(warp))
        }
        return effects
    }

    private mutating func changeFullscreen(_ mode: FullscreenMode, _ change: Action.Switch) throws(ActionError) {
        let window = try requireFocusedWindow()
        let isOn = windows[window]?.fullscreen == mode
        setFullscreen(window, change.apply(to: isOn) ? mode : nil)
    }

    // MARK: - Helpers

    /// The application a command opens with `open -a NAME` (or a quoted name), if it names one.
    static func applicationName(in command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard words.first == "open", let flag = words.firstIndex(where: { ["-a", "-na", "-an"].contains($0) }),
              flag + 1 < words.count else { return nil }
        let rest = Array(words[(flag + 1)...])
        var name = [rest[0]]
        if let quote = rest[0].first, quote == "\"" || quote == "'", !(rest[0].count > 1 && rest[0].hasSuffix(String(quote))) {
            for word in rest.dropFirst() {
                name.append(word)
                if word.hasSuffix(String(quote)) { break }
            }
        }
        let joined = name.joined(separator: " ").filter { $0 != "\"" && $0 != "'" }
        return joined.isEmpty ? nil : joined
    }

    /// Drops rules queued by a `run` whose window never appeared.
    public mutating func expireRunRules(_ token: Int) {
        pendingRunRules.removeAll { $0.token == token }
    }

    func requireFocusedWindow() throws(ActionError) -> WindowID {
        guard let window = focusedWindowID else { throw .noSuchWindow("focused") }
        return window
    }

    /// Runs a command, queuing the window rules of its `[rules]` prefix for the window it opens.
    private mutating func run(_ text: String) throws(ActionError) -> [Effect] {
        let (rules, command) = try Action.splitRunRules(text)
        guard !rules.isEmpty else { return [.run(command)] }
        let token = nextRunToken
        nextRunToken += 1
        pendingRunRules.append(PendingRunRules(token: token, effects: rules, application: Self.applicationName(in: command)))
        return [.expireRunRules(token: token), .run(command)]
    }

    /// The process that receives sent keys: the selected window's, else the focused one's.
    private func keyRecipient(_ selector: WindowSelector?) throws(ActionError) -> Int32? {
        if let selector { return windows[try findWindow(selector)]?.properties.pid }
        return focusedWindow?.properties.pid
    }

    func targetWindow(_ selector: WindowSelector?) throws(ActionError) -> WindowID {
        if let selector { return try findWindow(selector) }
        return try requireFocusedWindow()
    }

    /// The best window matching `selector`: the focused one if it matches, else the most recently focused.
    public func findWindow(_ selector: WindowSelector) throws(ActionError) -> WindowID {
        let matches = windows.values.filter { selector.matches($0, focusedWindow: focusedWindowID) }
        guard let best = matches.max(by: { ($0.focusStamp, $1.id) < ($1.focusStamp, $0.id) }) else {
            throw .noSuchWindow(selector.description)
        }
        return best.id
    }

    private mutating func switchWorkspace(_ selector: WorkspaceSelector) throws(ActionError) {
        var target = try resolve(selector)
        if target.isScratchpad {
            if case .scratchpad(let name) = target { toggleScratchpad(name) }
            return
        }
        if target == activeWorkspaceID {
            if focusedWindowID == nil, focusedFullscreenSpace == nil, let space = fullscreenSpaceToFocus(on: target) {
                // Back to the window in a fullscreen Space from its workspace.
                focusFullscreenSpace(space)
                return
            }
            guard settings.workspaces.backAndForth, let previous = previousWorkspace else { return }
            target = previous
        }
        activate(target, preferredMonitor: focusedMonitorID)
    }

    private mutating func moveToWorkspace(_ window: WindowID, _ selector: WorkspaceSelector, follow: Bool) throws(ActionError) {
        let target = try resolve(selector)
        guard let source = windows[window]?.workspace, source != target else { return }
        let wasFocused = focusedWindowID == window
        moveWindow(window, to: target)

        if !follow {
            if wasFocused {
                focusedWindowID = nil
                restoreFocus(on: source)
                if focusedWindowID == nil { restoreFocus(on: focusedMonitor?.activeWorkspace ?? source) }
            }
        } else if target.isScratchpad {
            showScratchpad(target, on: focusedMonitorID)
            setFocus(window)
        } else {
            activate(target, preferredMonitor: focusedMonitorID, focus: false)
            setFocus(window)
        }
        removeWorkspaceIfUnused(source)
    }

    private mutating func moveWindow(_ direction: Direction) throws(ActionError) {
        let window = try requireFocusedWindow()
        guard let state = windows[window] else { return }
        if state.isFloating {
            moveFloatingToEdge(window, direction)
            return
        }
        let boxes = navigableBoxes(scratchpad: state.workspace.isScratchpad, scrolledFrom: state.workspace)
        guard let box = boxes[window] else { return }
        let focal = switch direction {
        case .left: Point(x: box.minX - 1, y: box.midY)
        case .right: Point(x: box.maxX + 1, y: box.midY)
        case .up: Point(x: box.midX, y: box.minY - 1)
        case .down: Point(x: box.midX, y: box.maxY + 1)
        }

        let area = layoutArea(for: state.workspace), workspaceSettings = settings(for: state.workspace)
        guard let neighbor = self.window(in: direction, from: window) else {
            // Some layouts can still move a window with nothing beside it, such as out of a
            // shared column in the scrolling layout.
            let context = MoveContext(neighbor: nil, focalPoint: focal, area: area, settings: workspaceSettings)
            if workspaces[state.workspace]?.tiling.move(window, direction, context: context) == true {
                reveal(window)
                return
            }
            if settings.focus.crossesDisplays, let origin = monitor(of: window), let next = monitor(from: origin, toward: direction) {
                moveWindow(window, toMonitor: next.id)
            }
            return
        }

        let neighborWorkspace = windows[neighbor]!.workspace
        if neighborWorkspace != state.workspace {
            moveWindow(window, to: neighborWorkspace, focalPoint: focal)
            setFocus(window)
            return
        }
        let context = MoveContext(neighbor: neighbor, focalPoint: focal, area: area, settings: workspaceSettings)
        _ = workspaces[state.workspace]?.tiling.move(window, direction, context: context)
        reveal(window)
    }

    private mutating func moveWindow(_ window: WindowID, toMonitor monitorID: MonitorID) {
        guard let monitor = monitor(monitorID), let source = windows[window]?.workspace else { return }
        let target = monitor.activeWorkspace
        guard target != source else { return }
        moveWindow(window, to: target)
        setFocus(window)
    }

    private mutating func moveFloatingToEdge(_ window: WindowID, _ direction: Direction) {
        guard let state = windows[window], let monitor = monitor(of: window) else { return }
        let area = monitor.usableFrame
        let border = borderSize(of: state)
        var frame = state.floatingFrame
        switch direction {
        case .left: frame.origin.x = area.minX + border
        case .right: frame.origin.x = area.maxX - frame.width - border
        case .up: frame.origin.y = area.minY + border
        case .down: frame.origin.y = area.maxY - frame.height - border
        }
        windows[window]?.floatingFrame = frame
    }

    /// Swaps two windows' positions, across workspaces if necessary.
    private mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let first = windows[a], let second = windows[b], a != b else { return }
        if first.workspace == second.workspace {
            if first.isTiled && second.isTiled {
                workspaces[first.workspace]?.tiling.swap(a, b)
            } else if first.isFloating && second.isFloating {
                windows[a]?.floatingFrame = second.floatingFrame
                windows[b]?.floatingFrame = first.floatingFrame
            }
            return
        }
        guard first.isTiled && second.isTiled else { return }
        let boxes = navigableBoxes(scratchpad: first.workspace.isScratchpad, scrolledFrom: first.workspace)
        let (pointA, pointB) = (boxes[a]?.center, boxes[b]?.center)
        detach(a)
        detach(b)
        windows[a]?.workspace = second.workspace
        windows[b]?.workspace = first.workspace
        insertTiled(a, into: second.workspace, focalPoint: pointB)
        insertTiled(b, into: first.workspace, focalPoint: pointA)
        setFocus(a)
    }

    private mutating func swapActiveWorkspaces(_ a: MonitorID, _ b: MonitorID) {
        guard a != b, let i = monitorIndex(a), let j = monitorIndex(b) else { return }
        let (wsA, wsB) = (monitors[i].activeWorkspace, monitors[j].activeWorkspace)
        workspaces[wsA]?.monitor = b
        workspaces[wsB]?.monitor = a
        monitors[i].activeWorkspace = wsB
        monitors[j].activeWorkspace = wsA
        if let focused = focusedWindowID { setFocus(focused) }
    }

    private func cycleTarget(_ options: Action.CycleOptions) -> WindowID? {
        guard let workspaceID = focusedWorkspaceID, let workspace = workspaces[workspaceID] else { return nil }
        var candidates = workspace.windows
        if options.tiledOnly { candidates = candidates.filter { windows[$0]?.isTiled == true } }
        if options.floatingOnly { candidates = candidates.filter { windows[$0]?.isFloating == true } }
        guard !candidates.isEmpty else { return nil }
        guard let current = focusedWindowID, let index = candidates.firstIndex(of: current) else { return candidates.first }
        let step = options.previous ? -1 : 1
        let next = candidates[(index + step + candidates.count) % candidates.count]
        return next == current ? nil : next
    }

    private mutating func resize(_ window: WindowID, _ parameter: ResizeParameter) {
        guard let state = windows[window], let monitor = monitor(of: window) else { return }
        let requested = parameter.resolve(relativeTo: monitor.usableFrame.size)
        if state.isFloating {
            var frame = state.floatingFrame
            frame.size = parameter.exact
                ? requested
                : Size(width: frame.width + requested.width, height: frame.height + requested.height)
            let area = monitor.usableFrame
            frame.size.width = min(max(frame.width, 20), area.width)
            frame.size.height = min(max(frame.height, 20), area.height)
            // Grown past the display's edge, it moves back onto it.
            windows[window]?.floatingFrame = frame.moved(inside: area)
        } else if let current = arrangement().frames[window] {
            let delta = parameter.exact
                ? Size(width: requested.width - current.width, height: requested.height - current.height)
                : requested
            resizeTiled(window, by: delta, corner: nil)
        }
    }

    private mutating func reposition(_ window: WindowID, _ parameter: ResizeParameter) {
        guard let state = windows[window], state.isFloating, let monitor = monitor(of: window) else { return }
        let area = monitor.usableFrame
        let value = parameter.resolve(relativeTo: area.size)
        var frame = state.floatingFrame
        if parameter.exact {
            frame.origin = Point(x: area.minX + value.width, y: area.minY + value.height)
        } else {
            frame.origin = Point(x: frame.minX + value.width, y: frame.minY + value.height)
        }
        // However far it is asked to go, it stays on the display.
        windows[window]?.floatingFrame = frame.moved(inside: area)
    }

    /// Changes the focused workspace's layout, keeping its windows in order. The focused window
    /// takes the main area of a stack.
    private mutating func useLayout(_ choice: Action.LayoutChoice) {
        guard let id = focusedWorkspaceID, let current = workspaces[id]?.tiling.kind else { return }
        workspaces[id]?.layoutOverride = nil
        let configured = settings(for: id).layout.style
        let wanted: LayoutKind = switch choice {
        case .style(let kind): kind
        case .configured: configured
        case .toggle(let kind): current == kind ? configured : kind
        }
        workspaces[id]?.layoutOverride = wanted == configured ? nil : wanted
        let (area, effective) = (layoutArea(for: id), settings(for: id))
        workspaces[id]?.switchLayout(to: wanted, area: area, settings: effective)
        if wanted == .stack, current != .stack, let focused = focusedWindowID,
           let tiled = workspaces[id]?.tiling.windows, tiled.contains(focused), tiled.first != focused {
            try? sendLayoutMessage(LayoutMessage(command: "swap-main", arguments: []))
        }
    }

    private mutating func sendLayoutMessage(_ message: LayoutMessage) throws(ActionError) {
        guard let workspaceID = focusedWorkspaceID, var workspace = workspaces[workspaceID] else { return }
        let focused = focusedWindowID.flatMap { workspace.tiling.contains($0) ? $0 : nil }
        let outcome: LayoutMessageOutcome
        do {
            outcome = try workspace.tiling.handle(message, focused: focused, area: layoutArea(for: workspaceID), settings: settings(for: workspaceID))
        } catch {
            throw .layout(error)
        }
        workspaces[workspaceID] = workspace
        if let focus = outcome.focus { setFocus(focus) }
    }

    /// Where to move the cursor after focus moved with the keyboard: to the focused window, or
    /// the focused display, unless it is already there or `focus.move-cursor` is off.
    private func cursorWarp(after action: Action, focusBefore: WindowID?, monitorBefore: MonitorID?) -> Point? {
        guard settings.focus.movesCursor, focusedWindowID != focusBefore || focusedMonitorID != monitorBefore else { return nil }
        switch action {
        case .focus, .focusLast, .focusWindow, .cycle, .focusDisplay, .move, .moveToDisplay, .swap, .swapInOrder, .layout, .joinTabs, .leaveTabs:
            break
        default:
            return nil
        }
        if let window = focusedWindowID, let frame = arrangement().frames[window] {
            if let cursor, frame.contains(cursor) { return nil }
            return frame.center
        }
        if let monitor = focusedMonitor {
            if let cursor, monitor.frame.contains(cursor) { return nil }
            return monitor.usableFrame.center
        }
        return nil
    }
}
