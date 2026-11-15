import Foundation
import Testing
import MossCore
@testable import MossIPC

@Suite("Control requests")
struct RequestTests {
    @Test func requestsAndActions() throws {
        #expect(try ControlRequest(parsing: "--json windows") == ControlRequest(json: true, command: .windows))
        #expect(try ControlRequest(parsing: "workspace 2") == ControlRequest(command: .action("workspace 2")))
        #expect(try ControlRequest(parsing: "set layout.gaps 10 20") == ControlRequest(command: .set(option: "layout.gaps", value: "10 20")))
        #expect(try ControlRequest(parsing: "--json get layout.style").command == .get("layout.style"))
        #expect(try ControlRequest(parsing: "get").command == .get(nil))
        #expect(try ControlRequest(parsing: "run open /Applications/Safari.app").command == .action("run open /Applications/Safari.app"))
        #expect(throws: ControlRequestError.self) { try ControlRequest(parsing: "set layout.gaps") }
    }

    @Test func notices() throws {
        let command = try ControlCommand(parsing: "notify --icon error --seconds 5 Something  went wrong")
        guard case .notify(let notice) = command else { Issue.record("not a notice"); return }
        #expect(notice.icon == .error)
        #expect(notice.color == Notice.Icon.error.color)
        #expect(notice.milliseconds == 5000)
        #expect(notice.message == "Something  went wrong")

        #expect(try ControlCommand(parsing: "notify --color #ff8800 Hi") == .notify(Notice(icon: nil, message: "Hi", color: Color(rgba: 0xFF88_00FF), milliseconds: 4000)))
        #expect(throws: ControlRequestError.self) { try ControlCommand(parsing: "notify --icon sparkles Hi") }
        #expect(throws: ControlRequestError.self) { try ControlCommand(parsing: "notify") }
        #expect(try ControlCommand(parsing: "dismiss") == .dismiss)
        #expect(try ControlCommand(parsing: "error --color #66ee66 hello world") == .error(message: "hello world", color: Color(rgba: 0x66EE_66FF)))
        #expect(try ControlCommand(parsing: "error --clear") == .clearError)
    }

    @Test func wireTextRoundTrips() throws {
        let notice = Notice(icon: .info, message: "Saved", milliseconds: 3000)
        for command in [
            ControlCommand.windows, .action("focus left"), .set(option: "layout.gaps", value: "4"), .get("layout.style"), .get(nil),
            .notify(notice), .dismiss, .error(message: "Broken", color: ErrorBar.defaultColor), .clearError,
        ] {
            let request = ControlRequest(json: true, command: command)
            #expect(try ControlRequest(parsing: request.wireText) == request)
        }
    }
}

@Suite("Queries")
struct QueryTests {
    func world() -> World {
        var world = World()
        world.updateDisplays([DisplayDescription(id: MonitorID(1), name: "Built-in Display", frame: Rect(x: 0, y: 0, width: 1000, height: 600), visibleFrame: Rect(x: 0, y: 30, width: 1000, height: 570), isBuiltin: true, isMain: true)])
        world.addWindow(WindowID(0x2a), properties: WindowProperties(appID: "com.example.editor", appName: "Editor", title: "notes.txt", pid: 42), frame: Rect(x: 0, y: 0, width: 300, height: 200))
        return world
    }

    @Test func windowsAsJSON() throws {
        let response = QueryResponder.respond(to: .windows, json: true, context: QueryContext(world: world()))
        let windows = try JSONDecoder().decode([WindowInfo].self, from: Data(response.utf8))
        #expect(windows.count == 1)
        #expect(windows[0].id == "0x2a")
        #expect(windows[0].bundleID == "com.example.editor")
        #expect(windows[0].app == "Editor")
        #expect(windows[0].workspace == "1")
        #expect(windows[0].frame == FrameInfo(x: 9, y: 39, width: 982, height: 552))
        #expect(windows[0].focusOrder == 0)
    }

    @Test func hiddenWindowsReportTheirLayoutFrame() throws {
        var world = world()
        _ = try world.perform(Action(parsing: "workspace 2"))
        let response = QueryResponder.respond(to: .windows, json: true, context: QueryContext(world: world))
        let windows = try JSONDecoder().decode([WindowInfo].self, from: Data(response.utf8))
        #expect(windows[0].isHidden)
        #expect(windows[0].frame.x == 9)
    }

    @Test func workspacesCountTheWindowsInTabs() throws {
        var world = world()
        _ = try world.perform(Action(parsing: "tabs"))
        // The new window joins the tab group, in front of the first.
        world.addWindow(WindowID(0x2b), properties: WindowProperties(appID: "com.example.editor", appName: "Editor", title: "todo.txt", pid: 42), frame: Rect(x: 0, y: 0, width: 300, height: 200))
        let response = QueryResponder.respond(to: .workspaces, json: true, context: QueryContext(world: world))
        let workspaces = try JSONDecoder().decode([WorkspaceInfo].self, from: Data(response.utf8))
        #expect(workspaces.first?.windows == 2)
    }

    @Test func displays() throws {
        let response = QueryResponder.respond(to: .displays, json: true, context: QueryContext(world: world()))
        let displays = try JSONDecoder().decode([DisplayInfo].self, from: Data(response.utf8))
        #expect(displays.first?.usableFrame == FrameInfo(x: 0, y: 30, width: 1000, height: 570))
        #expect(displays.first?.isFocused == true)
        #expect(displays.first?.isMain == true)
    }

    @Test func textForPeople() {
        let text = QueryResponder.respond(to: .focused, json: false, context: QueryContext(world: world()))
        #expect(text.contains("window     0x2a"))
        #expect(text.contains("app        Editor (com.example.editor)"))
        let windows = QueryResponder.respond(to: .windows, json: false, context: QueryContext(world: world()))
        #expect(windows == "0x2a  1  tiled  Editor — notes.txt\n")
    }

    @Test func textColumnsStayAlignedWithoutAMarker() throws {
        var world = world()
        _ = try world.perform(Action(parsing: "workspace 2"))
        world.addWindow(WindowID(0x2b), properties: WindowProperties(appID: "com.example.editor", appName: "Editor", title: "b", pid: 42), frame: Rect(x: 0, y: 0, width: 300, height: 200))
        let text = QueryResponder.respond(to: .workspaces, json: false, context: QueryContext(world: world))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("   1  "))
        #expect(lines[1].hasPrefix("▸  2  "))
    }

    @Test func shortcutsAreWrittenWithTheMainKey() throws {
        let binding = KeyBinding(modifiers: [.capsLock, .shift], trigger: .key("l"), command: .action(try Action(parsing: "resize by 10 0")), options: .repeats)
        let response = QueryResponder.respond(to: .shortcuts, json: true, context: QueryContext(world: world(), bindings: [binding]))
        let shortcuts = try JSONDecoder().decode([ShortcutInfo].self, from: Data(response.utf8))
        #expect(shortcuts.first?.keys == "mod-shift-l")
        #expect(shortcuts.first?.action == "resize by 10 0")
        #expect(shortcuts.first?.repeats == true)
    }

    @Test func eventsAreLinesOfJSON() {
        #expect(QueryResponder.line(for: .workspaceShown(workspace: "2", name: "Mail", display: "Built-in")) == #"{"display":"Built-in","event":"workspace-shown","name":"Mail","workspace":"2"}"#)
        #expect(QueryResponder.line(for: .windowFocused(nil, bundleID: "", title: "")) == #"{"bundleID":"","event":"window-focused","title":"","window":null}"#)
        #expect(QueryResponder.line(for: .tilingPaused(true)) == #"{"event":"tiling-paused","paused":true}"#)
        // Every event names windows the same way.
        #expect(QueryResponder.line(for: .windowClosed(WindowID(0x1d))) == #"{"event":"window-closed","window":"0x1d"}"#)
        #expect(QueryResponder.line(for: .floatingChanged(WindowID(0x1d), isFloating: true)) == #"{"event":"floating-changed","floating":true,"window":"0x1d"}"#)
    }
}

@Suite("Sockets", .serialized)
struct SocketTests {
    func temporaryPaths() throws -> SocketPaths {
        let directory = URL(fileURLWithPath: "/tmp/moss-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let paths = SocketPaths(directory: directory)
        try paths.prepare()
        return paths
    }

    @Test func requestResponse() async throws {
        let paths = try temporaryPaths()
        let server = ControlServer(url: paths.control) { request in "echo: \(request)" }
        try server.start()
        defer { server.stop() }

        let client = IPCClient(paths: paths)
        let response = try await Task.detached { try client.send("--json windows") }.value
        #expect(response == "echo: --json windows")
    }

    @Test func eventsReachSubscribers() async throws {
        let paths = try temporaryPaths()
        let broadcaster = EventBroadcaster(url: paths.events)
        try broadcaster.start()
        defer { broadcaster.stop() }

        let stream = IPCClient(paths: paths).events()
        for _ in 0..<100 where broadcaster.subscriberCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        broadcaster.publish([.custom("hello"), .tilingPaused(false)])

        var received: [String] = []
        for try await line in stream {
            received.append(line)
            if received.count == 2 { break }
        }
        #expect(received == [#"{"event":"custom","text":"hello"}"#, #"{"event":"tiling-paused","paused":false}"#])
    }

    @Test func connectingWithoutAServerFails() throws {
        let paths = try temporaryPaths()
        #expect(throws: SocketError.self) { try IPCClient(paths: paths).send("version") }
    }
}
