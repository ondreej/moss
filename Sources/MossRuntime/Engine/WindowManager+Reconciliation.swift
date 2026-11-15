import MossCore
import MossConfig
import MossIPC
import Foundation
import os

/// Bringing the system in line with the model.
extension WindowManager {
    func commit(from before: World, effects: [Effect] = [], extraEvents: [Event] = []) {
        var events = world.events(since: before) + extraEvents
        for effect in effects {
            switch effect {
            case .run(let command): commands.run(command, environment: environment)
            case .expireRunRules(let token):
                Task { @EngineActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.world.expireRunRules(token)
                }
            case .close(let window): windowSystem.close(window)
            case .quit(let pid): windowSystem.terminate(pid: pid)
            case .signal(let pid, let number): windowSystem.signal(pid: pid, number)
            case .sendKeys(let chord, let pid): input.send(chord, to: pid)
            case .warpCursor(let point):
                windowSystem.warpCursor(to: point)
                world.cursor = point
            case .emit(let event): events.append(event)
            case .show(let surface): onShow?(surface)
            case .pause(let change): setPaused(change.apply(to: isPaused))
            case .reload: reloadConfiguration()
            case .quitMoss: onExit?()
            }
        }
        reconcile()
        showWorkspaceSwitch(from: before)
        if !events.isEmpty {
            publish(events)
            scheduleSessionSave()
        }
    }

    /// Brings windows, focus, decorations and the active mode in line with `world`.
    func reconcile() {
        guard hasStarted, !isPaused else { return }
        let arrangement = world.arrangement()
        let monitorFrames = world.monitors.map(\.frame)
        if let drag = userDrag, arrangement.frames[drag.window] == nil {
            // The window was sent out of sight mid-drag; releasing the button must not drop it here.
            userDrag = nil
        }
        let draggedWindow = userDrag?.window

        var frames: [WindowID: Rect] = [:]
        let animation = world.interaction == nil && userDrag == nil ? world.settings.animation.windowMovement : nil
        for (id, tile) in arrangement.frames where id != draggedWindow {
            if fittedFrames[id].map({ !$0.tile.isApproximatelyEqual(to: tile, tolerance: 1) }) == true {
                // A new tile: the window is offered all of it again.
                fittedFrames[id] = nil
            }
            let frame = target(for: id, in: tile)
            if let target = animator.target(of: id), target.isApproximatelyEqual(to: frame, tolerance: 1) { continue }
            // A tile scrolling back into view slides in from beyond the edge, not from where it was parked.
            let own = monitorFrames.max { frame.intersection($0).area < frame.intersection($1).area }
            let slidesIn = animator.isAnimating(id) ? nil : lastArrangement?.outOfView[id].flatMap { isOffScreen($0, monitors: monitorFrames, except: own) ? $0 : nil }
            let current = slidesIn ?? animator.frame(of: id) ?? appliedFrames[id] ?? observedFrames[id]
            guard current.map({ !$0.isApproximatelyEqual(to: frame, tolerance: 1) }) ?? true else { continue }

            if let animation, let current, slidesIn != nil || isOnScreen(current, monitors: monitorFrames), current.origin.distanceSquared(to: frame.origin) > 4 {
                animator.animate(id, from: current, to: frame, spec: animation)
                appliedFrames[id] = frame
            } else {
                animator.cancel(id)
                frames[id] = frame
            }
        }
        for (id, monitorID) in arrangement.hidden {
            guard let monitor = world.monitor(monitorID) else { continue }
            let size = observedFrames[id]?.size ?? appliedFrames[id]?.size ?? Size(width: 800, height: 600)
            let parked = HiddenPlacement.frame(for: size, on: monitor.frame, others: monitorFrames.filter { $0 != monitor.frame })
            if animator.target(of: id) == parked { continue }
            // A tile scrolling out of view slides past the edge before it is parked.
            if let animation, let edge = arrangement.outOfView[id], isOffScreen(edge, monitors: monitorFrames, except: monitor.frame),
               let current = animator.frame(of: id) ?? lastArrangement?.frames[id] {
                animator.animate(id, from: current, to: edge, then: parked, spec: animation)
                appliedFrames[id] = parked
                continue
            }
            animator.cancel(id)
            if appliedFrames[id].map({ !$0.isApproximatelyEqual(to: parked, tolerance: 1) }) ?? true {
                frames[id] = parked
            }
        }
        if !frames.isEmpty {
            appliedFrames.merge(frames) { _, new in new }
            windowSystem.setFrames(frames)
        }

        // macOS keeps the windows of a workspace coming into view where they were in its order,
        // often behind the tiles of the workspace before. Its floating windows, and a
        // scratchpad's windows, are brought above them.
        let visibleWorkspaces = Set(world.monitors.flatMap { [$0.activeWorkspace] + ($0.activeScratchpad.map { [$0] } ?? []) })
        let returning = lastArrangement == nil ? [] : arrangement.stack.filter { id in
            guard let window = world.windows[id], !appliedWorkspaces.contains(window.workspace) else { return false }
            return window.isFloating || window.workspace.isScratchpad
        }
        appliedWorkspaces = visibleWorkspaces
        // Only when Moss moves focus itself: when the user went to a window, by Command-Tab
        // or a click, the order is the application's to keep, so Command-Tab back works.
        if let focused = world.focusedWindowID, focused != appliedFocus {
            Log.engine.debug("focusing \(focused.address, privacy: .public)")
            appliedFocus = focused
            pendingFocus = (focused, .now)
            let others = returning.filter { $0 != focused }
            focusRequests = focusRequests.filter { ContinuousClock.now - $0.value < .seconds(2) }
            for window in others + [focused] { focusRequests[window] = .now }
            broughtForward = focusRequests.filter { others.contains($0.key) }
            if others.isEmpty {
                windowSystem.focus(focused)
            } else {
                windowSystem.focus(focused, after: others)
            }
            decorations.restack()
        } else if world.focusedWindowID == nil, let previous = appliedFocus, dormant[previous] == nil,
                  world.windows[previous].map({ !world.isVisible(window: $0.id) }) ?? true {
            // Nothing in view is to have focus, and the window that had it went out of sight
            // or closed: typing must not go on into a window no one can see.
            appliedFocus = nil
            windowSystem.focusDesktop()
        }

        if world.mode != appliedMode {
            appliedMode = world.mode
            input.setMode(world.mode)
        }

        lastArrangement = arrangement
        updateDecorations()
        updateDropTarget()
    }

    /// While a tiled window is dragged, shows the tile it would take if dropped now.
    func updateDropTarget() {
        var target: (window: WindowID, frame: Rect)?
        if let interaction = world.interaction, let cursor = world.cursor {
            target = world.dropTarget(for: interaction.window, at: cursor).map { (interaction.window, $0) }
        } else if let drag = userDrag, !drag.resized {
            target = world.dropTarget(for: drag.window, at: windowSystem.cursorLocation()).map { (drag.window, $0) }
        }
        guard target?.frame != appliedDropTarget else { return }
        appliedDropTarget = target?.frame
        decorations.showDropTarget(target?.frame, below: target?.window)
    }

    func updateDecorations() {
        guard let arrangement = lastArrangement else { return }
        let decorations = decorations(for: arrangement)
        if decorations != appliedDecorations {
            appliedDecorations = decorations
            self.decorations.update(decorations)
        }
    }

    /// Where a window goes for its tile: the tile itself, unless its application settled on a
    /// smaller frame within it.
    func target(for id: WindowID, in tile: Rect) -> Rect {
        guard let fitted = fittedFrames[id], fitted.tile.isApproximatelyEqual(to: tile, tolerance: 1) else { return tile }
        return fitted.frame
    }

    /// One animation frame: move the windows and keep their borders with them.
    func animationStep(_ frames: [WindowID: Rect]) {
        windowSystem.setFrames(frames)
        updateDecorations()
    }

    /// Whether most of a frame is on a display, as opposed to parked in a corner.
    private func isOnScreen(_ frame: Rect, monitors: [Rect]) -> Bool {
        let visible = monitors.reduce(0) { $0 + frame.intersection($1).area }
        return visible > frame.area * 0.5
    }

    /// Whether `frame` lies beyond every display but `own`, so a window can slide through it unseen.
    private func isOffScreen(_ frame: Rect, monitors: [Rect], except own: Rect? = nil) -> Bool {
        !monitors.contains { $0 != own && $0.intersects(frame) }
    }

    func decorations(for arrangement: Arrangement) -> [WindowDecoration] {
        // An open scratchpad dims what is behind it on its display.
        var dimmedBehind: [MonitorID: Double] = [:]
        for monitor in world.monitors {
            guard let scratchpad = monitor.activeScratchpad else { continue }
            dimmedBehind[monitor.id] = world.settings(for: scratchpad).scratchpads.dimBehind
        }
        return arrangement.stack.compactMap { id in
            // Fullscreen windows are drawn without decorations.
            guard let window = world.windows[id], window.fullscreen != .fullscreen, let tile = arrangement.frames[id] else { return nil }
            let settings = world.settings(for: window.workspace)
            var frame = target(for: id, in: tile)
            if let moving = animator.frame(of: id) {
                frame = moving
            } else if let observed = observedFrames[id], observed.isApproximatelyEqual(to: frame, tolerance: Self.fillTolerance) || userDrag?.window == id {
                frame = observed
            }
            let isActive = id == world.focusedWindowID
            let group = world.group(of: id)
            let gradient = isActive ? window.overrides.activeBorder ?? settings.borders.active : window.overrides.inactiveBorder ?? settings.borders.inactive
            var dim = settings.dimming.isEnabled && !isActive ? settings.dimming.amount : 0
            if !window.workspace.isScratchpad, let monitor = world.workspaces[window.workspace]?.monitor {
                dim = max(dim, dimmedBehind[monitor] ?? 0)
            }
            if window.overrides.noDim { dim = 0 }
            return WindowDecoration(
                window: id,
                frame: frame,
                borderWidth: world.borderSize(of: window),
                border: gradient,
                corners: corners(of: window, settings: settings),
                dim: dim,
                isActive: isActive,
                tabs: group.flatMap { tabBar(for: $0, settings: settings) }
            )
        }
    }

    /// Borders hug the window's own corners unless a rule or workspace says otherwise.
    private func corners(of window: Window, settings: Settings) -> CornerStyle {
        if let radius = window.overrides.cornerRadius { return .fixed(radius) }
        let borders = settings.borders
        return borders.followsWindowCorners ? .window(fallback: borders.cornerRadius) : .fixed(borders.cornerRadius)
    }

    private func tabBar(for group: WindowGroup, settings: Settings) -> TabBar? {
        guard settings.tabs.showsBar else { return nil }
        let tabs = group.members.compactMap { member in
            world.windows[member].map { TabBar.Tab(title: $0.properties.title.isEmpty ? $0.properties.appName : $0.properties.title, isActive: member == group.active) }
        }
        return TabBar(tabs: tabs, height: settings.tabs.barHeight, showsTitles: settings.tabs.showsTitles)
    }
}
