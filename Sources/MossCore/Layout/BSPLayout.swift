/// The BSP layout: a binary space partitioning tree in which every new window splits an
/// existing tile in two, alternating direction like a spiral.
///
/// A split's ratio is the share of the tile its first child receives: `0.5` divides it evenly.
public struct BSPLayout: TilingLayout, Hashable, Codable {
    public static let ratioRange: ClosedRange<Double> = 0.05...0.95

    public var kind: LayoutKind { .bsp }

    private var nodes: [NodeID: Node] = [:]
    private var root: NodeID?
    private var leaves: [WindowID: NodeID] = [:]
    private var nextNodeID = 0

    /// A pending direction for the next insertion, set by `preselect`.
    public private(set) var preselection: Direction?

    public init() {}

    /// Builds a layout by inserting `windows` in order with default placement.
    public init(windows: [WindowID], area: Rect, settings: Settings) {
        for window in windows {
            insert(window, context: InsertionContext(target: self.windows.last, area: area, settings: settings))
        }
    }

    // MARK: - Tree storage

    struct NodeID: Hashable, Sendable, Codable {
        let raw: Int
    }

    struct Node: Hashable, Sendable, Codable {
        var parent: NodeID?
        var content: Content
    }

    enum Content: Hashable, Sendable, Codable {
        case window(WindowID)
        case split(Split)
    }

    struct Split: Hashable, Sendable, Codable {
        var first: NodeID
        var second: NodeID
        /// The orientation chosen when the split was created or last toggled.
        var axis: Axis
        var ratio: Double
        /// Set when the orientation was chosen explicitly (preselection, `flip-split`), in
        /// which case it is kept even without `keep-direction`.
        var isAxisLocked = false

        func other(than child: NodeID) -> NodeID { child == first ? second : first }
    }

    private mutating func makeNode(_ content: Content, parent: NodeID? = nil) -> NodeID {
        let id = NodeID(raw: nextNodeID)
        nextNodeID += 1
        nodes[id] = Node(parent: parent, content: content)
        if case .window(let window) = content { leaves[window] = id }
        return id
    }

    private func split(_ id: NodeID) -> Split? {
        guard case .split(let split) = nodes[id]?.content else { return nil }
        return split
    }

    private mutating func updateSplit(_ id: NodeID, _ body: (inout Split) -> Void) {
        guard var split = split(id) else { return }
        body(&split)
        nodes[id]?.content = .split(split)
    }

    /// Replaces `old` with `new` in `old`'s parent (or at the root).
    private mutating func replace(_ old: NodeID, with new: NodeID) {
        let parent = nodes[old]?.parent
        nodes[new]?.parent = parent
        guard let parent else {
            root = new
            return
        }
        updateSplit(parent) { split in
            if split.first == old { split.first = new } else { split.second = new }
        }
    }

    // MARK: - Queries

    public var windows: [WindowID] {
        var result: [WindowID] = []
        result.reserveCapacity(leaves.count)
        func visit(_ id: NodeID) {
            switch nodes[id]?.content {
            case .window(let window): result.append(window)
            case .split(let split):
                visit(split.first)
                visit(split.second)
            case nil: break
            }
        }
        if let root { visit(root) }
        return result
    }

    public func contains(_ window: WindowID) -> Bool { leaves[window] != nil }

    /// The orientation a split takes inside `box`.
    private func effectiveAxis(of split: Split, in box: Rect, settings: Settings) -> Axis {
        let options = settings.layout.bsp
        if !options.keepsDirection && !options.smartSplit && !split.isAxisLocked {
            return Self.naturalAxis(for: box)
        }
        return split.axis
    }

    private static func naturalAxis(for box: Rect) -> Axis {
        box.height > box.width ? .vertical : .horizontal
    }

    struct Geometry {
        var boxes: [NodeID: Rect] = [:]
        var axes: [NodeID: Axis] = [:]
    }

    func geometry(in area: Rect, settings: Settings) -> Geometry {
        var geometry = Geometry()
        func visit(_ id: NodeID, _ box: Rect) {
            geometry.boxes[id] = box
            guard let split = split(id) else { return }
            let axis = effectiveAxis(of: split, in: box, settings: settings)
            geometry.axes[id] = axis
            let parts = box.split(axis, fraction: split.ratio)
            visit(split.first, parts.first)
            visit(split.second, parts.second)
        }
        if let root { visit(root, area) }
        return geometry
    }

    public func boxes(in area: Rect, settings: Settings, minimumSizes: [WindowID: Size]) -> [WindowID: Rect] {
        let geometry = geometry(in: area, settings: settings, minimumSizes: minimumSizes)
        var result: [WindowID: Rect] = [:]
        for (window, leaf) in leaves {
            result[window] = geometry.boxes[leaf]
        }
        return result
    }

    private func leaf(at point: Point, geometry: Geometry) -> NodeID? {
        leaves.values.first { geometry.boxes[$0]?.contains(point) == true }
    }

    /// The leaf containing `point`, or the one closest to it.
    private func closestLeaf(to point: Point, geometry: Geometry) -> NodeID? {
        if let hit = leaf(at: point, geometry: geometry) { return hit }
        return leaves.values.min { a, b in
            distance(from: point, to: geometry.boxes[a]!) < distance(from: point, to: geometry.boxes[b]!)
        }
    }

    private func distance(from point: Point, to rect: Rect) -> Double {
        let clamped = Point(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
        return point.distanceSquared(to: clamped)
    }

    /// Like `geometry(in:settings:)`, but each split moves so that both sides get at least the
    /// minimum size of the windows they hold, when the box is large enough for both.
    /// Otherwise the space is shared in proportion to their minimums.
    func geometry(in area: Rect, settings: Settings, minimumSizes: [WindowID: Size]) -> Geometry {
        // The plain proportions decide which way every split goes.
        let plain = geometry(in: area, settings: settings)
        guard !minimumSizes.isEmpty, let root else { return plain }

        var minimums: [NodeID: Size] = [:]
        func minimum(_ id: NodeID) -> Size {
            if let known = minimums[id] { return known }
            let result: Size
            switch nodes[id]?.content {
            case .window(let window):
                result = minimumSizes[window] ?? Size(width: 0, height: 0)
            case .split(let split):
                let (a, b) = (minimum(split.first), minimum(split.second))
                result = plain.axes[id] == .vertical
                    ? Size(width: max(a.width, b.width), height: a.height + b.height)
                    : Size(width: a.width + b.width, height: max(a.height, b.height))
            case nil:
                result = Size(width: 0, height: 0)
            }
            minimums[id] = result
            return result
        }

        var geometry = Geometry()
        func visit(_ id: NodeID, _ box: Rect) {
            geometry.boxes[id] = box
            guard let split = split(id) else { return }
            let axis = plain.axes[id] ?? effectiveAxis(of: split, in: box, settings: settings)
            geometry.axes[id] = axis
            func length(_ size: Size) -> Double { axis == .horizontal ? size.width : size.height }
            let extent = axis == .horizontal ? box.width : box.height
            let first = extent * split.ratio
            let lengths = apportion(extent, preferred: [first, extent - first], minimums: [length(minimum(split.first)), length(minimum(split.second))])
            let parts = box.split(axis, at: lengths[0])
            visit(split.first, parts.first)
            visit(split.second, parts.second)
        }
        visit(root, area)
        return geometry
    }

    // MARK: - Insertion and removal

    public mutating func insert(_ window: WindowID, context: InsertionContext) {
        guard !contains(window) else { return }
        guard root != nil else {
            root = makeNode(.window(window))
            return
        }

        let settings = context.settings
        let geometry = geometry(in: context.area, settings: settings)
        guard let target = splitTarget(for: context, geometry: geometry), let box = geometry.boxes[target] else { return }

        var axis = Self.naturalAxis(for: box)
        var axisIsExplicit = false
        let newGoesFirst: Bool
        let pointer = context.focalPoint ?? context.cursor

        if let direction = context.direction ?? preselection {
            axis = direction.axis
            axisIsExplicit = true
            newGoesFirst = direction.isTowardsStart
            if !settings.layout.bsp.remembersPreselection { preselection = nil }
        } else if settings.layout.bsp.smartSplit, let pointer {
            let delta = pointer - box.center
            let proportions = box.height / max(box.width, 1)
            if delta.x != 0, abs(delta.y / delta.x) < proportions {
                axis = .horizontal
                newGoesFirst = delta.x <= 0
            } else {
                axis = .vertical
                newGoesFirst = delta.y <= 0
            }
        } else {
            switch settings.layout.bsp.newWindowSide {
            case .before:
                newGoesFirst = true
            case .after:
                newGoesFirst = false
            case .cursor:
                if let pointer {
                    let firstHalf = box.split(axis, fraction: 0.5).first
                    newGoesFirst = firstHalf.contains(pointer)
                } else {
                    newGoesFirst = false
                }
            }
        }

        let newLeaf = makeNode(.window(window))
        let splitNode = NodeID(raw: nextNodeID)
        nextNodeID += 1
        let split = Split(
            first: newGoesFirst ? newLeaf : target,
            second: newGoesFirst ? target : newLeaf,
            axis: axis,
            ratio: settings.layout.bsp.defaultRatio.clamped(to: Self.ratioRange),
            isAxisLocked: axisIsExplicit
        )
        nodes[splitNode] = Node(parent: nil, content: .split(split))
        replace(target, with: splitNode)
        nodes[target]?.parent = splitNode
        nodes[newLeaf]?.parent = splitNode
    }

    private func splitTarget(for context: InsertionContext, geometry: Geometry) -> NodeID? {
        if let focal = context.focalPoint {
            return closestLeaf(to: focal, geometry: geometry)
        }
        let active = context.target.flatMap { leaves[$0] }
        if context.settings.layout.bsp.splitsFocused, let active {
            return active
        }
        if let cursor = context.cursor, let hovered = leaf(at: cursor, geometry: geometry) {
            return hovered
        }
        return active ?? windows.first.flatMap { leaves[$0] }
    }

    public mutating func remove(_ window: WindowID) {
        guard let leaf = leaves.removeValue(forKey: window) else { return }
        defer { nodes[leaf] = nil }
        guard let parent = nodes[leaf]?.parent, let split = split(parent) else {
            root = nil
            return
        }
        let sibling = split.other(than: leaf)
        replace(parent, with: sibling)
        nodes[parent] = nil
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let nodeA = leaves[a], let nodeB = leaves[b], a != b else { return }
        nodes[nodeA]?.content = .window(b)
        nodes[nodeB]?.content = .window(a)
        leaves[a] = nodeB
        leaves[b] = nodeA
    }

    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let node = leaves.removeValue(forKey: old), leaves[new] == nil else { return }
        nodes[node]?.content = .window(new)
        leaves[new] = node
    }

    // MARK: - Movement

    public mutating func move(_ window: WindowID, _ direction: Direction, context: MoveContext) -> Bool {
        guard contains(window), context.neighbor != nil else { return false }
        remove(window)
        insert(window, context: InsertionContext(focalPoint: context.focalPoint, area: context.area, settings: context.settings))
        return true
    }

    // MARK: - Resizing

    public mutating func alterSplitRatio(_ window: WindowID, _ change: RatioChange, area: Rect, settings: Settings) {
        guard let leaf = leaves[window], let parent = nodes[leaf]?.parent else { return }
        updateSplit(parent) { $0.ratio = change.apply(to: $0.ratio).clamped(to: Self.ratioRange) }
    }

    public mutating func resize(_ window: WindowID, by delta: Size, corner: Corner?, area: Rect, settings: Settings) {
        guard let leaf = leaves[window], nodes[leaf]?.parent != nil else { return }
        var geometry = geometry(in: area, settings: settings)
        guard let box = geometry.boxes[leaf] else { return }

        func sticks(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 2 }
        let touchesLeft = sticks(box.minX, area.minX), touchesRight = sticks(box.maxX, area.maxX)
        let touchesTop = sticks(box.minY, area.minY), touchesBottom = sticks(box.maxY, area.maxY)

        var movement = delta
        if touchesLeft && touchesRight { movement.width = 0 }
        if touchesTop && touchesBottom { movement.height = 0 }

        if settings.layout.bsp.smartResize {
            smartResize(leaf, movement: movement, corner: corner, edges: (touchesLeft, touchesRight, touchesTop, touchesBottom), geometry: &geometry, area: area, settings: settings)
        } else {
            simpleResize(leaf, movement: movement, geometry: geometry)
        }
    }

    private mutating func smartResize(
        _ leaf: NodeID,
        movement: Size,
        corner: Corner?,
        edges: (left: Bool, right: Bool, top: Bool, bottom: Bool),
        geometry: inout Geometry,
        area: Rect,
        settings: Settings
    ) {
        // Pick, for each axis, the closest ancestor split whose divider is the edge being
        // dragged ("outer") and the next one in the opposite direction ("inner").
        let none = corner == nil
        let left = corner?.isLeft == true || edges.right
        let right = (corner.map { !$0.isLeft } ?? false) || edges.left
        let top = corner?.isTop == true || edges.bottom
        let bottom = (corner.map { !$0.isTop } ?? false) || edges.top

        var verticalOuter: NodeID?, verticalInner: NodeID?
        var horizontalOuter: NodeID?, horizontalInner: NodeID?

        var current = leaf
        while let parent = nodes[current]?.parent, let split = split(parent) {
            let stacked = geometry.axes[parent] == .vertical
            let isFirst = split.first == current
            if verticalOuter == nil, stacked, none || (top && !isFirst) || (bottom && isFirst) {
                verticalOuter = current
            } else if verticalOuter == nil, verticalInner == nil, stacked {
                verticalInner = current
            } else if horizontalOuter == nil, !stacked, none || (left && !isFirst) || (right && isFirst) {
                horizontalOuter = current
            } else if horizontalOuter == nil, horizontalInner == nil, !stacked {
                horizontalInner = current
            }
            if verticalOuter != nil && horizontalOuter != nil { break }
            current = parent
        }

        if let outer = horizontalOuter {
            adjust(outer: outer, inner: horizontalInner, by: movement.width, axis: .horizontal, geometry: &geometry, area: area, settings: settings)
        }
        if let outer = verticalOuter {
            adjust(outer: outer, inner: verticalInner, by: movement.height, axis: .vertical, geometry: &geometry, area: area, settings: settings)
        }
    }

    private mutating func adjust(outer: NodeID, inner: NodeID?, by amount: Double, axis: Axis, geometry: inout Geometry, area: Rect, settings: Settings) {
        guard amount != 0, let outerParent = nodes[outer]?.parent, let parentBox = geometry.boxes[outerParent] else { return }
        let length = axis == .horizontal ? parentBox.width : parentBox.height
        guard length > 0 else { return }
        updateSplit(outerParent) { $0.ratio = ($0.ratio + amount / length).clamped(to: Self.ratioRange) }

        guard let inner, let innerParent = nodes[inner]?.parent, let innerBox = geometry.boxes[inner] else { return }
        let original = axis == .horizontal ? innerBox.width : innerBox.height
        geometry = self.geometry(in: area, settings: settings)
        guard let newParentBox = geometry.boxes[innerParent], let innerSplit = split(innerParent) else { return }
        let parentLength = axis == .horizontal ? newParentBox.width : newParentBox.height
        guard parentLength > 0 else { return }
        let ratio = innerSplit.first == inner
            ? (original - amount) / parentLength
            : 1 - (original + amount) / parentLength
        updateSplit(innerParent) { $0.ratio = ratio.clamped(to: Self.ratioRange) }
        geometry = self.geometry(in: area, settings: settings)
    }

    private mutating func simpleResize(_ leaf: NodeID, movement: Size, geometry: Geometry) {
        guard let parent = nodes[leaf]?.parent else { return }
        let parentIsSideBySide = geometry.axes[parent] == .horizontal

        // The nearest ancestor splitting along the other axis gives a second degree of freedom.
        var other = nodes[parent]?.parent
        while let candidate = other, (geometry.axes[candidate] == .horizontal) == parentIsSideBySide {
            other = nodes[candidate]?.parent
        }

        let sideContainer = parentIsSideBySide ? parent : other
        let topContainer = parentIsSideBySide ? other : parent
        if let sideContainer, let box = geometry.boxes[sideContainer], box.width > 0 {
            updateSplit(sideContainer) { $0.ratio = ($0.ratio + movement.width / box.width).clamped(to: Self.ratioRange) }
        }
        if let topContainer, let box = geometry.boxes[topContainer], box.height > 0 {
            updateSplit(topContainer) { $0.ratio = ($0.ratio + movement.height / box.height).clamped(to: Self.ratioRange) }
        }
    }

    // MARK: - Layout messages

    public mutating func handle(_ message: LayoutMessage, focused: WindowID?, area: Rect, settings: Settings) throws(LayoutMessageError) -> LayoutMessageOutcome {
        switch message.command {
        case "flip-split":
            guard let parent = focused.flatMap(parentSplit(of:)) else { break }
            let current = geometry(in: area, settings: settings).axes[parent] ?? .horizontal
            updateSplit(parent) {
                $0.axis = current.orthogonal
                $0.isAxisLocked = true
            }
        case "swap-split":
            guard let parent = focused.flatMap(parentSplit(of:)) else { break }
            updateSplit(parent) { Swift.swap(&$0.first, &$0.second) }
        case "preselect":
            guard let argument = message.arguments.first, let direction = Direction(argument: argument) else {
                throw .invalidArgument("preselect expects a direction: left, right, up or down")
            }
            preselection = direction
        case "promote":
            if let focused { moveToRoot(focused, stable: true) }
        default:
            throw .unknownMessage(message.command, layout: .bsp)
        }
        return LayoutMessageOutcome()
    }

    private func parentSplit(of window: WindowID) -> NodeID? {
        leaves[window].flatMap { nodes[$0]?.parent }
    }

    /// Swaps `window` with the half of the tree that does not contain it, making it a direct child of the root.
    private mutating func moveToRoot(_ window: WindowID, stable: Bool) {
        guard let leaf = leaves[window], let parent = nodes[leaf]?.parent, nodes[parent]?.parent != nil, let root else { return }
        var ancestor = leaf
        while let next = nodes[ancestor]?.parent, next != root { ancestor = next }
        guard let rootSplit = split(root) else { return }
        let other = rootSplit.other(than: ancestor)

        // Exchange the positions of `leaf` and `other`.
        let leafParent = parent
        let leafWasFirst = split(leafParent)?.first == leaf
        let otherWasFirst = rootSplit.first == other
        updateSplit(root) { if otherWasFirst { $0.first = leaf } else { $0.second = leaf } }
        updateSplit(leafParent) { if leafWasFirst { $0.first = other } else { $0.second = other } }
        nodes[leaf]?.parent = root
        nodes[other]?.parent = leafParent

        if stable { updateSplit(root) { Swift.swap(&$0.first, &$0.second) } }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
