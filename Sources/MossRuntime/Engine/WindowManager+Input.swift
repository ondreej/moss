import MossCore
import MossConfig
import MossIPC
import Foundation
import os

/// Key bindings, mouse bindings and the cursor.
extension WindowManager {
    public func handle(_ event: InputEvent) {
        guard !isStopping else { return }
        let before = world
        var effects: [Effect] = []
        switch event {
        case .binding(let binding):
            guard let action = binding.action else { break }
            if case .scroll = binding.trigger, !acceptScrollBinding() { break }
            if isPaused, action.arrangesWindows {
                post(Notice(icon: .info, message: "Tiling is paused", milliseconds: 1500))
                break
            }
            effects = (try? world.perform(action)) ?? []

        case .mouseBindingBegan(let action, let point):
            world.cursor = point
            if !isPaused, let window = world.visibleWindow(at: point) {
                world.beginInteraction(action, window: window, cursor: point)
            }

        case .mouseBindingMoved(let point):
            world.updateInteraction(cursor: point)

        case .mouseBindingEnded(let point):
            world.endInteraction(cursor: point)

        case .cursorMoved(let point):
            world.cursor = point
            followMouse(to: point)

        case .primaryButton(let isDown, let point):
            world.cursor = point
            if isDown { lastClick = .now }
            if isDown { world.handleClick(at: point) }
            if !isDown, let drag = userDrag {
                userDrag = nil
                if !drag.resized, world.windows[drag.window]?.isTiled == true {
                    world.drop(drag.window, at: point)
                }
                // Snap the dragged window back into its tile.
                appliedFrames[drag.window] = nil
            }
            if !isDown, let window = floatingDrag {
                floatingDrag = nil
                world.settleFloatingWindow(window)
            }
        }
        commit(from: before, effects: effects)
    }

    func acceptScrollBinding() -> Bool {
        let now = ContinuousClock.now
        // Scrolling sends many events; one shortcut runs at most this often.
        let delay = Duration.milliseconds(300)
        if let last = lastScrollBinding, now - last < delay { return false }
        lastScrollBinding = now
        return true
    }

    /// Focus follows the mouse (`focus.follows-mouse`).
    func followMouse(to point: Point) {
        guard world.interaction == nil, userDrag == nil else {
            Log.input.debug("focus follows mouse suspended: interaction \(self.world.interaction != nil), drag \(self.userDrag != nil)")
            return
        }
        if let monitor = world.monitor(at: point), monitor.id != world.focusedMonitorID {
            world.handleCursorEntered(monitor: monitor.id)
        }
        guard world.settings.focus.followsMouse, !windowSystem.isPrimaryButtonDown(),
              let hovered = world.visibleWindow(at: point), hovered != world.focusedWindowID,
              world.windows[hovered]?.overrides.noFocus == false else {
            Log.input.debug("hover at \(Int(point.x)),\(Int(point.y)): no focus change (button down: \(self.windowSystem.isPrimaryButtonDown()), hovered: \(self.world.visibleWindow(at: point)?.address ?? "none", privacy: .public))")
            return
        }
        // Do not steal focus while the cursor is over a menu, popover or other unmanaged window.
        guard windowSystem.topmostWindow(at: point) == hovered else { return }
        world.handleHover(over: hovered)
    }
}
