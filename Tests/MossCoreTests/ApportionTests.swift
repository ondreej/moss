import Testing
@testable import MossCore

@Suite("Apportioning space")
struct ApportionTests {
    @Test func preferredLengthsAreKeptWhenTheyAreLargeEnough() {
        #expect(apportion(100, preferred: [25, 75], minimums: [20, 0]) == [25, 75])
    }

    @Test func partsAtTheirMinimumLeaveTheRestToTheOthers() {
        #expect(apportion(90, preferred: [30, 30, 30], minimums: [0, 50, 0]) == [20, 50, 20])
    }

    @Test func minimumsThatDoNotFitShareTheExtentInProportion() {
        #expect(apportion(100, preferred: [50, 50], minimums: [120, 80]) == [60, 40])
    }
}
