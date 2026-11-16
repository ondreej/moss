import Foundation
import Testing
import MossCore
import MossIPC
import Synchronization
@testable import MossRuntime

@Suite("Window manager", .serialized)
@EngineActor
struct WindowManagerTests {
    @Test func adoptsAndTilesExistingWindows() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func newWindowsAreTiledAndFocused() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        // A new window takes the half of the split the cursor is over.
        harness.manager.handle(InputEvent.cursorMoved(to: Point(x: 800, y: 300)))
        harness.manager.handle(harness.system.open(snapshot(2)))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 500, y: 0, width: 500, height: 600))
        #expect(harness.system.lastFocused == WindowID(2))
        #expect(harness.events.all.contains(.windowOpened(WindowID(2), workspace: "1", bundleID: "com.example.app", title: "Window 2")))
    }

    @Test func workspaceSwitchParksWindowsOffScreen() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        #expect(harness.manager.respond(to: "workspace 2") == "ok\n")
        let parked = try #require(harness.system.frame(of: WindowID(1)))
        #expect(parked.origin == Point(x: 999, y: 599))
        #expect(harness.manager.respond(to: "workspace 1") == "ok\n")
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func parkedWindowsAvoidNeighbouringMonitors() async throws {
        let harness = try await Harness(displays: 2, windows: [snapshot(1)])
        _ = harness.manager.respond(to: "workspace 3")
        let parked = try #require(harness.system.frame(of: WindowID(1)))
        // Display 2 sits to the right, so the window is parked in the bottom-left corner.
        #expect(parked.maxX == 1)
    }

    @Test func externalFocusSwitchesWorkspace() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "workspace 2")
        try await Task.sleep(for: .milliseconds(450))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(1))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func aLateConfirmationOfFocusDoesNotFollowAWindowSentAway() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "focus-window id:0x1")
        _ = harness.manager.respond(to: "send-to-workspace 2")
        // The system confirms the focus request only now, with the window already gone.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(1))
    }

    @Test func activationAfterACloseDoesNotSwitchWorkspaces() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "workspace 2")
        harness.manager.handle(harness.system.open(snapshot(2)))
        try await Task.sleep(for: .milliseconds(450))
        // Window 2 closes and the system activates the application owning window 1.
        harness.manager.handle(PlatformEvent.windowDisappeared(WindowID(2)))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(2))
    }

    @Test func launchingFromAnotherWorkspaceKeepsTheUserThere() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "workspace 2")
        try await Task.sleep(for: .milliseconds(450))
        // The application is activated (its existing window is on workspace 1), then opens a new window.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(1))
        var second = snapshot(2)
        second.properties.pid = 1
        harness.manager.handle(harness.system.open(second))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(2))
        #expect(harness.manager.world.windows[WindowID(2)]?.workspace == .numbered(2))
        #expect(harness.manager.world.focusedWindowID == WindowID(2))
    }

    @Test func focusMovingToAnotherMonitorIsNotALaunch() async throws {
        let onSecondDisplay = snapshot(2, frame: Rect(x: 1100, y: 100, width: 400, height: 300))
        let harness = try await Harness(displays: 2, windows: [snapshot(1), onSecondDisplay])
        try await Task.sleep(for: .milliseconds(450))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        var second = snapshot(3)
        second.properties.pid = 2
        harness.manager.handle(harness.system.open(second))
        let world = harness.manager.world
        #expect(world.windows[WindowID(3)]?.workspace == world.windows[WindowID(2)]?.workspace)
    }

    @Test func applicationsMayRefuseTheirTileSize() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        let requests = harness.system.frameRequestCount
        // Window 2 will not be narrower than 700 points: it is not resized back…
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 500, y: 0, width: 700, height: 600)))
        #expect(harness.system.frameRequestCount == requests)
        // …and once its frame settles, the layout makes room for it.
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 300, y: 0, width: 700, height: 600))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 300, height: 600))
    }

    @Test func windowsSmallerThanTheirTileAreCentered() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        // Window 2 keeps its own width, as fixed-size and fixed-aspect windows do. Once it
        // settles, it is offered its whole tile again, in case it reported a stale frame…
        let tile = Rect(x: 500, y: 0, width: 500, height: 600)
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 500, y: 0, width: 300, height: 600)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.system.frame(of: WindowID(2)) == tile)
        // …and refusing it again, it sits in the middle of its tile, with its border around it.
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 500, y: 0, width: 300, height: 600)))
        try await Task.sleep(for: .milliseconds(400))
        let centered = Rect(x: 600, y: 0, width: 300, height: 600)
        #expect(harness.system.frame(of: WindowID(2)) == centered)
        #expect(harness.decorations.all.first { $0.window == WindowID(2) }?.frame == centered)
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 500, height: 600))

        // A new tile is offered whole again.
        harness.manager.handle(.windowDisappeared(WindowID(1)))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func windowsTheLayoutCannotMakeRoomForStayOnTheDisplay() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        // Together, the two windows need more than the display's width.
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 500, y: 0, width: 700, height: 600)))
        try await Task.sleep(for: .milliseconds(400))
        harness.manager.handle(harness.system.userChanged(WindowID(1), to: Rect(x: 0, y: 0, width: 600, height: 600)))
        try await Task.sleep(for: .milliseconds(400))
        let tile = try #require(harness.system.frame(of: WindowID(2)))
        #expect(tile.width < 700)
        // Window 2 keeps its width in its narrower tile…
        let requests = harness.system.frameRequestCount
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: tile.minX, y: 0, width: 700, height: 600)))
        try await Task.sleep(for: .milliseconds(400))
        // …and having refused its tile, it is not offered it again, only moved.
        // …so it is moved back onto the display, its border around it.
        let frame = Rect(x: 300, y: 0, width: 700, height: 600)
        #expect(harness.system.frameRequestCount == requests + 1)
        #expect(harness.system.frame(of: WindowID(2)) == frame)
        #expect(harness.decorations.all.first { $0.window == WindowID(2) }?.frame == frame)
    }

    @Test func aWindowNoRoomCanBeMadeForIsStillKeptOnTheDisplay() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        // Wider than the display: learning its minimum size changes no tile.
        harness.manager.handle(harness.system.userChanged(WindowID(1), to: Rect(x: 50, y: 0, width: 1200, height: 600)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1200, height: 600))
    }

    @Test func aWindowLeavingNativeFullscreenGoesBackToItsTile() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        let tile = try #require(harness.system.frame(of: WindowID(1)))
        harness.manager.handle(PlatformEvent.windowNativeFullscreen(WindowID(1), true))
        _ = harness.system.userChanged(WindowID(1), to: Rect(x: 0, y: 0, width: 1000, height: 600))
        harness.manager.handle(PlatformEvent.windowNativeFullscreen(WindowID(1), false))
        #expect(harness.system.frame(of: WindowID(1)) == tile)
        // macOS then puts it back at its frame from before fullscreen, without a word.
        _ = harness.system.userChanged(WindowID(1), to: Rect(x: 0, y: 0, width: 1000, height: 600))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(harness.system.frame(of: WindowID(1)) == tile)
    }

    @Test func fixedSizeWindowsAreCenteredWithoutBeingOfferedTheirTileAgain() async throws {
        var fixed = snapshot(2)
        fixed.properties.isResizable = false
        let harness = try await Harness(windows: [snapshot(1), fixed])
        // Tiled, as Calculator and Chess may be by a rule.
        _ = harness.manager.respond(to: "float off id:0x2")
        let tile = try #require(harness.manager.world.arrangement().frames[WindowID(2)])
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: tile.minX, y: 0, width: 300, height: 600)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.system.frame(of: WindowID(2)) == tile.centered(Size(width: 300, height: 600)))
    }

    @Test func draggingATiledWindowDropsItUnderTheCursor() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.system.setPrimaryButton(down: true)
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 200, y: 50, width: 500, height: 600)))
        harness.system.setPrimaryButton(down: false)
        harness.manager.handle(InputEvent.primaryButton(isDown: false, at: Point(x: 100, y: 300)))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func windowsSentAwayMidDragStayAway() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.system.setPrimaryButton(down: true)
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 200, y: 50, width: 500, height: 600)))
        _ = harness.manager.respond(to: "send-to-workspace 2 id:0x2")
        // The parked window settles in its corner while the button is still held.
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 999, y: 599, width: 500, height: 600)))
        harness.system.setPrimaryButton(down: false)
        harness.manager.handle(InputEvent.primaryButton(isDown: false, at: Point(x: 100, y: 300)))
        #expect(harness.manager.world.windows[WindowID(2)]?.workspace == .numbered(2))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func resizingATiledWindowByItsEdgeResizesTheLayout() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.system.setPrimaryButton(down: true)
        harness.manager.handle(harness.system.userChanged(WindowID(1), to: Rect(x: 0, y: 0, width: 600, height: 600)))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 600, y: 0, width: 400, height: 600))
        harness.system.setPrimaryButton(down: false)
        harness.manager.handle(InputEvent.primaryButton(isDown: false, at: Point(x: 600, y: 300)))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 600, height: 600))
    }

    @Test func draggingShowsWhereTheWindowWillLand() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.manager.handle(InputEvent.mouseBindingBegan(.move, at: Point(x: 700, y: 300)))
        harness.manager.handle(InputEvent.mouseBindingMoved(to: Point(x: 100, y: 300)))
        #expect(harness.decorations.lastDropTarget == Rect(x: 0, y: 0, width: 500, height: 600))
        harness.manager.handle(InputEvent.mouseBindingEnded(at: Point(x: 100, y: 300)))
        #expect(harness.decorations.lastDropTarget == .some(nil))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func mouseBindingsMoveWindows() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.manager.handle(InputEvent.mouseBindingBegan(.move, at: Point(x: 700, y: 300)))
        harness.manager.handle(InputEvent.mouseBindingMoved(to: Point(x: 650, y: 300)))
        #expect(harness.system.frame(of: WindowID(2))?.minX == 450)
        harness.manager.handle(InputEvent.mouseBindingEnded(at: Point(x: 100, y: 300)))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func capsLockIsHyperUnlessAskedOtherwise() async throws {
        // By default Caps Lock is Hyper, and Moss's caps shortcuts ride on it.
        let hyper = try await Harness(config: "[shortcuts]\ncaps-q = \"close\"\n")
        #expect(hyper.input.capsLockRole == .hyper)
        let own = try await Harness(config: "[keyboard]\ncaps-lock = \"caps-lock\"\n\n[shortcuts]\ncaps-q = \"close\"\n")
        #expect(own.input.capsLockRole == .modifier)
        let plain = try await Harness(config: "[keyboard]\nmain-key = \"alt\"\ncaps-lock = \"caps-lock\"\n")
        #expect(plain.input.capsLockRole == .unchanged)
    }

    @Test func shortcutsRunActions() async throws {
        let harness = try await Harness(config: "[shortcuts]\nalt-q = \"run open -a Terminal\"\n")
        let binding = try #require(harness.input.current.first)
        harness.manager.handle(InputEvent.binding(binding))
        #expect(harness.runner.all == ["open -a Terminal"])
    }

    @Test func setOptionsApplyImmediatelyAndResetOnReload() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        #expect(harness.manager.respond(to: "set layout.margins 10") == "ok\n")
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 10, y: 10, width: 980, height: 580))
        #expect(harness.manager.respond(to: "set layout.margins banana").hasPrefix("error:"))
        #expect(harness.manager.respond(to: "set layout.margin 4") == "error: unknown option 'layout.margin', did you mean 'layout.margins'?\n")
        _ = harness.manager.respond(to: "reload")
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func configurationErrorsShowInTheErrorBar() async throws {
        let config = "[layout]\ngaps = 0\nmargins = 0\n\n[shortcuts]\nalt-q = \"frobnicate\"\n"
        let harness = try await Harness(config: config)
        let bar = try #require(harness.notices.errorBar)
        #expect(bar.lines.count == 1)
        #expect(bar.lines[0].contains("moss.toml, line 7: "))
        #expect(bar.lines[0].contains("frobnicate"))

        _ = harness.manager.respond(to: "set errors.show false")
        #expect(harness.notices.errorBar == nil)
    }

    @Test func setErrorLastsUntilAReload() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        #expect(harness.notices.errorBar == nil)
        #expect(harness.manager.respond(to: "error --color #66ee66 Backup failed") == "ok\n")
        let bar = try #require(harness.notices.errorBar)
        #expect(bar.lines == ["Backup failed"])
        #expect(bar.color == Color(rgba: 0x66EE_66FF))
        // Windows make room for the bar.
        let room = ErrorBar.margin + bar.height
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: room, width: 1000, height: 600 - room))
        _ = harness.manager.respond(to: "reload")
        #expect(harness.notices.errorBar == nil)
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func workspaceSwitchesShowTheHUD() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "workspace 2")
        let hud = try #require(harness.notices.workspaceHUDs.last)
        #expect(hud.items.map(\.name) == ["1", "2"])
        #expect(hud.items.first { $0.isActive }?.name == "2")
        #expect(hud.items.first?.windows == 1)

        _ = harness.manager.respond(to: "set workspaces.show-name false")
        _ = harness.manager.respond(to: "workspace 1")
        #expect(harness.notices.workspaceHUDs.count == 1)
    }

    @Test func pausingLeavesWindowsAlone() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "workspace 2")
        _ = harness.manager.respond(to: "pause")
        #expect(harness.manager.isPaused)
        // The parked window comes back into view.
        let frame = try #require(harness.system.frame(of: WindowID(1)))
        #expect(Rect(x: 0, y: 0, width: 1000, height: 600).contains(frame.center))
        #expect(harness.notices.posted.last?.message == "Tiling paused")
        #expect(harness.events.all.last == .tilingPaused(true))
        #expect(harness.manager.respond(to: "status").contains(/tiling +paused/))

        let requests = harness.system.frameRequestCount
        harness.manager.handle(harness.system.open(snapshot(2)))
        #expect(harness.system.frameRequestCount == requests)

        _ = harness.manager.respond(to: "pause off")
        #expect(!harness.manager.isPaused)
        #expect(harness.system.frameRequestCount > requests)
        #expect(harness.events.all.contains(.tilingPaused(false)))
    }

    @Test func noticesArePosted() async throws {
        let harness = try await Harness()
        #expect(harness.manager.respond(to: "notify --icon ok --seconds 2 Done") == "ok\n")
        #expect(harness.notices.posted.map(\.message) == ["Done"])
        #expect(harness.notices.posted.first?.icon == .ok)
    }

    @Test func whilePausedOnlyActionsThatLeaveWindowsAloneRun() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "pause on")
        #expect(harness.manager.respond(to: "workspace 2") == "error: tiling is paused; 'pause off' resumes it\n")
        #expect(harness.manager.world.activeWorkspaceID == .numbered(1))
        #expect(harness.manager.respond(to: "run open -a Notes") == "ok\n")
        _ = harness.manager.respond(to: "pause off")
        #expect(harness.manager.respond(to: "workspace 2") == "ok\n")
    }

    @Test func noticesStayClearOfSpaceReservedForAStatusBar() async throws {
        let harness = try await Harness(config: "[displays.all]\nreserve = [30, 0, 0, 0]\n")
        _ = harness.manager.respond(to: "notify Done")
        #expect(harness.notices.areas.last == Rect(x: 0, y: 30, width: 1000, height: 570))
    }

    @Test func reloadPicksUpFileChanges() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        try "layout.margins = 50\nborders.width = 0\nanimation.enabled = false\n".write(to: harness.file, atomically: true, encoding: .utf8)
        harness.manager.reloadConfiguration()
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 50, y: 50, width: 900, height: 500))
        #expect(harness.events.all.contains(.configReloaded))
    }

    @Test func aConfigurationFileDeletedAndWrittenAgainIsStillWatched() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<60 where !done() { try await Task.sleep(for: .milliseconds(50)) }
        }
        try FileManager.default.removeItem(at: harness.file)
        try await settle { harness.events.all.contains(.configReloaded) }
        #expect(harness.events.all.contains(.configReloaded))
        try "layout.margins = 50\nborders.width = 0\nanimation.enabled = false\n".write(to: harness.file, atomically: false, encoding: .utf8)
        try await settle { harness.system.frame(of: WindowID(1))?.minX == 50 }
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 50, y: 50, width: 900, height: 500))
    }

    @Test func includedFilesAreWatchedWhileMissingAndByPattern() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<60 where !done() { try await Task.sleep(for: .milliseconds(50)) }
        }
        let directory = harness.file.deletingLastPathComponent()
        try "include = [\"missing.toml\", \"extra/*.toml\"]\nanimation.enabled = false\nborders.width = 0\n".write(to: harness.file, atomically: true, encoding: .utf8)
        harness.manager.reloadConfiguration()
        // An included file that appears is read…
        try "layout.margins = 50\n".write(to: directory.appendingPathComponent("missing.toml"), atomically: false, encoding: .utf8)
        // (An error bar above says the pattern matches nothing yet.)
        try await settle { harness.system.frame(of: WindowID(1))?.minX == 50 }
        #expect(harness.system.frame(of: WindowID(1))?.minX == 50)
        // …and so is a new file matching an included pattern.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("extra"), withIntermediateDirectories: true)
        harness.manager.reloadConfiguration()
        try "layout.margins = 20\n".write(to: directory.appendingPathComponent("extra/more.toml"), atomically: false, encoding: .utf8)
        try await settle { harness.system.frame(of: WindowID(1))?.minX == 20 }
        #expect(harness.system.frame(of: WindowID(1))?.minX == 20)
    }

    @Test func queriesAnswerInJSON() async throws {
        let harness = try await Harness(windows: [snapshot(7)])
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(7)))
        let response = harness.manager.respond(to: "--json focused")
        let window = try JSONDecoder().decode(WindowInfo.self, from: Data(response.utf8))
        #expect(window.id == "0x7")
        let option = try JSONDecoder().decode(OptionInfo.self, from: Data(harness.manager.respond(to: "--json get layout.gaps").utf8))
        #expect(option.value == "0")
        #expect(option.defaultValue == "8")
        #expect(option.isSet)
    }

    @Test func mistakesAreExplained() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        #expect(harness.manager.respond(to: "worksapce 2") == "error: unknown action 'worksapce', did you mean 'workspace'?\n")
        #expect(harness.manager.respond(to: "get layout.gapz").hasPrefix("error:"))
    }

    @Test func decorationsTrackFocus() async throws {
        let harness = try await Harness(config: "[layout]\ngaps = 0\nmargins = 0\n\n[borders]\nwidth = 2\n", windows: [snapshot(1), snapshot(2)])
        let decorations = harness.decorations.all
        #expect(decorations.count == 2)
        #expect(decorations.first { $0.isActive }?.window == harness.manager.world.focusedWindowID)
        #expect(decorations.allSatisfy { $0.borderWidth == 2 })
    }

    @Test func mossOwnWindowsAreToldWhenATileTakesFocus() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "float id:0x2")
        let tileFocused = Mutex(false)
        harness.manager.onTileFocused = { tileFocused.withLock { $0 = true } }
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        #expect(tileFocused.withLock { $0 })
    }

    @Test func tilesTakeFocusBelowTheFloatingWindows() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        // With nothing floating over it, a tile comes to the front as usual.
        _ = harness.manager.respond(to: "focus-window id:0x2")
        _ = harness.manager.respond(to: "focus-window id:0x1")
        #expect(harness.system.lastFocused == WindowID(1))
        #expect(!harness.system.lastFocusLeftInPlace)
        // Floating windows come forward when focused.
        _ = harness.manager.respond(to: "float id:0x2")
        _ = harness.manager.respond(to: "focus-window id:0x2")
        #expect(harness.system.lastFocused == WindowID(2))
        #expect(!harness.system.lastFocusLeftInPlace)
        // The tile under one takes focus where it is.
        _ = harness.manager.respond(to: "focus-window id:0x1")
        #expect(harness.system.lastFocused == WindowID(1))
        #expect(harness.system.lastFocusLeftInPlace)
        // A fullscreen tile goes above them.
        _ = harness.manager.respond(to: "focus-window id:0x1")
        _ = harness.manager.respond(to: "fullscreen")
        _ = harness.manager.respond(to: "focus-window id:0x2")
        _ = harness.manager.respond(to: "focus-window id:0x1")
        #expect(harness.system.lastFocused == WindowID(1))
        #expect(!harness.system.lastFocusLeftInPlace)
    }

    @Test func floatingWindowsComingIntoViewAreBroughtAboveTheTiles() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2), snapshot(3)])
        _ = harness.manager.respond(to: "float on id:0x3")
        _ = harness.manager.respond(to: "focus-window id:0x1")
        _ = harness.manager.respond(to: "workspace 2")
        #expect(harness.system.broughtForward.isEmpty)
        _ = harness.manager.respond(to: "workspace 1")
        // The floating window comes forward first, then the tile that has focus.
        #expect(harness.system.broughtForward == [[WindowID(3)]])
        #expect(harness.system.lastFocused == WindowID(1))
        // Nothing more while the workspace stays in view.
        _ = harness.manager.respond(to: "focus-window id:0x2")
        #expect(harness.system.broughtForward.count == 1)
    }

    @Test func aWindowBroughtForwardLateDoesNotPullFocusBack() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2), snapshot(3)])
        _ = harness.manager.respond(to: "float on id:0x2")
        _ = harness.manager.respond(to: "send-to-workspace 2 id:0x3")
        _ = harness.manager.respond(to: "focus-window id:0x1")
        _ = harness.manager.respond(to: "workspace 2")
        _ = harness.manager.respond(to: "workspace 1")
        #expect(harness.system.broughtForward.last == [WindowID(2)])
        // Left again at once; the system confirms the new focus…
        _ = harness.manager.respond(to: "workspace 2")
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(3)))
        // …and then the floating window, brought forward for workspace 1, takes focus late.
        let requests = harness.system.focusRequests.count
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(2))
        #expect(harness.manager.world.focusedWindowID == WindowID(3))
        #expect(harness.system.focusRequests.dropFirst(requests) == [WindowID(3)])
    }

    @Test func aWindowBroughtForwardReportedFocusedLastDoesNotKeepFocus() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "float on id:0x2")
        _ = harness.manager.respond(to: "focus-window id:0x1")
        _ = harness.manager.respond(to: "workspace 2")
        _ = harness.manager.respond(to: "workspace 1")
        #expect(harness.system.broughtForward.last == [WindowID(2)])
        // The two applications report in the other order.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        #expect(harness.manager.world.focusedWindowID == WindowID(1))
        #expect(harness.system.lastFocused == WindowID(1))
        // A click on the floating window is the user's choice.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        harness.manager.handle(InputEvent.primaryButton(isDown: true, at: Point(x: 150, y: 150)))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        #expect(harness.manager.world.focusedWindowID == WindowID(2))
    }

    @Test func focusSettlesOnATiledScratchpadWindowNextToFloatingOnes() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2), snapshot(3)])
        _ = harness.manager.respond(to: "float id:0x1")
        _ = harness.manager.respond(to: "float id:0x2")
        _ = harness.manager.respond(to: "send-to-workspace scratchpad id:0x3")
        _ = harness.manager.respond(to: "scratchpad")
        _ = harness.manager.respond(to: "focus-window id:0x3")
        let requests = harness.system.focusRequests.count
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(3)))
        // Nothing else is focused or raised in return, which would start a loop of focus changes.
        #expect(harness.system.focusRequests.count == requests)
        #expect(harness.manager.world.focusedWindowID == WindowID(3))
    }

    @Test func aWindowOpenedBehindAFullscreenOneLeavesItFocused() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "focus-window id:0x1")
        _ = harness.manager.respond(to: "fullscreen on")
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        harness.manager.handle(harness.system.open(snapshot(3)))
        #expect(harness.manager.world.focusedWindowID == WindowID(1))
        // Its application focuses the new window anyway; focus goes back to the fullscreen one.
        let requests = harness.system.focusRequests.count
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(3)))
        #expect(harness.manager.world.focusedWindowID == WindowID(1))
        #expect(harness.system.focusRequests.dropFirst(requests) == [WindowID(1)])
        // Once the system confirms that, focusing the new window is the user's choice.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(3)))
        #expect(harness.manager.world.focusedWindowID == WindowID(3))
    }

    @Test func anOpenScratchpadDimsWhatIsBehindIt() async throws {
        let harness = try await Harness(config: "[layout]\ngaps = 0\nmargins = 0\n\n[scratchpads]\ndim-behind = 0.4\n", windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "send-to-workspace scratchpad id:0x2")
        #expect(harness.decorations.all.allSatisfy { $0.dim == 0 })
        _ = harness.manager.respond(to: "scratchpad")
        #expect(harness.decorations.all.first { $0.window == WindowID(1) }?.dim == 0.4)
        #expect(harness.decorations.all.first { $0.window == WindowID(2) }?.dim == 0)
        _ = harness.manager.respond(to: "scratchpad")
        #expect(harness.decorations.all.allSatisfy { $0.dim == 0 })
    }

    @Test func bordersGoBackAboveRaisedWindows() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        let before = harness.decorations.restackCount
        // A click raises the window under its border; the focus change that follows restacks it.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        #expect(harness.decorations.restackCount > before)
    }

    @Test func windowsOfHiddenWorkspacesThatMacOSBringsBackAreParkedAgain() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "send-to-workspace 2 id:0x2")
        let parked = try #require(harness.system.frame(of: WindowID(2)))
        // As around fullscreen, macOS moves the application's other windows into view.
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 100, y: 100, width: 603, height: 505)))
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.system.frame(of: WindowID(2))?.origin == parked.origin)
    }

    @Test func closingAWorkspacesLastWindowStaysOnTheWorkspace() async throws {
        var other = snapshot(2)
        other.properties.pid = 1
        let harness = try await Harness(windows: [snapshot(1), other])
        _ = harness.manager.respond(to: "send-to-workspace 2 id:0x2")
        _ = harness.manager.respond(to: "focus-window id:0x1")
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        // The application focuses its other window before saying the first one closed.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        harness.manager.handle(PlatformEvent.windowDisappeared(WindowID(1)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(1))
        #expect(harness.system.desktopFocusCount == 1)

        // Without a window closing, focus moved to the other window is followed.
        try await Task.sleep(for: .seconds(1))
        var third = snapshot(3)
        third.properties.pid = 1
        harness.manager.handle(harness.system.open(third))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(3)))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(2))
        #expect(harness.manager.world.focusedWindowID == WindowID(2))
    }

    @Test func anEmptyWorkspaceLeavesTheDesktopFocused() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "focus-window id:0x1")
        _ = harness.manager.respond(to: "workspace 2")
        #expect(harness.system.desktopFocusCount == 1)
        _ = harness.manager.respond(to: "workspace 1")
        #expect(harness.system.lastFocused == WindowID(1))
        // A window going into native fullscreen keeps focus in its own Space.
        harness.manager.handle(PlatformEvent.windowNativeFullscreen(WindowID(1), true))
        #expect(harness.system.desktopFocusCount == 1)
    }

    @Test func minimizedWindowsLeaveTheLayout() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.manager.handle(PlatformEvent.windowMinimized(WindowID(2), true))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
        harness.manager.handle(PlatformEvent.windowMinimized(WindowID(2), false))
        #expect(harness.manager.world.windows[WindowID(2)] != nil)
    }

    @Test func shownApplicationsReturnToTheirWorkspaces() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "send-to-workspace 3 id:0x2")
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, true))
        #expect(harness.manager.world.windows[WindowID(2)] == nil)
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, false))
        #expect(harness.manager.world.windows[WindowID(2)]?.workspace == .numbered(3))
        #expect(harness.manager.world.activeWorkspaceID == .numbered(1))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func shownApplicationsFindTheirWindowsTilesAsTheyLeftThem() async throws {
        var second = snapshot(3)
        second.properties.pid = 2
        let harness = try await Harness(windows: [snapshot(1), snapshot(2), second, snapshot(4)])
        _ = harness.manager.respond(to: "focus-window id:0x2")
        _ = harness.manager.respond(to: "split-ratio 0.3")
        let before = (1...4).map { harness.system.frame(of: WindowID(UInt32($0))) }
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, true))
        #expect(harness.manager.world.windows[WindowID(3)] == nil)
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, false))
        #expect((1...4).map { harness.system.frame(of: WindowID(UInt32($0))) } == before)

        // A workspace emptied while its windows were away takes its layout back with them.
        _ = harness.manager.respond(to: "send-to-workspace 4 id:0x2")
        _ = harness.manager.respond(to: "send-to-workspace 4 id:0x3")
        _ = harness.manager.respond(to: "workspace 4")
        _ = harness.manager.respond(to: "layout stack")
        _ = harness.manager.respond(to: "workspace 1")
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, true))
        #expect(harness.manager.world.workspaces[.numbered(4)] == nil)
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, false))
        #expect(harness.manager.world.workspaces[.numbered(4)]?.tiling.kind == .stack)
        #expect(harness.manager.world.workspaces[.numbered(4)]?.layoutOverride == .stack)
        _ = harness.manager.respond(to: "send-to-workspace 1 id:0x2")
        _ = harness.manager.respond(to: "send-to-workspace 1 id:0x3")
        let back = (1...4).map { harness.system.frame(of: WindowID(UInt32($0))) }

        // Minimized and brought back, a window takes its tile again too.
        harness.manager.handle(PlatformEvent.windowMinimized(WindowID(1), true))
        harness.manager.handle(PlatformEvent.windowMinimized(WindowID(1), false))
        #expect((1...4).map { harness.system.frame(of: WindowID(UInt32($0))) } == back)
    }

    @Test func tabGroupsComeBackWithTheirWindows() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "focus-window id:0x2")
        _ = harness.manager.respond(to: "tabs")
        var third = snapshot(3)
        third.properties.pid = 2
        harness.manager.handle(harness.system.open(third))
        let group = try #require(harness.manager.world.group(of: WindowID(2)))
        #expect(group.members == [WindowID(2), WindowID(3)])
        let frames = (1...3).map { harness.system.frame(of: WindowID(UInt32($0))) }

        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, true))
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, false))
        #expect(harness.manager.world.group(of: WindowID(2))?.members == [WindowID(2), WindowID(3)])
        #expect(harness.manager.world.group(of: WindowID(2))?.active == WindowID(3))
        #expect((1...3).map { harness.system.frame(of: WindowID(UInt32($0))) } == frames)

        // One tab minimized and brought back rejoins the others.
        harness.manager.handle(PlatformEvent.windowMinimized(WindowID(2), true))
        harness.manager.handle(PlatformEvent.windowMinimized(WindowID(2), false))
        #expect(harness.manager.world.group(of: WindowID(3))?.members == [WindowID(2), WindowID(3)])
    }

    @Test func hiddenApplicationsWaitOutsideTheLayout() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)], hiddenApplications: [2])
        #expect(harness.manager.world.windows[WindowID(2)] == nil)
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
        harness.manager.handle(PlatformEvent.applicationHidden(pid: 2, false))
        #expect(harness.system.frame(of: WindowID(1))?.width == 500)
    }

    @Test func nativeFullscreenWindowsKeepFocusInTheirSpace() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        let requests = harness.system.focusRequests.count
        // Focusing another window would make the system leave the fullscreen window's Space.
        harness.manager.handle(PlatformEvent.windowNativeFullscreen(WindowID(2), true))
        #expect(harness.system.focusRequests.count == requests)
        #expect(harness.manager.world.focusedWindowID == nil)
        // Its application activated again, e.g. from a launcher: focus stays there.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        #expect(harness.system.focusRequests.count == requests)
        // Back on the desktop, the tiled windows have focus as usual.
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        #expect(harness.manager.world.focusedWindowID == WindowID(1))
        harness.manager.handle(PlatformEvent.windowNativeFullscreen(WindowID(2), false))
        #expect(harness.manager.world.windows[WindowID(2)] != nil)
    }

    @Test func windowsCoveringTheDisplayAreFullscreenOfTheirOwn() async throws {
        let harness = try await Harness(config: "[layout]\ngaps = 0\nmargins = 10\n\n[borders]\nwidth = 0\n", windows: [snapshot(1), snapshot(2)])
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        let requests = harness.system.focusRequests.count
        // A video player draws its own fullscreen over the whole display.
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 0, y: 0, width: 1000, height: 600)))
        #expect(harness.manager.world.windows[WindowID(2)] == nil)
        #expect(harness.system.focusRequests.count == requests)
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 0, y: 0, width: 1000, height: 600))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 10, y: 10, width: 980, height: 580))
        // Back from fullscreen, it returns to its tile with focus.
        harness.manager.handle(harness.system.userChanged(WindowID(2), to: Rect(x: 500, y: 10, width: 490, height: 580)))
        #expect(harness.manager.world.windows[WindowID(2)] != nil)
        #expect(harness.manager.world.focusedWindowID == WindowID(2))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 10, y: 10, width: 490, height: 580))
    }

    @Test func windowsReplacedByAFullscreenWindowOfTheirOwnKeepTheirPlace() async throws {
        let harness = try await Harness(config: "[layout]\ngaps = 0\nmargins = 0\n\n[borders]\nwidth = 0\n", windows: [snapshot(1), snapshot(2), snapshot(3)])
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        let tiles = [1, 2, 3].map { harness.system.frame(of: WindowID($0)) }
        let requests = harness.system.focusRequests.count
        // A browser closes the window and covers the display with one of its own for a video.
        harness.manager.handle(PlatformEvent.windowReplacedByFullscreen(WindowID(2)))
        #expect(harness.manager.world.windows[WindowID(2)] == nil)
        // Focusing another window, or the desktop, would bring it over the video.
        #expect(harness.system.focusRequests.count == requests)
        #expect(harness.system.desktopFocusCount == 0)
        harness.manager.handle(PlatformEvent.focusChanged(nil))
        #expect(harness.system.focusRequests.count == requests)
        // Leaving fullscreen, it opens a new window, which takes the old one's place.
        let back = WindowSnapshot(id: WindowID(4), properties: snapshot(2).properties, frame: Rect(x: 0, y: 0, width: 1000, height: 600))
        _ = harness.system.open(back)
        harness.manager.handle(PlatformEvent.windowReturnedFromFullscreen(WindowID(2), back))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(4)))
        #expect(harness.manager.world.focusedWindowID == WindowID(4))
        #expect([1, 4, 3].map { harness.system.frame(of: WindowID($0)) } == tiles)
    }

    @Test func aWindowReplacedByFullscreenThatNeverComesBackGivesUpItsPlace() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(2)))
        harness.manager.handle(PlatformEvent.windowReplacedByFullscreen(WindowID(2)))
        harness.manager.handle(PlatformEvent.focusChanged(nil))
        // The tab closed in fullscreen: focus goes on as after any window closed.
        harness.manager.handle(PlatformEvent.windowDisappeared(WindowID(2)))
        #expect(harness.manager.world.focusedWindowID == WindowID(1))
        #expect(harness.system.lastFocused == WindowID(1))
        // A window reported as its return after that is simply a new window.
        let late = WindowSnapshot(id: WindowID(4), properties: snapshot(2).properties, frame: Rect(x: 100, y: 100, width: 400, height: 300))
        _ = harness.system.open(late)
        harness.manager.handle(PlatformEvent.windowReturnedFromFullscreen(WindowID(2), late))
        #expect(harness.manager.world.windows[WindowID(4)] != nil)
        #expect(harness.manager.world.windows[WindowID(2)] == nil)
        #expect(harness.system.frame(of: WindowID(1))?.width == harness.system.frame(of: WindowID(4))?.width)
    }

    @Test func focusOnWindowsMossDoesNotArrangeIsLeftAlone() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        let requests = harness.system.focusRequests.count
        harness.manager.handle(PlatformEvent.focusChanged(nil))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(99)))
        #expect(harness.system.focusRequests.count == requests)
        #expect(harness.manager.world.focusedWindowID == nil)
        // Moss's own focus changes still apply.
        #expect(harness.manager.respond(to: "focus-window id:0x1") == "ok\n")
        #expect(harness.system.lastFocused == WindowID(1))
    }

    @Test func nativeFullscreenWindowsLeaveTheLayout() async throws {
        let harness = try await Harness(windows: [snapshot(1), snapshot(2)])
        harness.manager.handle(PlatformEvent.windowNativeFullscreen(WindowID(2), true))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 1000, height: 600))
        harness.manager.handle(PlatformEvent.windowNativeFullscreen(WindowID(2), false))
        #expect(harness.system.frame(of: WindowID(1))?.width == 500)
    }

    @Test func layoutChangesAnimate() async throws {
        let config = "[layout]\ngaps = 0\nmargins = 0\n\n[borders]\nwidth = 0\n\n[animation]\nduration = 0.15\ncurve = \"linear\"\n"
        let harness = try await Harness(config: config, animations: true, windows: [snapshot(1), snapshot(2)])
        // Windows that start off screen appear in place; let the opening animation finish.
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 500, y: 0, width: 500, height: 600))
        harness.manager.handle(PlatformEvent.focusChanged(WindowID(1)))
        _ = harness.manager.respond(to: "swap-split")
        try await Task.sleep(for: .milliseconds(60))
        let midway = try #require(harness.system.frame(of: WindowID(2)))
        #expect(midway.minX > 0 && midway.minX < 500)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.system.frame(of: WindowID(2)) == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func scrolledTilesSlideAcrossTheEdge() async throws {
        let config = "[layout]\nstyle = \"scrolling\"\ngaps = 0\nmargins = 0\n\n[borders]\nwidth = 0\n\n[animation]\nduration = 0.15\ncurve = \"linear\"\n"
        let harness = try await Harness(config: config, animations: true, windows: [snapshot(1), snapshot(2), snapshot(3)])
        _ = harness.manager.respond(to: "focus-window id:\(WindowID(3).address)")
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.system.frame(of: WindowID(3)) == Rect(x: 500, y: 0, width: 500, height: 600))

        _ = harness.manager.respond(to: "focus-window id:\(WindowID(1).address)")
        try await Task.sleep(for: .milliseconds(60))
        // Window 1 comes in from beyond the left edge while window 3 leaves past the right one.
        let incoming = try #require(harness.system.frame(of: WindowID(1)))
        let outgoing = try #require(harness.system.frame(of: WindowID(3)))
        #expect(incoming.minX > -500 && incoming.minX < 0)
        #expect(outgoing.minX > 500 && outgoing.minX < 1000)

        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.system.frame(of: WindowID(1)) == Rect(x: 0, y: 0, width: 500, height: 600))
        // Once past the edge, window 3 is parked like a window on a hidden workspace.
        let parked = try #require(harness.system.frame(of: WindowID(3)))
        #expect(parked.intersection(Rect(x: 0, y: 0, width: 1000, height: 600)).area < parked.area * 0.1)
    }

    @Test func theLastSessionIsNotSavedOverBeforeItIsRestored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moss-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionFile = directory.appendingPathComponent("session.json")
        let saved = SessionState(placements: [SessionState.Placement(window: WindowID(1), workspace: .numbered(3), isFloating: false, floatingFrame: .zero, isPinned: false)])
        try JSONEncoder().encode(saved).write(to: sessionFile)
        let manager = WindowManager(
            windowSystem: FakeWindowSystem(windows: [snapshot(1)]),
            input: FakeInputSystem(),
            decorations: FakeDecorations(),
            notices: FakeNotices(),
            store: ConfigurationStore(mainFile: try configurationFile("animation.enabled = false\n")),
            sessionFile: sessionFile
        )
        // Something happening before the start, such as a window appearing, saves nothing.
        manager.handle(PlatformEvent.windowAppeared(snapshot(2)))
        manager.saveSession()
        #expect(try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: sessionFile)) == saved)
        await manager.start()
        #expect(manager.world.windows[WindowID(1)]?.workspace == .numbered(3))
    }

    @Test func shutdownLeavesFullscreenWindowsClearOfReservedSpace() async throws {
        let harness = try await Harness(config: "[layout]\ngaps = 0\nmargins = 0\n\n[displays.all]\nreserve = [30, 0, 0, 0]\n", windows: [snapshot(1), snapshot(2)])
        _ = harness.manager.respond(to: "move-to-workspace 2 id:0x2")
        _ = harness.manager.respond(to: "fullscreen on")
        _ = harness.manager.respond(to: "workspace 1")
        _ = harness.manager.respond(to: "fullscreen on")
        #expect(harness.manager.world.windows.values.allSatisfy { $0.fullscreen == .fullscreen })
        await harness.manager.shutdown()
        let usable = Rect(x: 0, y: 30, width: 1000, height: 570)
        #expect(harness.system.frame(of: WindowID(1)) == usable)
        // A parked fullscreen window comes back within that space too.
        let parked = try #require(harness.system.frame(of: WindowID(2)))
        #expect(usable.contains(parked.origin) && parked.maxY <= usable.maxY)
    }

    @Test func shutdownRestoresParkedWindows() async throws {
        let harness = try await Harness(windows: [snapshot(1)])
        _ = harness.manager.respond(to: "workspace 2")
        await harness.manager.shutdown()
        let frame = try #require(harness.system.frame(of: WindowID(1)))
        #expect(Rect(x: 0, y: 0, width: 1000, height: 600).contains(frame.center))
    }
}
