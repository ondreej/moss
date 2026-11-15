import Testing
@testable import MossPlatform

/// The key mapping list is shared with the user's own mappings: only Moss's entry may change.
@Suite("Caps Lock remap")
struct CapsLockRemapTests {
    let escape = HIDKeyMapping(source: CapsLockRemap.capsLock, destination: 0x7_0000_0029)
    let swap = HIDKeyMapping(source: 0x7_0000_00E2, destination: 0x7_0000_00E3)

    @Test func addingKeepsOtherMappings() {
        let (list, replaced) = CapsLockRemap.adding(to: [swap])
        #expect(list == [swap, CapsLockRemap.entry])
        #expect(replaced == nil)
    }

    @Test func addingIsIdempotent() {
        let (list, _) = CapsLockRemap.adding(to: [swap, CapsLockRemap.entry])
        #expect(list == [swap, CapsLockRemap.entry])
    }

    @Test func aMappingOfCapsLockIsReplacedAndRestored() {
        let (list, replaced) = CapsLockRemap.adding(to: [escape, swap])
        #expect(list == [swap, CapsLockRemap.entry])
        #expect(replaced == escape)
        #expect(CapsLockRemap.removing(from: list, restoring: replaced) == [swap, escape])
    }

    @Test func removingLeavesForeignListsAlone() {
        #expect(CapsLockRemap.removing(from: [swap], restoring: escape) == [swap])
    }
}
