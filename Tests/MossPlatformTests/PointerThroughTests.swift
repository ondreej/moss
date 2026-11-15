import CoreGraphics
import Testing
@testable import MossPlatform

@Suite("Pointer pass-through")
struct PointerThroughTests {
    let display = CGRect(x: 0, y: 0, width: 6144, height: 2560)

    @Test func anOverlaySpreadOverAWholeDisplayLetsThePointerThrough() {
        #expect(MacWindowSystem.letsPointerThrough(owner: "Notification Center", layer: 21, bounds: display, displays: [display]))
    }

    @Test func menusAndPopoversStillCount() {
        let menu = CGRect(x: 120, y: 44, width: 280, height: 400)
        #expect(!MacWindowSystem.letsPointerThrough(owner: "Safari", layer: 101, bounds: menu, displays: [display]))
    }

    @Test func aWindowCoveringTheDisplayAtTheNormalLevelStillCounts() {
        // A video player in fullscreen of its own: hovering over it must not move focus.
        #expect(!MacWindowSystem.letsPointerThrough(owner: "Stremio", layer: 0, bounds: display, displays: [display]))
    }

    @Test func theDockLetsThePointerThroughEverywhere() {
        #expect(MacWindowSystem.letsPointerThrough(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 2400, width: 600, height: 160), displays: [display]))
    }
}
