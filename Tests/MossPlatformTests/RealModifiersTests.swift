import MossCore
import Testing
@testable import MossPlatform

@Suite("Real modifiers under Hyper")
struct RealModifiersTests {
    @Test func modifierKeysAlternateBetweenDownAndUp() {
        var held = RealModifiers()
        held.begin(holding: [])
        #expect(held.modifiers == [])
        held.keyChanged(56)  // left Shift down
        #expect(held.modifiers == .shift)
        held.keyChanged(58)  // left Option down
        #expect(held.modifiers == [.shift, .option])
        held.keyChanged(56)  // left Shift up
        #expect(held.modifiers == .option)
    }

    @Test func modifiersHeldBeforeCapsLockCountUntilReleased() {
        var held = RealModifiers()
        held.begin(holding: .shift)
        #expect(held.modifiers == .shift)
        held.keyChanged(60)  // the right Shift, held all along, goes up
        #expect(held.modifiers == [])
        held.keyChanged(60)  // and down again
        #expect(held.modifiers == .shift)
    }

    @Test func otherKeysAreNotModifiers() {
        var held = RealModifiers()
        let isModifier = held.keyChanged(4)
        #expect(!isModifier)
        held.begin(holding: .command)
        held.end()
        #expect(held.modifiers == [])
    }
}
