/// A workspace's layout as it was, kept to put windows back exactly where they were: across
/// a restart, or after windows were hidden or minimized for a while.
public enum SavedLayout: Hashable, Sendable, Codable {
    case bsp(BSPLayout)
    case stack(StackLayout)
    case scrolling(ScrollingLayout)

    public init(_ layout: any TilingLayout) {
        switch layout {
        case let bsp as BSPLayout: self = .bsp(bsp)
        case let stack as StackLayout: self = .stack(stack)
        case let scrolling as ScrollingLayout: self = .scrolling(scrolling)
        default: preconditionFailure("unknown layout \(type(of: layout))")
        }
    }

    public var layout: any TilingLayout {
        switch self {
        case .bsp(let layout): layout
        case .stack(let layout): layout
        case .scrolling(let layout): layout
        }
    }
}

extension World {
    /// Puts back a layout saved earlier on `workspace`. The windows it holds that are still
    /// tiled there go back exactly where they were; the ones that left are taken out. Windows
    /// tiled there that it does not hold are added with `addingOthers`; without it, the layout
    /// is only put back when there are none, so no window is moved that did not leave.
    ///
    /// A saved layout of another kind than the workspace's is ignored with `addingOthers`, as
    /// the configured layout may have changed since. Otherwise the workspace was emptied while
    /// the windows were away and made again, and takes the saved kind back.
    public mutating func reinstate(_ saved: SavedLayout, on workspace: WorkspaceID, addingOthers: Bool) {
        guard let current = workspaces[workspace]?.tiling else { return }
        let present = current.windows
        var layout = saved.layout
        if !addingOthers, present.contains(where: { !layout.contains($0) }) { return }
        if current.kind != layout.kind {
            guard !addingOthers else { return }
            workspaces[workspace]?.layoutOverride = nil
            let configured = settings(for: workspace).layout.style
            workspaces[workspace]?.layoutOverride = layout.kind == configured ? nil : layout.kind
        }
        for window in layout.windows where !present.contains(window) {
            // A tab group shows another member now: it takes the place of the one saved.
            if let group = windows[window]?.group, let active = groups[group]?.active, active != window,
               present.contains(active), !layout.contains(active) {
                layout.replace(window, with: active)
            } else {
                layout.remove(window)
            }
        }
        let (area, settings) = (layoutArea(for: workspace), settings(for: workspace))
        for window in present where !layout.contains(window) {
            layout.insert(window, context: InsertionContext(target: layout.windows.last, area: area, settings: settings))
        }
        workspaces[workspace]?.tiling = layout
    }
}
