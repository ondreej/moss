import Testing
@testable import MossCore

@Suite("Scrolling layout")
struct ScrollingLayoutTests {
    let settings = flatSettings()

    func layout(_ windows: [WindowID], settings: Settings? = nil) -> ScrollingLayout {
        ScrollingLayout(windows: windows, area: area, settings: settings ?? self.settings)
    }

    func message(_ layout: inout ScrollingLayout, _ text: String, focused: WindowID?, settings: Settings? = nil) throws -> WindowID? {
        try layout.handle(LayoutMessage(parsing: text), focused: focused, area: area, settings: settings ?? self.settings).focus
    }

    // MARK: Geometry

    @Test func aLoneColumnFillsTheView() {
        #expect(layout([1]).boxes(in: area, settings: settings) == [1: area])
    }

    @Test func columnsSitSideBySide() {
        let boxes = layout([1, 2]).boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(boxes[2] == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func theViewCentersTheFocusedColumn() {
        var layout = layout([1, 2, 3])
        layout.reveal(2, area: area, settings: settings)
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[1]?.minX == -250)
        #expect(boxes[2]?.minX == 250)
        #expect(boxes[3]?.minX == 750)
    }

    @Test func theViewNeverRunsPastTheEnds() {
        var layout = layout([1, 2, 3])
        layout.reveal(3, area: area, settings: settings)
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[2]?.minX == 0)
        #expect(boxes[3]?.minX == 500)
    }

    @Test func fittingScrollsJustEnough() {
        var settings = settings
        settings.layout.scrolling.scrollTo = .fit
        var layout = layout([1, 2, 3, 4], settings: settings)
        layout.reveal(3, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[3]?.minX == 500)
        // Already in view: nothing moves.
        layout.reveal(2, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[2]?.minX == 0)
    }

    @Test func columnsStackTheirWindows() throws {
        var layout = layout([1, 2, 3])
        _ = try message(&layout, "join-column left", focused: 2)
        #expect(layout.columnWindows == [[1, 2], [3]])
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 500, height: 300))
        #expect(boxes[2] == Rect(x: 0, y: 300, width: 500, height: 300))
    }

    @Test func otherDirectionsTurnTheStrip() {
        var settings = settings
        settings.layout.scrolling.direction = .left
        var boxes = layout([1, 2], settings: settings).boxes(in: area, settings: settings)
        #expect(boxes[1]?.minX == 500)
        #expect(boxes[2]?.minX == 0)

        settings.layout.scrolling.direction = .down
        boxes = layout([1, 2], settings: settings).boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 1000, height: 300))
        #expect(boxes[2] == Rect(x: 0, y: 300, width: 1000, height: 300))
    }

    @Test func columnsWidenForWindowsThatCannotShrink() {
        let boxes = layout([1, 2]).boxes(in: area, settings: settings, minimumSizes: [2: Size(width: 700, height: 0)])
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(boxes[2] == Rect(x: 500, y: 0, width: 700, height: 600))
    }

    // MARK: Changing the layout

    @Test func newWindowsOpenAfterTheFocusedColumn() {
        var layout = layout([1, 2, 3])
        layout.insert(4, context: InsertionContext(target: 1, area: area, settings: settings))
        #expect(layout.columnWindows == [[1], [4], [2], [3]])
    }

    @Test func droppedWindowsLandWhereTheyAreDropped() {
        var layout = layout([1, 2])
        layout.insert(3, context: InsertionContext(target: 2, focalPoint: Point(x: 100, y: 300), area: area, settings: settings))
        #expect(layout.columnWindows == [[3], [1], [2]])
    }

    @Test func movingALoneWindowSwapsColumns() {
        var layout = layout([1, 2, 3])
        let context = MoveContext(neighbor: nil, focalPoint: .zero, area: area, settings: settings)
        let swapped = layout.move(1, .right, context: context)
        #expect(swapped)
        #expect(layout.columnWindows == [[2], [1], [3]])
        let pastTheEnd = layout.move(3, .right, context: context)
        #expect(!pastTheEnd)
    }

    @Test func movingAWindowOutOfASharedColumnGivesItItsOwn() throws {
        var layout = layout([1, 2, 3])
        _ = try message(&layout, "join-column left", focused: 2)
        let context = MoveContext(neighbor: nil, focalPoint: .zero, area: area, settings: settings)
        let expelled = layout.move(2, .left, context: context)
        #expect(expelled)
        #expect(layout.columnWindows == [[2], [1], [3]])
        _ = try message(&layout, "join-column right", focused: 2)
        #expect(layout.columnWindows == [[1, 2], [3]])
        let reordered = layout.move(1, .down, context: context)
        #expect(reordered)
        #expect(layout.columnWindows == [[2, 1], [3]])
    }

    @Test func removingAColumnBeforeTheViewKeepsWhatIsShown() {
        var layout = layout([1, 2, 3, 4])
        layout.reveal(4, area: area, settings: settings)
        layout.remove(1)
        #expect(layout.boxes(in: area, settings: settings)[4]?.minX == 500)
    }

    // MARK: Layout messages

    @Test func columnFocusesTheNeighbouringColumn() throws {
        var layout = layout([1, 2, 3])
        let next = try message(&layout, "column next", focused: 2)
        let previous = try message(&layout, "column previous", focused: 2)
        #expect(next == 3)
        #expect(previous == 1)
    }

    @Test func scrollMovesTheViewByADistance() throws {
        var layout = layout([1, 2, 3])
        _ = try message(&layout, "scroll 250", focused: 1)
        #expect(layout.boxes(in: area, settings: settings)[2]?.minX == 250)
    }

    @Test func columnFocusWrapsAround() throws {
        var layout = layout([1, 2, 3])
        let wrapped = try message(&layout, "column next", focused: 3)
        #expect(wrapped == 1)
        var settings = settings
        settings.layout.scrolling.wraps = false
        let stopped = try message(&layout, "column next", focused: 3, settings: settings)
        #expect(stopped == nil)
    }

    @Test func movingAColumnWrapsAround() throws {
        var layout = layout([1, 2, 3])
        _ = try message(&layout, "move-column right", focused: 1)
        #expect(layout.columnWindows == [[2], [1], [3]])
        _ = try message(&layout, "move-column left", focused: 2)
        #expect(layout.columnWindows == [[1], [3], [2]])
    }

    @Test func columnWidthSetsAndStepsThroughWidths() throws {
        var layout = layout([1, 2])
        _ = try message(&layout, "column-width next", focused: 1)
        #expect(layout.columnWidths[0] == 0.667)
        _ = try message(&layout, "column-width next", focused: 1)
        _ = try message(&layout, "column-width next", focused: 1)
        #expect(layout.columnWidths[0] == 0.333)
        _ = try message(&layout, "column-width 0.8", focused: 1)
        #expect(layout.columnWidths[0] == 0.8)
        _ = try message(&layout, "column-width -0.3", focused: 1)
        #expect(abs(layout.columnWidths[0] - 0.5) < 1e-9)
        _ = try message(&layout, "column-width all 0.4", focused: 1)
        #expect(layout.columnWidths == [0.4, 0.4])
    }

    @Test func fitSharesTheViewBetweenColumns() throws {
        var layout = layout([1, 2, 3, 4])
        _ = try message(&layout, "fit all", focused: 1)
        #expect(layout.columnWidths == [0.25, 0.25, 0.25, 0.25])
        _ = try message(&layout, "fit active", focused: 2)
        #expect(layout.columnWidths[1] == 1)
    }

    @Test func scrollToTogglesTheFitMethod() throws {
        var layout = layout([1])
        _ = try message(&layout, "scroll-to toggle", focused: 1)
        #expect(layout.fitMethod(settings: settings) == .fit)
    }

    @Test func badArgumentsAreReported() {
        for text in ["column-width wide", "fit everything", "scroll-to edge", "lock-view maybe", "spin"] {
            var layout = layout([1])
            #expect(throws: LayoutMessageError.self) { _ = try layout.handle(LayoutMessage(parsing: text), focused: 1, area: area, settings: settings) }
        }
    }

    @Test func mouseResizeChangesTheColumnWidth() {
        var layout = layout([1, 2])
        layout.resize(1, by: Size(width: 100, height: 0), corner: .bottomRight, area: area, settings: settings)
        #expect(abs(layout.columnWidths[0] - 0.6) < 1e-9)
        layout.resize(2, by: Size(width: -100, height: 0), corner: .topLeft, area: area, settings: settings)
        #expect(abs(layout.columnWidths[1] - 0.6) < 1e-9)
    }
}

@Suite("Scrolling in the world")
struct ScrollingWorldTests {
    func world(monitors: Int = 1, configure: (inout Settings) -> Void = { _ in }) -> World {
        var settings = flatSettings()
        settings.layout.style = .scrolling
        configure(&settings)
        return makeWorld(settings: settings, monitors: monitors)
    }

    @Test func tilesScrolledOutOfViewAreParked() {
        var world = world()
        for id: WindowID in [1, 2, 3, 4] { world.open(id) }
        let arrangement = world.arrangement()
        #expect(arrangement.frames[3] == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(arrangement.frames[4] == Rect(x: 500, y: 0, width: 500, height: 600))
        #expect(arrangement.hidden[1] != nil && arrangement.hidden[2] != nil)
        #expect(arrangement.outOfView[2] == Rect(x: -500, y: 0, width: 500, height: 600))
    }

    @Test func focusingAScrolledOutWindowBringsItIntoView() throws {
        var world = world()
        for id: WindowID in [1, 2, 3, 4] { world.open(id) }
        try world.run("focus left")
        try world.run("focus left")
        #expect(world.focusedWindowID == 2)
        #expect(world.frame(2) == Rect(x: 250, y: 0, width: 500, height: 600))
    }

    @Test func layoutMessagesReachTheLayout() throws {
        var world = world()
        for id: WindowID in [1, 2, 3] { world.open(id) }
        try world.run("column previous")
        #expect(world.focusedWindowID == 2)
        #expect(world.frame(2)?.minX == 250)
    }

    @Test func hoveringFocusesWithoutScrolling() throws {
        var world = world()
        for id: WindowID in [1, 2, 3] { world.open(id) }
        try world.run("focus left")
        let frame = world.frame(1)
        #expect(frame?.minX == -250)
        world.handleHover(over: 1)
        #expect(world.focusedWindowID == 1)
        #expect(world.frame(1) == frame)
    }

    @Test func hoveringATileBarelyInViewLeavesFocusAlone() throws {
        var world = world { $0.layout.scrolling.hoverMinimumVisible = 0.6 }
        for id: WindowID in [1, 2, 3] { world.open(id) }
        try world.run("focus left")
        world.handleHover(over: 1)
        #expect(world.focusedWindowID == 2)
    }

    @Test func clickingATileBringsItIntoView() throws {
        var world = world()
        for id: WindowID in [1, 2, 3] { world.open(id) }
        try world.run("focus left")
        world.handleClick(at: Point(x: 100, y: 300))
        #expect(world.frame(1)?.minX == 0)
    }

    @Test func tilesReachingAnotherDisplayMustBeMostlyInView() throws {
        var world = world(monitors: 2)
        for id: WindowID in [1, 2, 3] { world.open(id) }
        try world.run("focus left")
        let arrangement = world.arrangement()
        // Half of window 1 is off the left edge, where there is no display: it stays.
        #expect(arrangement.frames[1]?.minX == -250)
        // Half of window 3 would be over the second display: it is parked instead.
        #expect(arrangement.frames[3] == nil)
        #expect(arrangement.hidden[3] == MonitorID(1))
    }

    @Test func aWindowLeavesASharedColumnWithNothingBesideIt() throws {
        var world = world()
        for id: WindowID in [1, 2] { world.open(id) }
        try world.run("join-column left")
        #expect((world.workspaces[.numbered(1)]?.tiling as? ScrollingLayout)?.columnWindows == [[1, 2]])
        try world.run("move right")
        #expect((world.workspaces[.numbered(1)]?.tiling as? ScrollingLayout)?.columnWindows == [[1], [2]])
    }

    @Test func workspaceRulesSetTheDirection() throws {
        let rule = try WorkspaceRule(workspace: .numbered(2), entries: [("direction", "down")])
        #expect(rule.scrollingDirection == .down)
        #expect(rule.entries.map(\.value) == ["down"])
    }
}
