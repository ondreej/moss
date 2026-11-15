import Testing
@testable import MossCore

@Suite("Stack layout")
struct StackLayoutTests {
    let settings = flatSettings()

    func layout(_ windows: [WindowID], settings: Settings? = nil) -> StackLayout {
        StackLayout(windows: windows, area: area, settings: settings ?? self.settings)
    }

    @Test func firstWindowIsMainAndFillsTheArea() {
        let layout = layout([1])
        #expect(layout.mainWindows == [1])
        #expect(layout.boxes(in: area, settings: settings) == [1: area])
    }

    @Test func stackSitsBesideTheMainWindow() {
        let boxes = layout([1, 2, 3]).boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 550, height: 600))
        #expect(boxes[2] == Rect(x: 550, y: 0, width: 450, height: 300))
        #expect(boxes[3] == Rect(x: 550, y: 300, width: 450, height: 300))
    }

    @Test func centerOrientationAlternatesStackSides() {
        var settings = settings
        settings.layout.stack.side = .center
        let boxes = layout([1, 2, 3], settings: settings).boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 225, y: 0, width: 550, height: 600))
        #expect(boxes[2] == Rect(x: 775, y: 0, width: 225, height: 600))
        #expect(boxes[3] == Rect(x: 0, y: 0, width: 225, height: 600))
    }

    @Test func centerFallsBackWithTooFewStackWindows() {
        var settings = settings
        settings.layout.stack.side = .center
        let boxes = layout([1, 2], settings: settings).boxes(in: area, settings: settings)
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 550, height: 600))
    }

    @Test func theMainColumnMakesRoomForAWideStackWindow() {
        let boxes = layout([1, 2, 3]).boxes(in: area, settings: settings, minimumSizes: [2: Size(width: 600, height: 0)])
        #expect(boxes[1] == Rect(x: 0, y: 0, width: 400, height: 600))
        #expect(boxes[2] == Rect(x: 400, y: 0, width: 600, height: 300))
    }

    @Test func stackWindowsMakeRoomForATallNeighbour() {
        let boxes = layout([1, 2, 3]).boxes(in: area, settings: settings, minimumSizes: [2: Size(width: 0, height: 400)])
        #expect(boxes[2] == Rect(x: 550, y: 0, width: 450, height: 400))
        #expect(boxes[3] == Rect(x: 550, y: 400, width: 450, height: 200))
    }

    @Test func centeredSidesMakeRoomForAWideMainWindow() {
        var settings = settings
        settings.layout.stack.side = .center
        let boxes = layout([1, 2, 3], settings: settings).boxes(in: area, settings: settings, minimumSizes: [1: Size(width: 750, height: 0)])
        #expect(boxes[1] == Rect(x: 125, y: 0, width: 750, height: 600))
        #expect(boxes[2] == Rect(x: 875, y: 0, width: 125, height: 600))
        #expect(boxes[3] == Rect(x: 0, y: 0, width: 125, height: 600))
    }

    @Test func newWindowsCanBecomeTheMainWindow() {
        var settings = settings
        settings.layout.stack.newWindow = .main
        let layout = layout([1, 2], settings: settings)
        #expect(layout.mainWindows == [2])
        #expect(layout.windows == [2, 1])
    }

    @Test func closingTheMainWindowPromotesTheFirstStackWindow() {
        var layout = layout([1, 2, 3])
        layout.remove(1)
        #expect(layout.mainWindows == [2])
    }

    @Test func swapMain() throws {
        var layout = layout([1, 2, 3])
        let outcome = try layout.handle(LayoutMessage(parsing: "swap-main"), focused: 3, area: area, settings: settings)
        #expect(layout.mainWindows == [3])
        #expect(outcome.focus == 3)
    }

    @Test func mainCount() throws {
        var layout = layout([1, 2, 3])
        _ = try layout.handle(LayoutMessage(parsing: "main-count +1"), focused: 1, area: area, settings: settings)
        #expect(layout.mainWindows == [1, 2])
        _ = try layout.handle(LayoutMessage(parsing: "main-count -1"), focused: 1, area: area, settings: settings)
        #expect(layout.mainWindows == [1])
        _ = try layout.handle(LayoutMessage(parsing: "main-count -1"), focused: 1, area: area, settings: settings)
        #expect(layout.mainWindows == [1])
    }

    @Test func mainSize() throws {
        var layout = layout([1, 2])
        _ = try layout.handle(LayoutMessage(parsing: "main-size 0.7"), focused: 1, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1]?.width == 700)
        _ = try layout.handle(LayoutMessage(parsing: "main-size -0.2"), focused: 1, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1]?.isApproximatelyEqual(to: Rect(x: 0, y: 0, width: 500, height: 600), tolerance: 0.001) == true)
    }

    @Test func stackSide() throws {
        var layout = layout([1, 2])
        _ = try layout.handle(LayoutMessage(parsing: "stack-side right"), focused: 1, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1]?.isApproximatelyEqual(to: Rect(x: 450, y: 0, width: 550, height: 600), tolerance: 0.001) == true)
        _ = try layout.handle(LayoutMessage(parsing: "stack-side top"), focused: 1, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1] == Rect(x: 0, y: 0, width: 1000, height: 330))
    }

    @Test func horizontalResizeChangesTheMainSize() {
        var layout = layout([1, 2])
        layout.resize(1, by: Size(width: 100, height: 0), corner: nil, area: area, settings: settings)
        #expect(layout.boxes(in: area, settings: settings)[1]?.width == 650)
    }

    @Test func verticalResizeTradesSpaceWithTheNeighbour() {
        var layout = layout([1, 2, 3])
        layout.resize(2, by: Size(width: 0, height: 60), corner: nil, area: area, settings: settings)
        let boxes = layout.boxes(in: area, settings: settings)
        #expect(boxes[2]?.height == 360)
        #expect(boxes[3]?.height == 240)
    }

    @Test func rotate() throws {
        var layout = layout([1, 2, 3])
        _ = try layout.handle(LayoutMessage(parsing: "rotate next"), focused: 1, area: area, settings: settings)
        #expect(layout.windows == [2, 3, 1])
        #expect(layout.mainWindows == [2])
    }
}
