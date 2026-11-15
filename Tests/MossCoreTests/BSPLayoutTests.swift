import Testing
@testable import MossCore

@Suite("BSP layout")
struct BSPLayoutTests {
    let settings = flatSettings()

    func layout(_ windows: [WindowID], settings: Settings? = nil) -> BSPLayout {
        BSPLayout(windows: windows, area: area, settings: settings ?? self.settings)
    }

    @Test func singleWindowFillsTheArea() {
        let boxes = layout([1]).boxes(in: area, settings: settings)
        #expect(boxes == [1: area])
    }

    @Test func secondWindowSplitsAlongTheLongerSide() {
        let boxes = layout([1, 2]).boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(boxes[2] == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func thirdWindowSplitsTheFocusedTallTileVertically() {
        let boxes = layout([1, 2, 3]).boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(boxes[2] == Rect(x: 500, y: 0, width: 500, height: 300))
        #expect(boxes[3] == Rect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func forceSplitFirstPlacesNewWindowsLeft() {
        var settings = settings
        settings.layout.bsp.newWindowSide = .before
        let boxes = layout([1, 2], settings: settings).boxes(in: area, settings: settings)
        #expect(boxes[2] == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(boxes[1] == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func cursorInFirstHalfPlacesNewWindowFirst() {
        var layout = layout([1])
        layout.insert(2, context: InsertionContext(target: 1, cursor: Point(x: 100, y: 300), area: area, settings: settings))
        #expect(layout.windows == [2, 1])
    }

    @Test func removingAWindowGivesItsSpaceToTheSibling() {
        var layout = layout([1, 2, 3])
        layout.remove(2)
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[3] == Rect(x: 500, y: 0, width: 500, height: 600))
        #expect(layout.windows == [1, 3])
    }

    @Test func removingTheLastWindowEmptiesTheLayout() {
        var layout = layout([1])
        layout.remove(1)
        #expect(layout.isEmpty)
        layout.insert(2, context: InsertionContext(area: area, settings: settings))
        #expect(layout.boxes(in: area, settings: settings) == [2: area])
    }

    @Test func preselectionOverridesSplitDirection() throws {
        var layout = layout([1])
        _ = try layout.handle(LayoutMessage(parsing: "preselect up"), focused: 1, area: area, settings: settings)
        layout.insert(2, context: InsertionContext(target: 1, area: area, settings: settings))
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[2] == Rect(x: 0, y: 0, width: 1000, height: 300))
        #expect(layout.preselection == nil)
    }

    @Test func flipSplitTurnsTheParentSplit() throws {
        var layout = layout([1, 2])
        _ = try layout.handle(LayoutMessage(parsing: "flip-split"), focused: 1, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1] == Rect(x: 0, y: 0, width: 1000, height: 300))
    }

    @Test func unlockedSplitsFollowTheTileShape() {
        let layout = layout([1, 2])
        // A tall tile splits into windows on top of each other.
        let tall = Rect(x: 0, y: 0, width: 600, height: 1000)
        #expect(layout.boxes(in: tall, settings: settings)[1] == Rect(x: 0, y: 0, width: 600, height: 500))
    }

    @Test func swapSplitExchangesChildren() throws {
        var layout = layout([1, 2])
        _ = try layout.handle(LayoutMessage(parsing: "swap-split"), focused: 1, area: area, settings: settings)
        #expect(layout.windows == [2, 1])
    }

    @Test func keyboardResizeMovesTheDivider() {
        var layout = layout([1, 2])
        layout.resize(1, by: Size(width: 100, height: 0), corner: nil, area: area, settings: settings)
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[1]?.width == 600)
        #expect(boxes[2]?.width == 400)
    }

    @Test func resizeIsClampedToTheRatioRange() {
        var layout = layout([1, 2])
        layout.resize(1, by: Size(width: 5000, height: 0), corner: nil, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1]?.width == 950)
    }

    @Test func splitRatioCanBeSetExactly() {
        var layout = layout([1, 2])
        layout.alterSplitRatio(1, .exact(0.75), area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1]?.width == 750)
    }

    @Test func movingLeftReinsertsAtTheFocalPoint() {
        var layout = layout([1, 2, 3])
        let context = MoveContext(neighbor: 1, focalPoint: Point(x: 499, y: 450), area: area, settings: settings)
        let moved = layout.move(3, .left, context: context)
        #expect(moved)
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 500, height: 300))
        #expect(boxes[3] == Rect(x: 0, y: 300, width: 500, height: 300))
        #expect(boxes[2] == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func movingWithoutNeighbourIsANoOp() {
        var layout = layout([1, 2])
        let before = layout
        let moved = layout.move(1, .left, context: MoveContext(neighbor: nil, focalPoint: Point(x: -1, y: 300), area: area, settings: settings))
        #expect(!moved)
        #expect(layout == before)
    }

    @Test func moveToRootKeepsTheWindowOnItsSide() throws {
        var layout = layout([1, 2, 3])
        _ = try layout.handle(LayoutMessage(parsing: "promote"), focused: 3, area: area, settings: settings)
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[3] == Rect(x: 500, y: 0, width: 500, height: 600))
        #expect(boxes[2] == Rect(x: 0, y: 0, width: 500, height: 300))
        #expect(boxes[1] == Rect(x: 0, y: 300, width: 500, height: 300))
    }

    @Test func unknownMessagesAreRejected() {
        var layout = layout([1])
        do {
            _ = try layout.handle(LayoutMessage(parsing: "bogus"), focused: 1, area: area, settings: settings)
            Issue.record("expected an error")
        } catch {
            #expect(error == .unknownMessage("bogus", layout: .bsp))
        }
    }

    @Test func swapExchangesPositions() {
        var layout = layout([1, 2])
        layout.swap(1, 2)
        #expect(layout.boxes(in: area, settings: settings)[2] == Rect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func splitsMakeRoomForMinimumSizes() {
        let layout = BSPLayout(windows: [1, 2], area: area, settings: flatSettings())
        let boxes = layout.boxes(in: area, settings: flatSettings(), minimumSizes: [2: Size(width: 700, height: 100)])
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 300, height: 600))
        #expect(boxes[2] == Rect(x: 300, y: 0, width: 700, height: 600))
    }

    @Test func minimumsThatCannotAllFitShareTheSpace() {
        let layout = BSPLayout(windows: [1, 2], area: area, settings: flatSettings())
        let boxes = layout.boxes(in: area, settings: flatSettings(), minimumSizes: [1: Size(width: 900, height: 0), 2: Size(width: 600, height: 0)])
        #expect(boxes[1]?.width == 600)
        #expect(boxes[2]?.width == 400)
    }
}
