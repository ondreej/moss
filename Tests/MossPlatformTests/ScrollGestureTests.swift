import MossCore
import Testing
@testable import MossPlatform

@Suite("Scroll gestures")
struct ScrollGestureTests {
    let bound: (Direction) -> Bool = { _ in true }
    let unbound: (Direction) -> Bool = { _ in false }

    @Test func aSwipeTakesOneStepWhateverItsLength() {
        var gesture = ScrollGesture()
        #expect(gesture.handle(.began, isBound: bound) == .consume)
        #expect(gesture.handle(.moved(dx: 0, dy: -10), isBound: bound) == .consume)
        #expect(gesture.handle(.moved(dx: 0, dy: -20), isBound: bound) == .run(.down))
        for _ in 0..<20 {
            #expect(gesture.handle(.moved(dx: 0, dy: -30), isBound: bound) == .consume)
        }
        #expect(gesture.handle(.ended, isBound: bound) == .consume)
        // Coasting after the fingers lift does not take another step, nor reach the app.
        #expect(gesture.handle(.coasting(isLast: false), isBound: bound) == .consume)
        #expect(gesture.handle(.coasting(isLast: true), isBound: bound) == .consume)
        // The next swipe takes the next step.
        _ = gesture.handle(.began, isBound: bound)
        #expect(gesture.handle(.moved(dx: 0, dy: 30), isBound: bound) == .run(.up))
    }

    @Test func swipesWithoutAShortcutReachTheApplication() {
        var gesture = ScrollGesture()
        #expect(gesture.handle(.began, isBound: unbound) == .pass)
        #expect(gesture.handle(.moved(dx: 0, dy: 40), isBound: unbound) == .pass)
        #expect(gesture.handle(.ended, isBound: unbound) == .pass)
        #expect(gesture.handle(.coasting(isLast: false), isBound: unbound) == .pass)
    }

    @Test func sidewaysSwipesGoLeftOrRight() {
        var gesture = ScrollGesture()
        _ = gesture.handle(.began, isBound: bound)
        #expect(gesture.handle(.moved(dx: -30, dy: 5), isBound: bound) == .run(.right))
    }

    @Test func wheelNotchesStepOneByOne() {
        var gesture = ScrollGesture()
        #expect(gesture.handle(.notch(.down), isBound: bound) == .run(.down))
        #expect(gesture.handle(.notch(.down), isBound: bound) == .run(.down))
        #expect(gesture.handle(.notch(.up), isBound: unbound) == .pass)
    }
}
