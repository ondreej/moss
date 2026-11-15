extension World {
    /// The smallest size a floating window can be resized to with the mouse.
    static let minimumInteractiveSize = Size(width: 40, height: 40)

    /// Starts moving or resizing a window with the mouse. A tiled window being moved floats
    /// under the cursor until it is dropped.
    @discardableResult
    public mutating func beginInteraction(_ action: DragAction, window id: WindowID, cursor: Point) -> Bool {
        guard interaction == nil, let state = windows[id], isVisible(state.workspace), state.fullscreen == nil,
              let frame = arrangement().frames[id] else { return false }

        let kind: Interaction.Kind
        var layoutBefore: SavedLayout?
        switch action {
        case .move:
            kind = .move
            if state.isTiled {
                layoutBefore = workspaces[state.workspace].map { SavedLayout($0.tiling) }
                workspaces[state.workspace]?.tiling.remove(id)
                workspaces[state.workspace]?.floating.append(id)
                windows[id]?.isFloating = true
                windows[id]?.floatingFrame = frame
            }
        case .resize:
            let corner: Corner = switch (cursor.x < frame.midX, cursor.y < frame.midY) {
            case (true, true): .topLeft
            case (false, true): .topRight
            case (true, false): .bottomLeft
            case (false, false): .bottomRight
            }
            kind = .resize(corner)
        }
        interaction = Interaction(kind: kind, window: id, startCursor: cursor, lastCursor: cursor, startFrame: frame, wasTiled: state.isTiled, layoutBefore: layoutBefore)
        self.cursor = cursor
        setFocus(id)
        return true
    }

    public mutating func updateInteraction(cursor: Point) {
        guard var current = interaction, windows[current.window] != nil else { return }
        let total = cursor - current.startCursor
        let step = cursor - current.lastCursor

        switch current.kind {
        case .move:
            var frame = current.startFrame
            frame.origin = current.startFrame.origin + total
            // A tile being dragged goes back into the layout; only floating windows snap.
            let placed = current.wasTiled ? frame : snapped(frame, moving: current.window)
            windows[current.window]?.floatingFrame = placed
        case .resize(let corner):
            if current.wasTiled {
                resizeTiled(current.window, by: Size(width: step.x, height: step.y), corner: corner)
            } else {
                windows[current.window]?.floatingFrame = Self.resized(current.startFrame, by: total, dragging: corner)
            }
        }
        current.lastCursor = cursor
        interaction = current
        self.cursor = cursor
    }

    public mutating func endInteraction(cursor: Point) {
        guard let finished = interaction else { return }
        updateInteraction(cursor: cursor)
        interaction = nil
        guard let state = windows[finished.window], case .move = finished.kind else { return }

        if finished.wasTiled {
            workspaces[state.workspace]?.floating.removeAll { $0 == finished.window }
            windows[finished.window]?.isFloating = false
            guard let monitor = monitor(at: cursor) else { return }
            let target = monitor.activeScratchpad ?? monitor.activeWorkspace
            if target == state.workspace, let saved = finished.layoutBefore, let other = swapPartner(for: finished.window, at: cursor),
               Set(saved.layout.windows) == Set((workspaces[target]?.tiling.windows ?? []) + [finished.window]) {
                // Dropped in the middle of another tile: the two trade places, and every split stays.
                workspaces[target]?.tiling = saved.layout
                workspaces[target]?.tiling.swap(finished.window, other)
                setFocus(finished.window)
                return
            }
            windows[finished.window]?.workspace = target
            insertTiled(finished.window, into: target, focalPoint: cursor)
            if target != state.workspace {
                removeWorkspaceIfUnused(state.workspace)
            }
            setFocus(finished.window)
        } else if let destination = monitor(at: state.floatingFrame.center), destination.id != workspaces[state.workspace]?.monitor {
            // A floating window dragged onto another monitor joins that monitor's workspace.
            let frame = state.floatingFrame
            moveWindow(finished.window, to: destination.activeScratchpad ?? destination.activeWorkspace)
            windows[finished.window]?.floatingFrame = frame
            setFocus(finished.window)
        }
    }

    public mutating func cancelInteraction() {
        guard let interaction else { return }
        endInteraction(cursor: interaction.lastCursor)
    }

    static func resized(_ frame: Rect, by delta: Point, dragging corner: Corner) -> Rect {
        var minX = frame.minX, minY = frame.minY, maxX = frame.maxX, maxY = frame.maxY
        let minimum = minimumInteractiveSize
        if corner.isLeft { minX = min(minX + delta.x, maxX - minimum.width) } else { maxX = max(maxX + delta.x, minX + minimum.width) }
        if corner.isTop { minY = min(minY + delta.y, maxY - minimum.height) } else { maxY = max(maxY + delta.y, minY + minimum.height) }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
