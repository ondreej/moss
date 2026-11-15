/// The stack layout: one or more main windows take a large share of the screen while the
/// others are stacked beside them.
public struct StackLayout: TilingLayout, Hashable, Codable {
    public static let mainSizeRange: ClosedRange<Double> = 0.05...0.95
    private static let shareRange: ClosedRange<Double> = 0.05...1.95

    public var kind: LayoutKind { .stack }

    struct Entry: Hashable, Sendable, Codable {
        var window: WindowID
        var isMain: Bool
        /// The window's share of its column, `1` being an equal split.
        var share: Double = 1
    }

    private var entries: [Entry] = []
    /// Overrides the configured main size once the main area is resized on this workspace.
    public private(set) var mainSizeOverride: Double?
    /// Overrides the configured side once it is changed with `stack-side`.
    public private(set) var sideOverride: StackSide?

    public init() {}

    public init(windows: [WindowID], area: Rect, settings: Settings) {
        for window in windows {
            insert(window, context: InsertionContext(target: self.windows.last, area: area, settings: settings))
        }
    }

    // MARK: - Queries

    public var windows: [WindowID] { mains.map(\.window) + stack.map(\.window) }
    public var mainWindows: [WindowID] { mains.map(\.window) }

    private var mains: [Entry] { entries.filter(\.isMain) }
    private var stack: [Entry] { entries.filter { !$0.isMain } }

    public func contains(_ window: WindowID) -> Bool { index(of: window) != nil }

    private func index(of window: WindowID) -> Int? { entries.firstIndex { $0.window == window } }

    public func mainSize(settings: Settings) -> Double { mainSizeOverride ?? settings.layout.stack.mainSize }

    public func side(settings: Settings) -> StackSide { sideOverride ?? settings.layout.stack.side }

    /// The side actually used: a centered main area falls back while the stack is too small.
    private func effectiveSide(settings: Settings) -> StackSide {
        let side = side(settings: settings)
        let options = settings.layout.stack
        if side == .center && stack.count < options.centerMinimumStack {
            return options.centerFallback == .center ? .left : options.centerFallback
        }
        return side
    }

    // MARK: - Insertion and removal

    public mutating func insert(_ window: WindowID, context: InsertionContext) {
        guard !contains(window) else { return }
        let options = context.settings.layout.stack
        let activeIndex = context.target.flatMap(index(of:))
        let active = activeIndex.map { entries[$0] }

        var entry = Entry(window: window, isMain: false)
        let becomesMain = entries.isEmpty
            || options.newWindow == .main
            || (options.newWindow == .inherit && active?.isMain == true)

        if becomesMain {
            // A new main window demotes an existing one, keeping the number of main windows.
            let insertsBefore = options.newWindowPosition == .beforeFocused && activeIndex != nil
            let demoted = insertsBefore ? entries.lastIndex(where: \.isMain) : entries.firstIndex(where: \.isMain)
            if let demoted { entries[demoted].isMain = false }
            entry.isMain = true
        }

        switch (options.newWindowPosition, activeIndex) {
        case (.beforeFocused, let index?): entries.insert(entry, at: index)
        case (.afterFocused, let index?): entries.insert(entry, at: index + 1)
        case (.start, _): entries.insert(entry, at: 0)
        default: entries.append(entry)
        }
    }

    public mutating func remove(_ window: WindowID) {
        guard let index = index(of: window) else { return }
        let removed = entries.remove(at: index)
        if removed.isMain, !entries.contains(where: \.isMain), let promoted = entries.indices.first {
            entries[promoted].isMain = true
        }
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let i = index(of: a), let j = index(of: b), i != j else { return }
        let (first, second) = (entries[i], entries[j])
        entries[i] = Entry(window: second.window, isMain: first.isMain, share: first.share)
        entries[j] = Entry(window: first.window, isMain: second.isMain, share: second.share)
    }

    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let index = index(of: old), !contains(new) else { return }
        entries[index].window = new
    }

    public mutating func move(_ window: WindowID, _ direction: Direction, context: MoveContext) -> Bool {
        guard let neighbor = context.neighbor, contains(window) else { return false }
        swap(window, neighbor)
        return true
    }

    // MARK: - Geometry

    /// The main windows and the stack each fill a column across the primary axis, and the windows of a
    /// column share it along the other. Columns and windows grow to the minimum sizes they hold
    /// when there is room, and share the space in proportion to those minimums when there is not.
    public func boxes(in area: Rect, settings: Settings, minimumSizes: [WindowID: Size]) -> [WindowID: Rect] {
        let mains = mains, stack = stack
        guard !mains.isEmpty else { return [:] }
        let side = effectiveSide(settings: settings)
        let mainSize = mainSize(settings: settings)
        // Columns sit side by side across this axis, and windows stack along the other one.
        let across: Axis = side == .top || side == .bottom ? .vertical : .horizontal
        let along: Axis = across == .horizontal ? .vertical : .horizontal
        let extent = across == .horizontal ? area.width : area.height
        var result: [WindowID: Rect] = [:]

        func minimum(_ entry: Entry, on axis: Axis) -> Double {
            let size = minimumSizes[entry.window] ?? Size(width: 0, height: 0)
            return axis == .horizontal ? size.width : size.height
        }

        /// Lays out one column per group of entries, side by side across `area`.
        func columns(_ groups: [[Entry]], preferred: [Double]) {
            let lengths = apportion(extent, preferred: preferred, minimums: groups.map { $0.map { minimum($0, on: across) }.max() ?? 0 })
            var offset = 0.0
            for (group, length) in zip(groups, lengths) {
                let column = across == .horizontal
                    ? Rect(x: area.minX + offset, y: area.minY, width: length, height: area.height)
                    : Rect(x: area.minX, y: area.minY + offset, width: area.width, height: length)
                distribute(group, in: column)
                offset += length
            }
        }

        func distribute(_ entries: [Entry], in column: Rect) {
            let length = along == .vertical ? column.height : column.width
            let total = entries.reduce(0) { $0 + $1.share }
            let lengths = apportion(length, preferred: entries.map { length * $0.share / total }, minimums: entries.map { minimum($0, on: along) })
            var offset = 0.0
            for (entry, length) in zip(entries, lengths) {
                result[entry.window] = along == .vertical
                    ? Rect(x: column.minX, y: column.minY + offset, width: column.width, height: length)
                    : Rect(x: column.minX + offset, y: column.minY, width: length, height: column.height)
                offset += length
            }
        }

        let keepsPosition = settings.layout.stack.keepsMainPosition
        if stack.isEmpty && !(keepsPosition && side == .center) {
            columns([mains], preferred: [extent])
            return result
        }

        switch side {
        case .left, .top:
            columns([mains, stack], preferred: [extent * mainSize, extent - extent * mainSize])
        case .right, .bottom:
            let stackLength = extent * (1 - mainSize)
            columns([stack, mains], preferred: [stackLength, extent - stackLength])
        case .center:
            let (rightStack, leftStack) = Self.alternate(stack)
            let sideLength = (extent - extent * mainSize) / 2
            columns([leftStack, mains, rightStack], preferred: [sideLength, extent * mainSize, sideLength])
        }
        return result
    }

    /// Splits stack windows between the right and left columns, starting on the right.
    private static func alternate(_ stack: [Entry]) -> (right: [Entry], left: [Entry]) {
        var right: [Entry] = [], left: [Entry] = []
        for (offset, entry) in stack.enumerated() {
            if offset.isMultiple(of: 2) { right.append(entry) } else { left.append(entry) }
        }
        return (right, left)
    }

    // MARK: - Resizing

    public mutating func alterSplitRatio(_ window: WindowID, _ change: RatioChange, area: Rect, settings: Settings) {
        mainSizeOverride = change.apply(to: mainSize(settings: settings)).clamped(to: Self.mainSizeRange)
    }

    public mutating func resize(_ window: WindowID, by delta: Size, corner: Corner?, area: Rect, settings: Settings) {
        guard let index = index(of: window) else { return }
        let side = effectiveSide(settings: settings)
        let entry = entries[index]

        // The primary axis moves the boundary between the main area and the stack.
        if !stack.isEmpty || side == .center {
            let change: Double
            switch side {
            case .left: change = delta.width / area.width
            case .right: change = -delta.width / area.width
            case .top: change = delta.height / area.height
            case .bottom: change = -delta.height / area.height
            case .center:
                let onLeft = !entry.isMain && stackIndex(of: window).map { !$0.isMultiple(of: 2) } == true
                let sign: Double = entry.isMain ? (corner?.isLeft == true ? -1 : 1) : (onLeft ? -1 : 1)
                change = sign * 2 * delta.width / area.width
            }
            if change != 0 {
                mainSizeOverride = (mainSize(settings: settings) + change).clamped(to: Self.mainSizeRange)
            }
        }

        // The secondary axis trades space with the neighbouring window in the same column.
        let alongColumn = side == .top || side == .bottom ? delta.width : delta.height
        let column = columnIndices(containing: window, side: side)
        guard alongColumn != 0, column.count > 1, let position = column.firstIndex(of: index) else { return }
        let growsTowardsStart = corner?.isTop == true || (side == .top || side == .bottom ? corner?.isLeft == true : false)
        let neighborPosition = growsTowardsStart || position == column.count - 1 ? position - 1 : position + 1
        guard column.indices.contains(neighborPosition) else { return }

        let columnLength = side == .top || side == .bottom ? area.width : area.height
        let totalShare = column.reduce(0) { $0 + entries[$1].share }
        let shareDelta = alongColumn / columnLength * totalShare * (growsTowardsStart ? -1 : 1)
        let neighbor = column[neighborPosition]
        let applied = min(max(shareDelta, Self.shareRange.lowerBound - entries[index].share), entries[neighbor].share - Self.shareRange.lowerBound)
        entries[index].share += applied
        entries[neighbor].share -= applied
    }

    private func stackIndex(of window: WindowID) -> Int? { stack.firstIndex { $0.window == window } }

    /// Indices into `entries` of the windows sharing a column with `window`, in display order.
    private func columnIndices(containing window: WindowID, side: StackSide) -> [Int] {
        guard let index = index(of: window) else { return [] }
        let isMain = entries[index].isMain
        let sameRole = entries.indices.filter { entries[$0].isMain == isMain }
        guard side == .center, !isMain else { return sameRole }
        let parity = sameRole.firstIndex(of: index)! % 2
        return sameRole.enumerated().filter { $0.offset % 2 == parity }.map(\.element)
    }

    // MARK: - Layout actions

    public mutating func handle(_ message: LayoutMessage, focused: WindowID?, area: Rect, settings: Settings) throws(LayoutMessageError) -> LayoutMessageOutcome {
        let argument = message.arguments.first?.lowercased()
        switch message.command {
        case "swap-main":
            guard let focused, let main = mains.first?.window, let partner = focused == main ? stack.first?.window : main else { break }
            swap(focused, partner)
            return LayoutMessageOutcome(focus: focused)
        case "focus-main":
            guard let main = mains.first?.window else { break }
            if focused == main, let first = stack.first?.window { return LayoutMessageOutcome(focus: first) }
            return LayoutMessageOutcome(focus: main)
        case "main-count":
            switch argument {
            case "+1": if let first = entries.firstIndex(where: { !$0.isMain }) { entries[first].isMain = true }
            case "-1": if mains.count > 1, let last = entries.lastIndex(where: \.isMain) { entries[last].isMain = false }
            default: throw .invalidArgument("main-count expects +1 or -1")
            }
        case "stack-side":
            let current = side(settings: settings)
            switch argument {
            case "next": sideOverride = current.next
            case "previous": sideOverride = current.previous
            case let value?:
                guard let side = StackSide(rawValue: value) else { throw .invalidArgument("stack-side expects left, right, top, bottom, center, next or previous") }
                sideOverride = side
            case nil: throw .invalidArgument("stack-side expects left, right, top, bottom, center, next or previous")
            }
        case "main-size":
            guard let argument, let value = Double(argument) else { throw .invalidArgument("main-size expects a fraction of the screen, such as 0.6 or +0.05") }
            let isRelative = argument.hasPrefix("+") || argument.hasPrefix("-")
            alterSplitRatio(focused ?? WindowID(0), isRelative ? .relative(value) : .exact(value), area: area, settings: settings)
        case "rotate":
            guard argument == "next" || argument == "previous" else { throw .invalidArgument("rotate expects next or previous") }
            rotate(forward: argument == "next")
            return LayoutMessageOutcome(focus: mains.first?.window)
        default:
            throw .unknownMessage(message.command, layout: .stack)
        }
        return LayoutMessageOutcome()
    }

    /// Rotates windows through the main and stack positions.
    private mutating func rotate(forward: Bool) {
        let order = windows
        guard order.count > 1 else { return }
        let rotated = forward ? Array(order.dropFirst()) + [order[0]] : [order[order.count - 1]] + order.dropLast()
        let mainCount = mains.count
        entries = rotated.enumerated().map { Entry(window: $0.element, isMain: $0.offset < mainCount) }
    }
}
