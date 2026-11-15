import Testing
@testable import MossCore

@Suite("Tabs")
struct TabTests {
    /// Settings without gaps, borders or a tab bar, so frames equal layout boxes.
    func settings(tabBar: Bool = false) -> Settings {
        var settings = flatSettings()
        settings.tabs.showsBar = tabBar
        return settings
    }

    @Test func newWindowsJoinTheFocusedGroup() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        #expect(world.group(of: 1)?.members == [1, 2])
        #expect(world.group(of: 1)?.active == 2)
        #expect(world.frame(2) == area)
        #expect(world.arrangement().hidden[1] != nil)
        #expect(world.focusedWindowID == 2)
    }

    @Test func aFloatingGroupKeepsItsTabBarOnTheDisplay() throws {
        var world = makeWorld(settings: settings(tabBar: true))
        world.open(1)
        try world.run("float on")
        try world.run("tabs")
        world.windows[1]?.floatingFrame = Rect(x: 100, y: 0, width: 300, height: 200)
        let bar = world.tabBarHeight(world.settings)
        #expect(world.frame(1) == Rect(x: 100, y: bar, width: 300, height: 200))
    }

    @Test func switchingTabsChangesTheVisibleMember() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        try world.run("tab next")
        #expect(world.focusedWindowID == 1)
        #expect(world.frame(1) == area)
        #expect(world.arrangement().hidden[2] != nil)
        try world.run("tab 2")
        #expect(world.focusedWindowID == 2)
    }

    @Test func groupsKeepTheirPlaceInTheLayout() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        world.open(2)
        try world.run("tabs")
        world.open(3)
        #expect(world.frame(1) == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(world.frame(3) == Rect(x: 500, y: 0, width: 500, height: 600))
        try world.run("tab previous")
        #expect(world.frame(2) == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func moveOutOfGroupGivesTheWindowItsOwnTile() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        try world.run("leave-tabs")
        #expect(world.windows[2]?.group == nil)
        #expect(world.group(of: 1)?.members == [1])
        #expect(world.frame(1)?.width == 500)
        #expect(world.frame(2)?.width == 500)
    }

    @Test func closingTheActiveMemberShowsTheNextOne() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        world.open(3)
        world.removeWindow(3)
        #expect(world.group(of: 1)?.members == [1, 2])
        #expect(world.frame(world.group(of: 1)!.active) == area)
        world.removeWindow(1)
        world.removeWindow(2)
        #expect(world.groups.isEmpty)
    }

    @Test func togglingDissolvesTheGroup() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        try world.run("tabs")
        #expect(world.groups.isEmpty)
        #expect(world.windows.values.allSatisfy { $0.group == nil })
        #expect(world.frame(1)?.width == 500 && world.frame(2)?.width == 500)
    }

    @Test func moveIntoGroupFromANeighbour() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        var noAutoGroup = settings()
        noAutoGroup.tabs.autoJoin = false
        world.configure(settings: noAutoGroup)
        world.open(2)
        #expect(world.windows[2]?.group == nil)
        try world.run("join-tabs left")
        #expect(world.group(of: 1)?.members == [1, 2])
        #expect(world.frame(2) == area)
    }

    @Test func groupsMoveBetweenWorkspacesTogether() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        try world.run("move-to-workspace 3")
        #expect(world.windows[1]?.workspace == .numbered(3))
        #expect(world.windows[2]?.workspace == .numbered(3))
        #expect(world.frame(2) == area)
    }

    @Test func focusingAHiddenMemberActivatesIt() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        try world.run("focus-window id:0x1")
        #expect(world.group(of: 1)?.active == 1)
        #expect(world.frame(1) == area)
    }

    @Test func theTabBarTakesRoomAboveTheWindow() throws {
        var world = makeWorld(settings: settings(tabBar: true))
        world.open(1)
        try world.run("tabs")
        let bar = world.tabBarHeight(world.settings)
        #expect(world.frame(1) == Rect(x: 0, y: bar, width: 1000, height: 600 - bar))
    }

    @Test func groupsSurviveSessions() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        try world.run("tabs")
        world.open(2)
        world.open(3)
        try world.run("tab 2")
        let state = world.sessionState()

        var restarted = makeWorld(settings: settings())
        for id in [1, 2, 3] as [WindowID] {
            restarted.addWindow(id, properties: properties(), frame: Rect(x: 0, y: 0, width: 300, height: 200), origin: .existing)
        }
        restarted.restore(state)
        #expect(restarted.group(of: 1)?.members == world.group(of: 1)?.members)
        #expect(restarted.group(of: 1)?.active == 2)
        #expect(restarted.frame(2) == area)
        #expect(restarted.arrangement().hidden[1] != nil)
    }

    @Test func tabEvents() throws {
        var world = makeWorld(settings: settings())
        world.open(1)
        var before = world
        try world.run("tabs")
        #expect(world.events(since: before).contains(.tabsCreated([1])))
        before = world
        world.open(2)
        #expect(world.events(since: before).contains(.windowJoinedTabs(2)))
    }

    @Test func tabRules() throws {
        var world = makeWorld(settings: settings())
        world.configure(settings: settings(), windowRules: try WindowRule.rules(from: [("if.app", "tabbed"), ("tabs", "own")])
            + WindowRule.rules(from: [("if.app", "loner"), ("tabs", "never")]))
        world.open(1, app: "tabbed")
        #expect(world.group(of: 1)?.members == [1])
        world.open(2, app: "loner")
        #expect(world.windows[2]?.group == nil)
        try world.run("focus-window id:0x1")
        world.open(3)
        #expect(world.group(of: 1)?.members == [1, 3])
    }
}
