/// The scrolling layout: columns of windows side by side on a strip that runs past the
/// edges of the screen. The view scrolls along the strip to keep the focused column in sight,
/// and the windows of a column share it across the strip.
///
/// Positions along the strip are measured in view lengths, so a column of width `0.5` takes
/// half of the screen whatever its size.
public struct ScrollingLayout: TilingLayout, Hashable, Codable {
    public static let widthRange: ClosedRange<Double> = 0.1...1
    private static let shareRange: ClosedRange<Double> = 0.05...1.95

    public var kind: LayoutKind { .scrolling }

    struct Entry: Hashable, Sendable, Codable {
        var window: WindowID
        /// The window's share of its column, `1` being an equal split.
        var share: Double = 1
    }

    struct Column: Hashable, Sendable, Codable {
        var entries: [Entry]
        /// The column's length along the strip, in view lengths.
        var width: Double
        /// The window that takes focus when the column is focused.
        var active: WindowID

        init(_ window: WindowID, width: Double) {
            entries = [Entry(window: window)]
            self.width = width.clamped(to: ScrollingLayout.widthRange)
            active = window
        }

        var windows: [WindowID] { entries.map(\.window) }
    }

    private var columns: [Column] = []
    /// Where the view starts along the strip, in view lengths.
    public private(set) var viewStart: Double = 0
    /// Overrides the configured way of bringing columns into view, once changed with `scroll-to`.
    public private(set) var fitMethodOverride: ScrollingFitMethod?
    /// Focus does not move the view (`lock-view`).
    public private(set) var isViewLocked = false

    public init() {}

    public init(windows: [WindowID], area: Rect, settings: Settings) {
        for window in windows {
            insert(window, context: InsertionContext(target: self.windows.last, area: area, settings: settings))
        }
    }

    // MARK: - Queries

    public var windows: [WindowID] { columns.flatMap(\.windows) }

    /// The windows of each column, in strip order.
    public var columnWindows: [[WindowID]] { columns.map(\.windows) }

    /// The stored width of each column, in view lengths.
    public var columnWidths: [Double] { columns.map(\.width) }

    public func contains(_ window: WindowID) -> Bool { position(of: window) != nil }

    private func position(of window: WindowID) -> (column: Int, row: Int)? {
        for (column, content) in columns.enumerated() {
            if let row = content.entries.firstIndex(where: { $0.window == window }) { return (column, row) }
        }
        return nil
    }

    public func fitMethod(settings: Settings) -> ScrollingFitMethod {
        fitMethodOverride ?? settings.layout.scrolling.scrollTo
    }

    // MARK: - Insertion and removal

    /// New windows get a column of their own: where `focalPoint` falls on the strip, or after
    /// the focused window's column.
    public mutating func insert(_ window: WindowID, context: InsertionContext) {
        guard !contains(window) else { return }
        let index: Int
        if let point = context.focalPoint {
            index = insertionIndex(at: point, area: context.area, settings: context.settings)
        } else if let target = context.target, let column = position(of: target)?.column {
            index = column + 1
        } else {
            index = columns.count
        }
        columns.insert(Column(window, width: context.settings.layout.scrolling.columnWidth), at: index)
    }

    /// The column index a window dropped at `point` takes: before the first column whose
    /// middle lies past the point.
    private func insertionIndex(at point: Point, area: Rect, settings: Settings) -> Int {
        let strip = Strip(area: area, direction: settings.layout.scrolling.direction)
        guard strip.length > 0 else { return columns.count }
        let lengths = lengths(settings: settings)
        let position = clampedView(viewStart, lengths: lengths, settings: settings) + strip.offset(of: point) / strip.length
        var start = 0.0
        for (index, length) in lengths.enumerated() {
            if position < start + length / 2 { return index }
            start += length
        }
        return columns.count
    }

    public mutating func remove(_ window: WindowID) {
        guard let column = position(of: window)?.column else { return }
        let start = columns[..<column].reduce(0) { $0 + $1.width }, width = columns[column].width
        // A column leaving from before the view must not shift what is shown.
        if detach(window), start + width <= viewStart { viewStart -= width }
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let first = position(of: a), let second = position(of: b), a != b else { return }
        columns[first.column].entries[first.row].window = b
        columns[second.column].entries[second.row].window = a
        for column in [first.column, second.column] where columns[column].active == a || columns[column].active == b {
            let active = columns[column].active
            if !columns[column].windows.contains(active) { columns[column].active = active == a ? b : a }
        }
    }

    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let (column, row) = position(of: old), !contains(new) else { return }
        columns[column].entries[row].window = new
        if columns[column].active == old { columns[column].active = new }
    }

    /// Along the strip, a window sharing its column leaves it for a new column on that side,
    /// and a window alone in its column trades places with the neighbouring column. Across the
    /// strip, windows trade places within their column.
    public mutating func move(_ window: WindowID, _ direction: Direction, context: MoveContext) -> Bool {
        guard let (column, row) = position(of: window) else { return false }
        let strip = Strip(area: context.area, direction: context.settings.layout.scrolling.direction)
        if let step = strip.step(direction) {
            if columns[column].entries.count > 1 {
                expel(window, toColumn: step > 0 ? column + 1 : column, settings: context.settings)
                return true
            }
            let target = column + step
            guard columns.indices.contains(target) else { return false }
            columns.swapAt(column, target)
            return true
        }
        guard let step = strip.crossStep(direction), columns[column].entries.indices.contains(row + step) else { return false }
        columns[column].entries.swapAt(row, row + step)
        return true
    }

    /// Moves `window` out of its column into a new one inserted at `index`, counted before
    /// the window leaves.
    private mutating func expel(_ window: WindowID, toColumn index: Int, settings: Settings) {
        guard let (column, _) = position(of: window), columns[column].entries.count > 1 else { return }
        detach(window)
        columns.insert(Column(window, width: settings.layout.scrolling.columnWidth), at: index)
    }

    /// Moves `window` to the end of the column at `target`.
    private mutating func consume(_ window: WindowID, into target: Int) {
        guard let column = position(of: window)?.column, column != target, columns.indices.contains(target) else { return }
        let index = detach(window) && column < target ? target - 1 : target
        columns[index].entries.append(Entry(window: window))
        columns[index].active = window
    }

    /// Takes `window` out of its column. Returns whether the column emptied and was dropped.
    @discardableResult
    private mutating func detach(_ window: WindowID) -> Bool {
        guard let (column, row) = position(of: window) else { return false }
        guard columns[column].entries.count > 1 else {
            columns.remove(at: column)
            return true
        }
        columns[column].entries.remove(at: row)
        if columns[column].active == window {
            columns[column].active = columns[column].entries[min(row, columns[column].entries.count - 1)].window
        }
        return false
    }

    // MARK: - Geometry

    /// Each column's length along the strip, in view lengths. A lone column fills the view
    /// with `fill-lone-column`, and columns grow to the minimum size of their windows.
    private func lengths(settings: Settings, strip: Strip? = nil, minimumSizes: [WindowID: Size] = [:]) -> [Double] {
        if columns.count == 1 && settings.layout.scrolling.fillsLoneColumn { return [1] }
        return columns.map { column in
            guard let strip, strip.length > 0 else { return column.width }
            let minimum = column.windows.map { minimumSizes[$0].map(strip.along) ?? 0 }.max() ?? 0
            return max(column.width, minimum / strip.length)
        }
    }

    /// The start of the view as shown: it never runs past either end of the strip, and a strip
    /// shorter than the view is centered or starts at its beginning, following the fit method.
    private func clampedView(_ view: Double, lengths: [Double], settings: Settings) -> Double {
        let total = lengths.reduce(0, +)
        if total <= 1 {
            return fitMethod(settings: settings) == .center ? (total - 1) / 2 : 0
        }
        return min(max(view, 0), total - 1)
    }

    public func boxes(in area: Rect, settings: Settings, minimumSizes: [WindowID: Size]) -> [WindowID: Rect] {
        let strip = Strip(area: area, direction: settings.layout.scrolling.direction)
        let lengths = lengths(settings: settings, strip: strip, minimumSizes: minimumSizes)
        let view = clampedView(viewStart, lengths: lengths, settings: settings)
        var result: [WindowID: Rect] = [:]
        var start = 0.0
        for (column, length) in zip(columns, lengths) {
            let offset = (start - view) * strip.length
            let totalShare = column.entries.reduce(0) { $0 + $1.share }
            let breadths = apportion(
                strip.breadth,
                preferred: column.entries.map { strip.breadth * $0.share / totalShare },
                minimums: column.entries.map { minimumSizes[$0.window].map(strip.across) ?? 0 }
            )
            var across = 0.0
            for (entry, breadth) in zip(column.entries, breadths) {
                result[entry.window] = strip.rect(along: offset, length: length * strip.length, across: across, breadth: breadth)
                across += breadth
            }
            start += length
        }
        return result
    }

    // MARK: - The view

    public mutating func reveal(_ window: WindowID, area: Rect, settings: Settings) {
        guard let column = position(of: window)?.column else { return }
        columns[column].active = window
        guard settings.layout.scrolling.followsFocus, !isViewLocked else { return }
        bringIntoView(column, settings: settings)
    }

    /// Scrolls so that `column` is in view, centered or just fitting.
    private mutating func bringIntoView(_ column: Int, settings: Settings, method: ScrollingFitMethod? = nil) {
        guard columns.indices.contains(column) else { return }
        let lengths = lengths(settings: settings)
        let start = lengths[..<column].reduce(0, +), length = lengths[column]
        let current = clampedView(viewStart, lengths: lengths, settings: settings)
        let view = switch method ?? fitMethod(settings: settings) {
        case .center: start + length / 2 - 0.5
        case .fit where length >= 1 || start < current: start
        case .fit where start + length > current + 1: start + length - 1
        case .fit: current
        }
        viewStart = clampedView(view, lengths: lengths, settings: settings)
    }

    /// Scrolls the view by `distance` view lengths.
    private mutating func scroll(by distance: Double, settings: Settings) {
        let lengths = lengths(settings: settings)
        viewStart = clampedView(clampedView(viewStart, lengths: lengths, settings: settings) + distance, lengths: lengths, settings: settings)
    }

    // MARK: - Resizing

    public mutating func alterSplitRatio(_ window: WindowID, _ change: RatioChange, area: Rect, settings: Settings) {
        guard let column = position(of: window)?.column else { return }
        columns[column].width = change.apply(to: columns[column].width).clamped(to: Self.widthRange)
        bringIntoView(column, settings: settings)
    }

    /// Along the strip the column changes width; across it, the window trades space with its
    /// neighbour in the column.
    public mutating func resize(_ window: WindowID, by delta: Size, corner: Corner?, area: Rect, settings: Settings) {
        guard let (column, row) = position(of: window) else { return }
        let strip = Strip(area: area, direction: settings.layout.scrolling.direction)
        // Dragging a left or top corner grows the window as the cursor moves left or up.
        let growth = Size(width: corner?.isLeft == true ? -delta.width : delta.width, height: corner?.isTop == true ? -delta.height : delta.height)

        if strip.along(growth) != 0, strip.length > 0 {
            columns[column].width = (columns[column].width + strip.along(growth) / strip.length).clamped(to: Self.widthRange)
        }

        let entries = columns[column].entries
        guard strip.across(growth) != 0, entries.count > 1, strip.breadth > 0 else { return }
        let towardsStart = strip.isHorizontal ? corner?.isTop == true : corner?.isLeft == true
        let neighbor = towardsStart || row == entries.count - 1 ? row - 1 : row + 1
        guard entries.indices.contains(neighbor) else { return }
        let totalShare = entries.reduce(0) { $0 + $1.share }
        let change = strip.across(growth) / strip.breadth * totalShare
        let applied = min(max(change, Self.shareRange.lowerBound - entries[row].share), entries[neighbor].share - Self.shareRange.lowerBound)
        columns[column].entries[row].share += applied
        columns[column].entries[neighbor].share -= applied
    }

    // MARK: - Layout actions

    public mutating func handle(_ message: LayoutMessage, focused: WindowID?, area: Rect, settings: Settings) throws(LayoutMessageError) -> LayoutMessageOutcome {
        let strip = Strip(area: area, direction: settings.layout.scrolling.direction)
        let arguments = message.arguments.map { $0.lowercased() }
        let current = focused.flatMap(position(of:))?.column
        let wraps = settings.layout.scrolling.wraps

        /// `left` / `right` (or `up` / `down` on a vertical strip) as a step along the strip.
        func step(_ name: String) throws(LayoutMessageError) -> Int {
            guard let direction = Direction(argument: name) else { throw .invalidArgument("\(message.command) expects a direction such as left or right") }
            return strip.step(direction) ?? (direction.isTowardsStart ? -1 : 1)
        }

        switch message.command {
        case "column":
            guard arguments.first == "next" || arguments.first == "previous" else { throw .invalidArgument("column expects next or previous") }
            guard let current, let target = Self.index(current + (arguments.first == "next" ? 1 : -1), count: columns.count, wrap: wraps) else { break }
            return LayoutMessageOutcome(focus: columns[target].active)

        case "scroll":
            guard let distance = arguments.first.flatMap(Double.init) else { throw .invalidArgument("scroll expects a distance in points, such as -200") }
            if strip.length > 0 { scroll(by: distance / strip.length, settings: settings) }

        case "column-width":
            try resizeColumns(arguments, current: current, settings: settings)

        case "fit":
            try fit(arguments.first ?? "active", current: current, area: area, settings: settings)

        case "move-column":
            let step = try step(arguments.first ?? "")
            guard let focused, let current else { break }
            swapColumn(current, step: step, wrap: wraps)
            return LayoutMessageOutcome(focus: focused)

        case "join-column":
            let step = try step(arguments.first ?? "")
            guard let focused, let current, columns.indices.contains(current + step) else { break }
            consume(focused, into: current + step)
            return LayoutMessageOutcome(focus: focused)

        case "leave-column":
            guard let focused, let current else { break }
            expel(focused, toColumn: current + 1, settings: settings)
            return LayoutMessageOutcome(focus: focused)

        case "reveal":
            if let current { bringIntoView(current, settings: settings, method: .fit) }

        case "scroll-to":
            switch arguments.first {
            case "toggle": fitMethodOverride = fitMethod(settings: settings).toggled
            case let value?:
                guard let method = ScrollingFitMethod(rawValue: value) else { throw .invalidArgument("scroll-to expects center, fit or toggle") }
                fitMethodOverride = method
            case nil: throw .invalidArgument("scroll-to expects center, fit or toggle")
            }
            if let current { bringIntoView(current, settings: settings) }

        case "lock-view":
            switch arguments.first {
            case nil, "toggle": isViewLocked.toggle()
            case "on": isViewLocked = true
            case "off": isViewLocked = false
            default: throw .invalidArgument("lock-view expects on, off or toggle")
            }

        default:
            throw .unknownMessage(message.command, layout: .scrolling)
        }
        return LayoutMessageOutcome()
    }

    /// `column-width`: an exact width (`0.5`), a relative change (`+0.1`), the next or previous
    /// preset, or one width for every column (`all 0.5`).
    private mutating func resizeColumns(_ arguments: [String], current: Int?, settings: Settings) throws(LayoutMessageError) {
        let usage = "column-width expects a fraction of the screen (0.5, +0.1), next, previous, or all followed by a width"
        guard let argument = arguments.first else { throw .invalidArgument(usage) }
        if argument == "all" {
            guard arguments.count > 1, let width = Double(arguments[1]) else { throw .invalidArgument(usage) }
            for index in columns.indices { columns[index].width = width.clamped(to: Self.widthRange) }
        } else if let current {
            let width = columns[current].width
            switch argument {
            case "next", "previous":
                columns[current].width = Self.preset(after: width, forward: argument == "next", in: settings.layout.scrolling.columnWidthPresets)
            default:
                guard let value = Double(argument) else { throw .invalidArgument(usage) }
                let isRelative = argument.hasPrefix("+") || argument.hasPrefix("-")
                columns[current].width = (isRelative ? width + value : value).clamped(to: Self.widthRange)
            }
        }
        if let current { bringIntoView(current, settings: settings) }
    }

    /// The next larger preset width, or the next smaller one, wrapping around.
    static func preset(after width: Double, forward: Bool, in presets: [Double]) -> Double {
        let sorted = presets.map { $0.clamped(to: widthRange) }.sorted()
        guard let first = sorted.first, let last = sorted.last else { return width }
        let tolerance = 0.001
        return forward
            ? sorted.first { $0 > width + tolerance } ?? first
            : sorted.last { $0 < width - tolerance } ?? last
    }

    /// `fit`: resizes columns to share the view exactly.
    private mutating func fit(_ mode: String, current: Int?, area: Rect, settings: Settings) throws(LayoutMessageError) {
        let lengths = lengths(settings: settings)
        let starts = lengths.indices.map { lengths[..<$0].reduce(0, +) }
        let range: Range<Int>
        switch mode {
        case "active":
            guard let current else { return }
            range = current..<(current + 1)
        case "all":
            range = columns.indices
        case "visible":
            let view = clampedView(viewStart, lengths: lengths, settings: settings)
            let visible = columns.indices.filter { starts[$0] < view + 1 && starts[$0] + lengths[$0] > view }
            guard let first = visible.first, let last = visible.last else { return }
            range = first..<(last + 1)
        case "to-end":
            guard let current else { return }
            range = current..<columns.count
        case "to-start":
            guard let current else { return }
            range = 0..<(current + 1)
        default:
            throw .invalidArgument("fit expects active, visible, all, to-end or to-start")
        }
        guard !range.isEmpty else { return }
        for index in range { columns[index].width = (1 / Double(range.count)).clamped(to: Self.widthRange) }
        viewStart = clampedView(columns[..<range.lowerBound].reduce(0) { $0 + $1.width }, lengths: self.lengths(settings: settings), settings: settings)
    }

    /// `index` when it is within `0..<count`; otherwise wrapped around, if allowed.
    private static func index(_ index: Int, count: Int, wrap: Bool) -> Int? {
        if (0..<count).contains(index) { return index }
        guard wrap, count > 1 else { return nil }
        return (index % count + count) % count
    }

    /// Moves a column one place along the strip; past either end it wraps to the other.
    private mutating func swapColumn(_ column: Int, step: Int, wrap: Bool) {
        let target = column + step
        if columns.indices.contains(target) {
            columns.swapAt(column, target)
        } else if wrap, columns.count > 1 {
            let moved = columns.remove(at: column)
            if step < 0 { columns.append(moved) } else { columns.insert(moved, at: 0) }
        }
    }
}

/// The scrolling layout's strip within a work area: how positions along it and across it map
/// to the screen.
private struct Strip {
    let area: Rect
    let direction: ScrollingDirection

    var isHorizontal: Bool { direction == .right || direction == .left }
    /// The view's length along the strip.
    var length: Double { isHorizontal ? area.width : area.height }
    /// The view's extent across the strip.
    var breadth: Double { isHorizontal ? area.height : area.width }

    func along(_ size: Size) -> Double { isHorizontal ? size.width : size.height }
    func across(_ size: Size) -> Double { isHorizontal ? size.height : size.width }

    /// The rectangle starting `offset` points along the strip from the view's start and
    /// `across` points across it from the area's top or left edge.
    func rect(along offset: Double, length: Double, across: Double, breadth: Double) -> Rect {
        switch direction {
        case .right: Rect(x: area.minX + offset, y: area.minY + across, width: length, height: breadth)
        case .left: Rect(x: area.maxX - offset - length, y: area.minY + across, width: length, height: breadth)
        case .down: Rect(x: area.minX + across, y: area.minY + offset, width: breadth, height: length)
        case .up: Rect(x: area.minX + across, y: area.maxY - offset - length, width: breadth, height: length)
        }
    }

    /// How far `point` lies along the strip from the view's start, in points.
    func offset(of point: Point) -> Double {
        switch direction {
        case .right: point.x - area.minX
        case .left: area.maxX - point.x
        case .down: point.y - area.minY
        case .up: area.maxY - point.y
        }
    }

    /// `+1` when `direction` points further along the strip, `-1` back towards its start,
    /// `nil` across it.
    func step(_ direction: Direction) -> Int? {
        switch (self.direction, direction) {
        case (.right, .right), (.left, .left), (.down, .down), (.up, .up): 1
        case (.right, .left), (.left, .right), (.down, .up), (.up, .down): -1
        default: nil
        }
    }

    /// `+1` when `direction` points down (or right on a vertical strip), `-1` the other way,
    /// `nil` along the strip.
    func crossStep(_ direction: Direction) -> Int? {
        switch (isHorizontal, direction) {
        case (true, .down), (false, .right): 1
        case (true, .up), (false, .left): -1
        default: nil
        }
    }
}
