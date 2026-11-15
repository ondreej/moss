import Foundation
import Testing
@testable import MossCore

@Suite("World")
struct WorldTests {
    @Test func layoutActionChangesTheWorkspaceAndTheFocusedWindowTakesTheMainArea() throws {
        var world = makeWorld()
        for id: WindowID in [1, 2, 3, 4, 5] { world.open(id) }
        _ = try world.perform(Action(parsing: "focus-window id:0x3"))
        _ = try world.perform(Action(parsing: "layout toggle stack"))
        let workspace = try #require(world.focusedWorkspaceID)
        #expect(world.workspaces[workspace]?.tiling.kind == .stack)
        #expect(world.workspaces[workspace]?.tiling.windows.first == 3)
        #expect(Set(world.workspaces[workspace]?.tiling.windows ?? []) == [1, 2, 3, 4, 5])

        // A reloaded configuration keeps the layout chosen for the workspace…
        world.configure(settings: flatSettings())
        #expect(world.workspaces[workspace]?.tiling.kind == .stack)

        // …and toggling again goes back to the configured one.
        _ = try world.perform(Action(parsing: "layout toggle stack"))
        #expect(world.workspaces[workspace]?.tiling.kind == .bsp)
        #expect(world.workspaces[workspace]?.layoutOverride == nil)
    }

    @Test func aCenteredStackPutsTheFocusedWindowInTheMiddle() throws {
        var settings = flatSettings()
        settings.layout.stack.side = .center
        var world = makeWorld(settings: settings)
        for id: WindowID in [1, 2, 3, 4, 5] { world.open(id) }
        _ = try world.perform(Action(parsing: "focus-window id:0x2"))
        _ = try world.perform(Action(parsing: "layout stack"))
        let main = try #require(world.frame(2))
        #expect(main.height == 600)
        #expect(main.minX > 0 && main.maxX < 1000)
    }

    @Test func defaultGapsAndBorders() {
        var world = makeWorld(settings: Settings())
        world.open(1)
        world.open(2)
        // Margins of 8 at the edges, a gap of 8 between the windows, and a border of 1 around each.
        #expect(world.frame(1) == Rect(x: 9, y: 9, width: 486, height: 582))
        #expect(world.frame(2) == Rect(x: 505, y: 9, width: 486, height: 582))
    }

    @Test func openingAWindowFocusesIt() {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        #expect(world.focusedWindowID == 2)
        #expect(world.windows[2]?.workspace == .numbered(1))
    }

    @Test func dialogsFloat() {
        var world = makeWorld()
        world.open(1, kind: .dialog)
        #expect(world.windows[1]?.isFloating == true)
        #expect(world.frame(1) == Rect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func switchingWorkspacesHidesWindows() throws {
        var world = makeWorld()
        world.open(1)
        try world.run("workspace 2")
        #expect(world.activeWorkspaceID == .numbered(2))
        #expect(world.arrangement().hidden[1] == 1)
        #expect(world.focusedWindowID == nil)

        world.open(2)
        try world.run("workspace 1")
        #expect(world.focusedWindowID == 1)
        #expect(world.workspaces[.numbered(2)] != nil)
    }

    @Test func emptyWorkspacesAreDestroyedWhenLeft() throws {
        var world = makeWorld()
        try world.run("workspace 3")
        try world.run("workspace 1")
        #expect(world.workspaces[.numbered(3)] == nil)
    }

    @Test func backAndForth() throws {
        var settings = flatSettings()
        settings.workspaces.backAndForth = true
        var world = makeWorld(settings: settings)
        world.open(1)
        try world.run("workspace 4")
        world.open(2)
        try world.run("workspace 4")
        #expect(world.activeWorkspaceID == .numbered(1))
        try world.run("workspace last")
        #expect(world.activeWorkspaceID == .numbered(4))
    }

    @Test func relativeWorkspaces() throws {
        var world = makeWorld()
        world.open(1)
        try world.run("workspace +2")
        #expect(world.activeWorkspaceID == .numbered(3))
        world.open(2)
        try world.run("workspace next")
        #expect(world.activeWorkspaceID == .numbered(1))
        try world.run("workspace previous")
        #expect(world.activeWorkspaceID == .numbered(3))
        try world.run("workspace empty")
        #expect(world.activeWorkspaceID == .numbered(2))
    }

    @Test func moveToWorkspaceFollowsTheWindow() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        try world.run("move-to-workspace 3")
        #expect(world.activeWorkspaceID == .numbered(3))
        #expect(world.focusedWindowID == 2)
        #expect(world.frame(2) == area)
    }

    @Test func moveToWorkspaceSilentStays() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        try world.run("send-to-workspace 3")
        #expect(world.activeWorkspaceID == .numbered(1))
        #expect(world.focusedWindowID == 1)
        #expect(world.frame(1) == area)
        #expect(world.arrangement().hidden[2] != nil)
    }

    @Test func toggleFloatingCentresOnTheTile() throws {
        var world = makeWorld()
        world.open(1, frame: Rect(x: 0, y: 0, width: 200, height: 100))
        world.open(2)
        try world.run("focus-window id:0x1")
        try world.run("float")
        #expect(world.windows[1]?.isFloating == true)
        #expect(world.frame(2) == area)
        #expect(world.frame(1) == Rect(x: 150, y: 250, width: 200, height: 100))
        try world.run("float")
        #expect(world.windows[1]?.isFloating == false)
    }

    @Test func fullscreenModes() throws {
        var settings = flatSettings()
        settings.layout.margins = Insets(all: 10)
        var world = makeWorld(settings: settings)
        world.open(1)
        world.open(2)
        try world.run("fullscreen")
        #expect(world.frame(2) == area)
        #expect(world.arrangement().stack.last == 2)
        try world.run("maximize")
        #expect(world.frame(2) == Rect(x: 10, y: 10, width: 980, height: 580))
        try world.run("maximize")
        #expect(world.windows[2]?.fullscreen == nil)
    }

    @Test func scratchpadsToggle() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        try world.run("send-to-workspace scratchpad:notes")
        #expect(world.arrangement().hidden[2] != nil)
        try world.run("scratchpad notes")
        #expect(world.focusedWindowID == 2)
        #expect(world.frame(2) == area)
        try world.run("scratchpad notes")
        #expect(world.arrangement().hidden[2] != nil)
        #expect(world.focusedWindowID == 1)
    }

    @Test func scratchpadsCloseWhenEmptied() throws {
        var world = makeWorld()
        world.open(1)
        try world.run("move-to-workspace scratchpad")
        #expect(world.focusedMonitor?.activeScratchpad == .scratchpad(WorkspaceID.defaultScratchpadName))
        world.removeWindow(1)
        #expect(world.focusedMonitor?.activeScratchpad == nil)
    }

    @Test func moveFocusBetweenTiles() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        world.open(3)
        try world.run("focus left")
        #expect(world.focusedWindowID == 1)
        try world.run("focus right")
        #expect(world.focusedWindowID == 3)
        try world.run("focus up")
        #expect(world.focusedWindowID == 2)
    }

    @Test func moveFocusWarpsTheCursor() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        world.cursor = Point(x: 900, y: 300)
        let effects = try world.perform(Action(parsing: "focus left"))
        #expect(effects == [.warpCursor(Point(x: 250, y: 300))])
    }

    @Test func focusAndWindowsCrossMonitors() throws {
        var world = makeWorld(monitors: 2)
        world.open(1)
        try world.run("focus right")
        #expect(world.focusedMonitorID == 2)
        #expect(world.focusedWindowID == nil)
        try world.run("focus left")
        #expect(world.focusedWindowID == 1)
        try world.run("move right")
        #expect(world.windows[1]?.workspace == .numbered(2))
        #expect(world.frame(1) == Rect(x: 1000, y: 0, width: 1000, height: 600))
        #expect(world.focusedMonitorID == 2)
    }

    @Test func workspacesFollowTheirMonitor() throws {
        var world = makeWorld(monitors: 2)
        try world.run("focus-display right")
        world.open(1)
        try world.run("focus-display left")
        try world.run("workspace 2")
        #expect(world.focusedMonitorID == 2)
        #expect(world.focusedWindowID == 1)
    }

    @Test func closingTheFocusedWindowFocusesTheLastOne() {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        world.open(3)
        world.removeWindow(3)
        #expect(world.focusedWindowID == 2)
        #expect(world.frame(1) == Rect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func windowRulesApplyOnOpen() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), windowRules: try [
            WindowRule.rules(from: [("if.app", "^com\\.example\\.calculator$"), ("float", "true")]),
            WindowRule.rules(from: [("if.app", "music"), ("workspace", "4"), ("silent", "true")]),
        ].flatMap(\.self))
        world.open(1, app: "com.example.calculator")
        world.open(2, app: "com.example.music")
        #expect(world.windows[1]?.isFloating == true)
        #expect(world.windows[2]?.workspace == .numbered(4))
        #expect(world.activeWorkspaceID == .numbered(1))
    }

    @Test func decorationRulesApplyOnOpenAndFollowFocus() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), windowRules: try [
            WindowRule.rules(from: [("if.app", "^com\\.example\\.app$"), ("border-width", "7")]),
            WindowRule.rules(from: [("if.focused", "true"), ("border-width", "9")]),
        ].flatMap(\.self))
        world.open(1)
        world.open(2)
        #expect(world.windows[1]?.overrides.borderWidth == 7)
        #expect(world.windows[2]?.overrides.borderWidth == 9)
        world.handleFocusChange(to: 1)
        #expect(world.windows[1]?.overrides.borderWidth == 9)
        #expect(world.windows[2]?.overrides.borderWidth == 7)
    }

    @Test func rulesFollowTitleChanges() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), windowRules: try WindowRule.rules(from: [("if.title", "Draft"), ("dim", "false")]))
        world.open(1)
        #expect(world.windows[1]?.overrides.noDim == false)
        world.updateWindow(1, properties: properties(title: "Draft"))
        #expect(world.windows[1]?.overrides.noDim == true)
        world.updateWindow(1, properties: properties(title: "Sent"))
        #expect(world.windows[1]?.overrides.noDim == false)
    }

    @Test func tagsLetRulesBuildOnEachOther() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), windowRules: try [
            WindowRule.rules(from: [("if.app", "^com\\.example\\.terminal$"), ("tag", "term")]),
            WindowRule.rules(from: [("if.tag", "term"), ("corner-radius", "0")]),
            WindowRule.rules(from: [("if.tag", "pinned"), ("border-width", "3")]),
        ].flatMap(\.self))
        world.open(1, app: "com.example.terminal")
        #expect(world.windows[1]?.ruleTags == ["term"])
        #expect(world.windows[1]?.overrides.cornerRadius == 0)
        try world.run("tag +pinned")
        #expect(world.windows[1]?.overrides.borderWidth == 3)
        try world.run("tag pinned")
        #expect(world.windows[1]?.tags.isEmpty == true)
        #expect(world.windows[1]?.overrides.borderWidth == nil)
    }

    @Test func stayFocusedWindowsKeepFocus() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), windowRules: try WindowRule.rules(from: [("if.title", "Password"), ("keep-focus", "true")]))
        world.open(1)
        world.open(2, title: "Password")
        #expect(world.focusedWindowID == 2)
        world.handleFocusChange(to: 1)
        #expect(world.focusedWindowID == 2)
        try world.run("workspace 2")
        world.open(3)
        #expect(world.focusedWindowID == 3)
    }

    @Test func floatingSizeLimits() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), windowRules: try WindowRule.rules(from: [
            ("if.app", "x"), ("float", "true"), ("min-size", "300 200"), ("max-size", "500 400"),
        ]))
        world.open(1, app: "x", frame: Rect(x: 100, y: 100, width: 100, height: 100))
        #expect(world.windows[1]?.floatingFrame.size == Size(width: 300, height: 200))
        try world.run("resize to 900 900")
        #expect(world.windows[1]?.floatingFrame.size == Size(width: 500, height: 400))
    }

    @Test func floatingWindowsMovedOrGrownByActionsStayOnTheDisplay() throws {
        var world = makeWorld()
        world.open(1)
        try world.run("float on")
        world.windows[1]?.floatingFrame = Rect(x: 100, y: 100, width: 300, height: 200)
        try world.run("position by 2000 2000")
        #expect(world.windows[1]?.floatingFrame == Rect(x: 700, y: 400, width: 300, height: 200))
        try world.run("resize by 5000 0")
        #expect(world.windows[1]?.floatingFrame == Rect(x: 0, y: 400, width: 1000, height: 200))
    }

    @Test func whenEmptyRunsWhenSwitchingToANewWorkspace() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), workspaceRules: [try WorkspaceRule(workspace: .numbered(3), entries: [("when-empty", "[float] open -a Notes")])])
        world.open(1)
        let effects = try world.perform(Action(parsing: "workspace 3"))
        #expect(effects.contains(.run("open -a Notes")))
        #expect(world.pendingRunRules.first?.effects == [.float])
        // Moving a window there does not count: the workspace is not created empty.
        try world.run("workspace 1")
        let moved = try world.perform(Action(parsing: "move-to-workspace 3"))
        #expect(!moved.contains(.run("open -a Notes")))
    }

    @Test func workspaceRuleDecorationsAndNames() throws {
        var settings = flatSettings()
        settings.borders.width = 3
        var world = makeWorld(settings: settings)
        world.configure(settings: settings, workspaceRules: [
            try WorkspaceRule(workspace: .numbered(2), entries: [("name", "Web"), ("decorations", "false"), ("square-corners", "true"), ("stack-side", "right")]),
        ])
        #expect(world.displayName(of: .numbered(2)) == "Web")
        #expect(world.settings(for: .numbered(2)).borders.width == 0)
        #expect(world.settings(for: .numbered(2)).borders.cornerRadius == 0)
        #expect(world.settings(for: .numbered(2)).layout.stack.side == .right)
        #expect(world.settings(for: .numbered(1)).borders.width == 3)
    }

    @Test func workspaceRulesOverrideGaps() throws {
        var world = makeWorld(settings: Settings())
        world.configure(settings: Settings(), workspaceRules: [try WorkspaceRule(workspace: .numbered(1), entries: [("margins", "0"), ("gaps", "0"), ("border-width", "0")])])
        world.open(1)
        #expect(world.frame(1) == area)
    }

    @Test func persistentWorkspacesSurvive() throws {
        var world = makeWorld()
        world.configure(settings: flatSettings(), workspaceRules: [try WorkspaceRule(workspace: .numbered(5), entries: [("persistent", "true")])])
        #expect(world.workspaces[.numbered(5)] != nil)
        try world.run("workspace 5")
        try world.run("workspace 1")
        #expect(world.workspaces[.numbered(5)] != nil)
    }

    @Test func mouseMoveDropsTiledWindowsAtTheCursor() {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        let began = world.beginInteraction(.move, window: 2, cursor: Point(x: 700, y: 300))
        #expect(began)
        #expect(world.frame(1) == area)
        world.updateInteraction(cursor: Point(x: 200, y: 300))
        world.endInteraction(cursor: Point(x: 200, y: 300))
        #expect(world.windows[2]?.isFloating == false)
        #expect(world.frame(2) == Rect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func mouseResizeOfFloatingWindow() {
        var world = makeWorld()
        world.open(1, frame: Rect(x: 100, y: 100, width: 200, height: 200), kind: .dialog)
        world.beginInteraction(.resize, window: 1, cursor: Point(x: 290, y: 290))
        world.endInteraction(cursor: Point(x: 340, y: 310))
        #expect(world.frame(1) == Rect(x: 100, y: 100, width: 250, height: 220))
    }

    @Test func layoutCanBeSwitchedOnReload() {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        world.open(3)
        var settings = flatSettings()
        settings.layout.style = .stack
        world.configure(settings: settings)
        #expect(world.frame(1) == Rect(x: 0, y: 0, width: 550, height: 600))
    }

    @Test func events() throws {
        var world = makeWorld()
        var before = world
        world.open(1, app: "org.example.term", title: "shell")
        let opened = world.events(since: before)
        #expect(opened.contains(.windowOpened(1, workspace: "1", bundleID: "org.example.term", title: "shell")))
        #expect(opened.contains(.windowFocused(1, bundleID: "org.example.term", title: "shell")))

        before = world
        try world.run("workspace 2")
        let switched = world.events(since: before)
        #expect(switched.contains(.workspaceShown(workspace: "2", name: "2", display: "Display 1")))
        #expect(switched.contains(.workspaceCreated("2")))
        #expect(switched.contains(.windowFocused(nil, bundleID: "", title: "")))
    }

    @Test func fullscreenEventsNameTheWindowThatChanged() throws {
        var settings = flatSettings()
        settings.fullscreen.newWindow = .exit
        var world = makeWorld(settings: settings)
        world.open(1)
        try world.run("fullscreen on")
        var before = world
        world.open(2)
        // The new window ends fullscreen for window 1, and takes focus.
        let events = world.events(since: before).filter { if case .fullscreenChanged = $0 { true } else { false } }
        #expect(events == [.fullscreenChanged(1, isFullscreen: false)])

        before = world
        try world.run("focus-window id:0x1")
        #expect(!world.events(since: before).contains { if case .fullscreenChanged = $0 { true } else { false } })
    }

    @Test func layoutActionsReachTheLayout() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        try world.run("swap-split")
        #expect(world.frame(2) == Rect(x: 0, y: 0, width: 500, height: 600))
        // An action of another layout is refused.
        var copy = world
        #expect(throws: ActionError.self) { try copy.perform(Action(parsing: "column-width next")) }
    }

    @Test func sessionsRoundTrip() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        try world.run("send-to-workspace 3")
        world.open(3, kind: .dialog)
        let state = world.sessionState()

        var restarted = makeWorld()
        for id in [1, 2, 3] as [WindowID] {
            restarted.addWindow(id, properties: properties(), frame: Rect(x: 0, y: 0, width: 300, height: 200), origin: .existing)
        }
        restarted.restore(state)
        #expect(restarted.windows[2]?.workspace == .numbered(3))
        #expect(restarted.windows[3]?.isFloating == true)
        #expect(restarted.windows[3]?.floatingFrame == world.windows[3]?.floatingFrame)
        #expect(restarted.frame(1) == area)
        #expect(restarted.focusedWindowID == world.focusedWindowID)
    }

    @Test func sessionsFromOtherVersionsDecode() throws {
        let older = #"{"placements":[],"activeWorkspaces":[]}"#
        let state = try JSONDecoder().decode(SessionState.self, from: Data(older.utf8))
        #expect(state.groups.isEmpty)
    }

    @Test func runRulesApplyToTheWindowTheCommandOpens() throws {
        var world = makeWorld()
        world.open(1)
        let effects = try world.perform(Action(parsing: "run [workspace=3, silent, float] open -na \"Example Terminal\""))
        #expect(effects.contains(.run("open -na \"Example Terminal\"")))
        #expect(world.pendingRunRules.first?.application == "Example Terminal")

        // A window from another application is not affected.
        world.addWindow(2, properties: WindowProperties(appID: "com.example.other", appName: "Other"), frame: .zero)
        #expect(world.windows[2]?.workspace == .numbered(1))

        world.addWindow(3, properties: WindowProperties(appID: "com.example.terminal", appName: "Example Terminal"), frame: Rect(x: 0, y: 0, width: 300, height: 200))
        #expect(world.windows[3]?.workspace == .numbered(3))
        #expect(world.windows[3]?.isFloating == true)
        #expect(world.pendingRunRules.isEmpty)
        #expect(throws: ActionError.self) { try Action(parsing: "run [sparkle] true") }
    }

    @Test func pinnedWindowsFollowWorkspaceSwitches() throws {
        var world = makeWorld()
        world.open(1, kind: .dialog)
        try world.run("pin")
        try world.run("workspace 2")
        #expect(world.windows[1]?.workspace == .numbered(2))
        #expect(world.arrangement().frames[1] != nil)
    }

    @Test func ruleBordersMakeRoomInTheLayout() throws {
        var settings = flatSettings()
        settings.borders.width = 2
        var world = makeWorld(settings: settings)
        world.configure(settings: settings, windowRules: try WindowRule.rules(from: [("if.tag", "wide"), ("border-width", "10")]))
        world.open(1)
        #expect(world.frame(1) == Rect(x: 2, y: 2, width: 996, height: 596))
        try world.run("tag +wide")
        #expect(world.windows[1]?.overrides.borderWidth == 10)
        #expect(world.frame(1) == Rect(x: 10, y: 10, width: 980, height: 580))
        try world.run("tag -wide")
        #expect(world.frame(1) == Rect(x: 2, y: 2, width: 996, height: 596))
    }

    @Test func signalsAndKeysGoToTheTargetProcess() throws {
        var world = makeWorld()
        world.open(1)
        #expect(try world.perform(Action(parsing: "signal TERM")) == [.signal(pid: 1, 15)])
        let effects = try world.perform(Action(parsing: "send-keys cmd-v"))
        #expect(effects == [.sendKeys(KeyChord(modifiers: .command, key: .key("v")), pid: 1)])
    }

    @Test func fullscreenSwitches() throws {
        var world = makeWorld()
        world.open(1)
        try world.run("maximize on")
        #expect(world.windows[1]?.fullscreen == .maximized)
        try world.run("maximize on")
        #expect(world.windows[1]?.fullscreen == .maximized)
        try world.run("fullscreen on")
        #expect(world.windows[1]?.fullscreen == .fullscreen)
        try world.run("fullscreen off")
        #expect(world.windows[1]?.fullscreen == nil)
    }

    func display(_ index: Int, id: UInt32? = nil) -> DisplayDescription {
        let frame = Rect(x: Double(index) * 1000, y: 0, width: 1000, height: 600)
        return DisplayDescription(id: MonitorID(id ?? UInt32(index + 1)), name: "Display \(index + 1)", frame: frame, visibleFrame: frame, isMain: index == 0)
    }

    @Test func workspacesGoHomeWhenTheirMonitorReturns() throws {
        var world = makeWorld(monitors: 2)
        try world.run("focus-display 2")
        world.open(1)
        world.open(2, frame: Rect(x: 1600, y: 100, width: 300, height: 200))
        try world.run("float on id:0x2")
        let workspace = try #require(world.windows[1]?.workspace)
        let floating = try #require(world.windows[2]?.floatingFrame)
        #expect(world.workspaces[workspace]?.monitor == MonitorID(2))

        world.updateDisplays([display(0)])
        #expect(world.workspaces[workspace]?.monitor == MonitorID(1))
        // The floating window moves along instead of staying where the display was.
        #expect(Rect(x: 0, y: 0, width: 1000, height: 600).contains(world.windows[2]!.floatingFrame.center))

        world.updateDisplays([display(0), display(1)])
        #expect(world.workspaces[workspace]?.monitor == MonitorID(2))
        #expect(world.monitor(MonitorID(2))?.activeWorkspace == workspace)
        #expect(world.monitor(MonitorID(1))?.activeWorkspace == .numbered(1))
        #expect(world.windows[2]?.floatingFrame == floating)
        #expect(world.frame(1)?.minX ?? 0 >= 1000)
    }

    @Test func aReconnectedDisplayIsRecognisedByName() throws {
        var world = makeWorld(monitors: 2)
        try world.run("focus-display 2")
        world.open(1)
        let workspace = try #require(world.windows[1]?.workspace)
        world.updateDisplays([display(0)])
        world.updateDisplays([display(0), display(1, id: 77)])
        #expect(world.workspaces[workspace]?.monitor == MonitorID(77))
        #expect(world.monitor(MonitorID(77))?.activeWorkspace == workspace)
    }

    @Test func homesSurviveARestartWhileTheDisplayIsAway() throws {
        var world = makeWorld(monitors: 2)
        try world.run("focus-display 2")
        world.open(1)
        let workspace = try #require(world.windows[1]?.workspace)
        world.updateDisplays([display(0)])
        let data = try JSONEncoder().encode(world.sessionState())

        var restarted = makeWorld(monitors: 1)
        restarted.addWindow(1, properties: properties(), frame: Rect(x: 100, y: 100, width: 300, height: 200), origin: .existing)
        restarted.restore(try JSONDecoder().decode(SessionState.self, from: data))
        #expect(restarted.workspaces[workspace]?.home?.name == "Display 2")
        restarted.updateDisplays([display(0), display(1)])
        #expect(restarted.workspaces[workspace]?.monitor == MonitorID(2))
    }

    @Test func dropTargetsPreviewTheTileAWindowWouldTake() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        // Dragging window 2 over the left half of window 1 puts it on the left.
        #expect(world.dropTarget(for: 2, at: Point(x: 100, y: 300)) == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(world.frame(2) == Rect(x: 500, y: 0, width: 500, height: 600))

        world.beginInteraction(.move, window: 2, cursor: Point(x: 700, y: 300))
        world.updateInteraction(cursor: Point(x: 100, y: 300))
        #expect(world.dropTarget(for: 2, at: Point(x: 100, y: 300)) == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(world.interaction != nil)

        try world.run("float on id:0x1")
        #expect(world.dropTarget(for: 1, at: Point(x: 100, y: 300)) == nil)
    }

    @Test func learnedMinimumSizesReshapeTheLayout() {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        let learned = world.learnMinimumSize(of: 2, observed: Size(width: 650, height: 600), requested: Size(width: 500, height: 600))
        let jitter = world.learnMinimumSize(of: 2, observed: Size(width: 504, height: 600), requested: Size(width: 500, height: 600))
        #expect(learned)
        #expect(!jitter)
        #expect(world.frame(2) == Rect(x: 350, y: 0, width: 650, height: 600))
        #expect(world.frame(1) == Rect(x: 0, y: 0, width: 350, height: 600))
    }

    @Test func aNewWindowBesideOneAsLargeAsItsTileStillGetsRoom() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        world.windows[2]?.minimumTileSize = Size(width: 495, height: 300)
        try world.run("focus-window id:0x2")
        try world.run("preselect right")
        world.open(3)
        let frames = try [1, 2, 3].map { try #require(world.frame(WindowID($0))) }
        #expect(frames[2].width >= 100)
        #expect(frames[1].width >= 495)
        #expect(frames[0].width + frames[1].width + frames[2].width == 1000)
    }

    @Test func onlyDeclaredModesCanBeEntered() throws {
        var world = makeWorld()
        world.configure(settings: world.settings, modes: ["resize"])
        #expect(throws: ActionError.noSuchMode("reszie")) { try world.run("mode reszie") }
        #expect(world.mode == nil)
        try world.run("mode resize")
        #expect(world.mode == "resize")
        // A mode the configuration no longer declares is left.
        world.configure(settings: world.settings)
        #expect(world.mode == nil)
    }

    @Test func floatingWindowsSnapToEdgesNearby() throws {
        var settings = flatSettings()
        settings.floating.snaps = true
        settings.floating.snapDistance = 10
        var world = makeWorld(settings: settings)
        world.open(1)
        world.open(2)
        world.open(3)
        try world.run("float on id:0x3")
        world.windows[3]?.floatingFrame = Rect(x: 300, y: 200, width: 200, height: 100)
        world.beginInteraction(.move, window: 3, cursor: Point(x: 400, y: 250))
        // Near the display's left edge, it joins it…
        world.updateInteraction(cursor: Point(x: 106, y: 250))
        #expect(world.windows[3]?.floatingFrame.origin == Point(x: 0, y: 200))
        // …and away from every edge, it follows the cursor.
        world.updateInteraction(cursor: Point(x: 160, y: 250))
        #expect(world.windows[3]?.floatingFrame.origin == Point(x: 60, y: 200))
        // Near the edge between the two tiles, its right edge joins it.
        world.updateInteraction(cursor: Point(x: 395, y: 250))
        #expect(world.windows[3]?.floatingFrame.origin == Point(x: 300, y: 200))
        world.endInteraction(cursor: Point(x: 395, y: 250))

        // Without `floating.snap`, windows go where they are put.
        settings.floating.snaps = false
        world.configure(settings: settings)
        world.windows[3]?.floatingFrame = Rect(x: 6, y: 200, width: 200, height: 100)
        world.settleFloatingWindow(3)
        #expect(world.windows[3]?.floatingFrame.origin == Point(x: 6, y: 200))
    }

    @Test func tilesTheLayoutMakesEqualComeOutEqual() throws {
        var settings = flatSettings()
        settings.layout.gaps = Insets(all: 8)
        settings.layout.margins = Insets(all: 8)
        var world = makeWorld(settings: settings)
        world.open(1)
        world.open(2)
        let (left, right) = try (#require(world.frame(1)), #require(world.frame(2)))
        // The margins at the screen's edges, the gap between the windows, and equal halves.
        #expect(left.minX == 8 && right.maxX == 992 && left.minY == 8 && left.maxY == 592)
        #expect(right.minX - left.maxX == 8)
        #expect(left.width == right.width)

        try world.run("layout stack")
        for id in 3...5 { world.open(WindowID(UInt32(id))) }
        let stacked = world.workspaces[.numbered(1)]!.tiling.windows.dropFirst().compactMap { world.frame($0)?.height }
        #expect(stacked.count == 4)
        #expect(stacked.max()! - stacked.min()! <= 1)
    }

    @Test func aRestartedSessionPutsBackLayoutsAndFullscreen() throws {
        var world = makeWorld()
        for id in 1...4 { world.open(WindowID(UInt32(id))) }
        try world.run("focus-window id:0x2")
        try world.run("split-ratio 0.3")
        try world.run("flip-split")
        try world.run("workspace 2")
        world.open(5)
        world.open(6)
        try world.run("layout stack")
        try world.run("fullscreen on")
        try world.run("workspace 1")
        let frames = (1...4).map { world.frame(WindowID(UInt32($0))) }
        let data = try JSONEncoder().encode(world.sessionState())

        // The same windows, found again in another order after a restart.
        var restarted = makeWorld()
        for id in [6, 4, 2, 5, 3, 1] { restarted.open(WindowID(UInt32(id))) }
        restarted.restore(try JSONDecoder().decode(SessionState.self, from: data))
        #expect((1...4).map { restarted.frame(WindowID(UInt32($0))) } == frames)
        #expect(restarted.workspaces[.numbered(2)]?.tiling.kind == .stack)
        #expect(restarted.workspaces[.numbered(2)]?.layoutOverride == .stack)
        #expect(restarted.windows[6]?.fullscreen == .fullscreen)
    }

    @Test func aTileDroppedInTheMiddleOfAnotherTradesPlacesWithIt() throws {
        var world = makeWorld()
        world.open(1)
        world.open(2)
        try world.run("focus-window id:0x1")
        try world.run("split-ratio 0.7")
        #expect(world.frame(1) == Rect(x: 0, y: 0, width: 700, height: 600))

        // Dragged by the title bar onto the middle of window 1: they trade places, sizes kept.
        world.drop(2, at: Point(x: 350, y: 300))
        #expect(world.frame(2) == Rect(x: 0, y: 0, width: 700, height: 600))
        #expect(world.frame(1) == Rect(x: 700, y: 0, width: 300, height: 600))

        // The same with the main key held.
        world.beginInteraction(.move, window: 1, cursor: Point(x: 850, y: 300))
        world.updateInteraction(cursor: Point(x: 500, y: 300))
        world.endInteraction(cursor: Point(x: 500, y: 300))
        #expect(world.frame(1) == Rect(x: 0, y: 0, width: 700, height: 600))
        #expect(world.frame(2) == Rect(x: 700, y: 0, width: 300, height: 600))
    }
}
