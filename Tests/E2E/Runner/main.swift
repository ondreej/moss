import AppKit
import IOKit.hidsystem
import MossIPC

/// Maps an accessibility window element to its window server identifier.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// End-to-end tests against a running Moss instance on a real macOS session.
//
//     moss-e2e <path to WindowFactory.app> [scenario name filter]
//
// Each scenario opens real windows with WindowFactory, drives Moss through its control
// socket, and checks both Moss's model and the frames the window server reports. Run it on
// a machine dedicated to testing: it opens, moves and closes windows.

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Frame: Equatable, CustomStringConvertible {
    var x, y, width, height: Double
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var description: String { "(\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height)))" }

    func overlaps(_ other: Frame) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    func close(to other: Frame, tolerance: Double = 3) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

final class Session {
    let client = IPCClient()
    let factory: URL
    var spawned: [Process] = []

    init(factory: URL) { self.factory = factory }

    // MARK: Control

    @discardableResult
    func run(_ request: String) throws -> String {
        let response = try client.send(request)
        if response.hasPrefix("error:") { throw Failure("'\(request)' failed: \(response)") }
        return response
    }

    func query<T: Decodable>(_ command: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(try run("--json " + command).utf8))
    }

    func windows() throws -> [WindowInfo] { try query("windows") }
    func display() throws -> DisplayInfo { try query("displays", as: [DisplayInfo].self)[0] }
    func focused() throws -> WindowInfo? { try? query("focused") }
    func focusedWorkspace() throws -> String? { try query("workspaces", as: [WorkspaceInfo].self).first(where: \.isFocused)?.workspace }
    func option(_ path: String) throws -> Double {
        Double(try query("get \(path)", as: OptionInfo.self).value.split(separator: " ")[0]) ?? 0
    }

    // MARK: Windows

    /// Opens windows and waits until Moss manages all of them.
    @discardableResult
    func open(_ tag: String, count: Int = 1, kind: String = "standard", size: String? = nil, minimum: String? = nil, level: Int? = nil) throws -> [WindowInfo] {
        var arguments = ["-n", "-W", factory.path, "--args", "--tag", tag, "--count", String(count), "--kind", kind]
        if let size { arguments += ["--size", size] }
        if let minimum { arguments += ["--min", minimum] }
        if let level { arguments += ["--level", String(level)] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        spawned.append(process)
        return try waitFor("\(count) '\(tag)' windows") {
            let matching = try windows().filter { $0.title.hasPrefix(tag + " ") }
            return matching.count == count ? matching.sorted { $0.title < $1.title } : nil
        }
    }

    func window(_ title: String) throws -> WindowInfo {
        guard let window = try windows().first(where: { $0.title == title }) else { throw Failure("no window titled '\(title)'") }
        return window
    }

    /// Moves windows that do not belong to the suite out of the way, onto workspace 99.
    func isolate() throws {
        for window in try windows() where !window.bundleID.contains("WindowFactory") {
            try run("send-to-workspace 99 id:\(window.id)")
        }
    }

    /// Waits until the on-screen frames of `windows` stop changing.
    func settledFrames(_ windows: [WindowInfo]) throws -> [Frame] {
        var previous: [Frame] = []
        return try waitFor("frames to settle") {
            let current = windows.compactMap { Self.screenFrame(of: $0.id) }
            defer { previous = current }
            return current == previous && current.count == windows.count ? current : nil
        }
    }

    func closeAll() {
        // Every factory process, those whose windows Moss does not list, as in fullscreen, too.
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.contains("WindowFactory") == true }.map(\.processIdentifier)
        let pids = Set((try? windows().filter { $0.bundleID.contains("WindowFactory") }.map(\.pid)) ?? []).union(running)
        for pid in pids { kill(pid, SIGTERM) }
        spawned.forEach { $0.terminate() }
        spawned.removeAll()
        try? waitUntil("factory windows to close", timeout: 5) {
            try !windows().contains { $0.bundleID.contains("WindowFactory") }
        }
        // Start every scenario on an empty workspace 1.
        try? waitUntil("workspace 1", timeout: 3) {
            try run("workspace 1")
            Thread.sleep(forTimeInterval: 0.2)
            return try focusedWorkspace() == "1"
        }
    }

    // MARK: Geometry

    static func frame(of window: WindowInfo) -> Frame {
        Frame(x: window.frame.x, y: window.frame.y, width: window.frame.width, height: window.frame.height)
    }

    /// The window's frame as the window server reports it, independently of Moss.
    static func screenFrame(of address: String) -> Frame? {
        guard let id = UInt32(address.dropFirst(2), radix: 16),
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let info = list.first, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return Frame(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// The application whose window is in front of all others, leaving out Moss's borders.
    static func frontmostOwner() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let front = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerName as String] as? String) != "Moss" }
        return front?[kCGWindowOwnerPID as String] as? pid_t
    }

    /// The process of the active application, the one keys go to, as Launch Services knows it.
    static func activeApplication() -> pid_t? {
        func lsappinfo(_ arguments: [String]) -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
            process.arguments = arguments
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return "" }
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let front = lsappinfo(["front"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let info = lsappinfo(["info", "-only", "pid", front])
        return info.split(separator: "=").last.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The window the application's keyboard input goes to, as the accessibility API reports it.
    static func keyWindow(of pid: pid_t) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(focused as! AXUIElement, &id) == .success else { return nil }
        return "0x" + String(id, radix: 16)
    }

    /// Whether the window server shows window `upper` in front of window `lower`.
    static func isInFront(_ upper: String, of lower: String) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let order = list.compactMap { ($0[kCGWindowNumber as String] as? UInt32).map { "0x" + String($0, radix: 16) } }
        guard let upperIndex = order.firstIndex(of: upper), let lowerIndex = order.firstIndex(of: lower) else { return false }
        return upperIndex < lowerIndex
    }

    /// Makes an application the active one, as launchers do.
    static func activate(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Whether the window is on screen in the Space shown, as opposed to another Space.
    static func isShown(_ address: String) -> Bool {
        guard let id = UInt32(address.dropFirst(2), radix: 16),
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]])?.first else { return false }
        return info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Whether the application shows a window above `level`, as the bubble beside the text
    /// cursor is above the window it belongs to.
    static func showsWindow(of pid: pid_t, above level: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int ?? 0 > level }
    }

    /// Waits until the window server shows every visible window where Moss says it is.
    func expectOnScreen(_ windows: [WindowInfo]) throws {
        for window in windows where !window.isHidden {
            let expected = Self.frame(of: window)
            try waitUntil("\(window.title) on screen at \(expected)") {
                guard let actual = Self.screenFrame(of: window.id) else { return false }
                return actual.close(to: expected)
            }
        }
    }

    func waitUntil(_ what: @autoclosure () throws -> String, timeout: Double = 4, interval: Double = 0.05, _ check: () throws -> Bool) throws {
        try waitFor(try what(), timeout: timeout, interval: interval) { try check() ? () : nil }
    }

    @discardableResult
    /// Polls `check` until it returns a value. `what` describes the condition and is evaluated
    /// when the wait times out, so it can report the state at that moment.
    func waitFor<T>(_ what: @autoclosure () throws -> String, timeout: Double = 4, interval: Double = 0.05, _ check: () throws -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: (any Error)?
        while Date() < deadline {
            do {
                if let value = try check() { return value }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: interval)
        }
        let description = (try? what()) ?? "condition"
        throw Failure("timed out waiting for \(description)" + (lastError.map { " (\($0))" } ?? ""))
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message()) }
    }
}

/// Caps Lock's state, set the way the key sets it.
enum CapsLock {
    static func set(_ isOn: Bool) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connection) }
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), isOn)
    }
}

// MARK: - Scenarios

struct Scenario {
    let name: String
    let body: (Session) throws -> Void
}

let scenarios: [Scenario] = [
    Scenario(name: "tiles two windows side by side") { s in
        let windows = try s.open("pair", count: 2)
        try s.waitUntil("both windows tiled") {
            let frames = try s.windows().filter { $0.title.hasPrefix("pair ") }.map(Session.frame)
            return frames.count == 2 && abs(frames[0].width - frames[1].width) <= 2 && abs(frames[0].y - frames[1].y) <= 1
        }
        let tiled = try s.windows().filter { $0.title.hasPrefix("pair ") }.sorted { $0.frame.x < $1.frame.x }
        let (left, right) = (Session.frame(of: tiled[0]), Session.frame(of: tiled[1]))
        let gap = (try s.option("layout.gaps")) + 2 * (try s.option("borders.width"))
        try s.expect(abs(right.x - left.maxX - gap) <= 1, "gap between windows is \(right.x - left.maxX), expected \(gap)")
        try s.expectOnScreen(windows.isEmpty ? [] : tiled)
    },

    Scenario(name: "the BSP layout splits the focused tile") { s in
        try s.open("split", count: 3)
        let frames = try s.windows().filter { $0.title.hasPrefix("split ") }.map(Session.frame)
        let columns = Set(frames.map { Int($0.x) })
        try s.expect(columns.count == 2, "expected two columns, got frames \(frames)")
        try s.expectOnScreen(try s.windows())
    },

    Scenario(name: "workspaces hide and restore windows") { s in
        let window = try s.open("ws")[0]
        let before = Session.frame(of: window)
        try s.run("workspace 2")
        try s.waitUntil("window hidden") { try s.window("ws 1").isHidden }
        try s.waitUntil("window parked off screen") {
            guard let frame = Session.screenFrame(of: window.id) else { return false }
            return frame.x > before.maxX || frame.y > before.maxY
        }
        try s.run("workspace 1")
        try s.waitUntil("window restored to \(before), now at \(String(describing: Session.screenFrame(of: window.id)))") {
            guard let frame = Session.screenFrame(of: window.id) else { return false }
            return frame.close(to: before)
        }
    },

    Scenario(name: "move-to-workspace follows the window") { s in
        try s.open("move", count: 2)
        try s.run("focus-window title:^move 2$")
        try s.run("move-to-workspace 3")
        let focused = try s.focusedWorkspace()
        try s.expect(focused == "3", "focused workspace is \(focused ?? "none")")
        try s.expect(try s.window("move 2").workspace == "3", "window did not move")
        try s.expect(try s.focused()?.title == "move 2", "focus did not follow")
        try s.run("send-to-workspace 1")
        try s.expect(try s.focusedWorkspace() == "3", "send-to-workspace switched workspaces")
    },

    Scenario(name: "floating, fullscreen and back") { s in
        try s.open("float", count: 2)
        try s.run("focus-window title:^float 1$")
        try s.run("float")
        try s.expect(try s.window("float 1").isFloating, "window is not floating")
        let display = try s.display()
        try s.waitUntil("remaining window fills the screen") {
            let frame = Session.frame(of: try s.window("float 2"))
            return frame.width > display.frame.width * 0.8
        }
        try s.run("float")
        try s.run("fullscreen")
        try s.waitUntil("fullscreen frame on screen") {
            let window = try s.window("float 1")
            guard window.fullscreen == "fullscreen", let frame = Session.screenFrame(of: window.id) else { return false }
            return frame.width >= display.frame.width - 2
        }
        try s.run("fullscreen")
    },

    Scenario(name: "video fullscreen in a window of its own") { s in
        // Browsers show a video in fullscreen by closing the window and covering the screen
        // with another, then open a new window when it ends. The window beside must not come
        // up over the video, and the new window takes the old one's tile.
        let beside = try s.open("beside")[0]
        let video = try s.open("video", kind: "video")[0]
        let tiles = try s.settledFrames([beside, video])
        kill(video.pid, SIGUSR1)
        try s.waitUntil("the video window to leave the layout") { try !s.windows().contains { $0.id == video.id } }
        Thread.sleep(forTimeInterval: 0.5)
        try s.expect(Session.frontmostOwner() == video.pid, "a window came up over the video; front: pid \(Session.frontmostOwner().map(String.init) ?? "none")")
        kill(video.pid, SIGUSR1)
        let back = try s.waitFor("the video window to come back") { try s.windows().first { $0.title == video.title && $0.id != video.id } }
        let frames = try s.settledFrames([beside, back])
        try s.expect(zip(frames, tiles).allSatisfy { $0.close(to: $1) }, "windows at \(frames) instead of their tiles \(tiles)")
        try s.waitUntil("the video window to have focus; focused: \(String(describing: try? s.focused()?.title))") { try s.focused()?.id == back.id }
    },

    Scenario(name: "the Caps Lock bubble beside the text cursor is left alone") { s in
        // While Caps Lock is on, macOS shows a bubble beside the text cursor in a small window
        // of the app being typed in. Focusing it would take the cursor away, which hides the
        // bubble, and focusing the text again would bring it back, over and over. Launchers
        // raise their windows above others, and the bubble goes above them in turn.
        for (tag, level) in [("text", 0), ("raised", Int(CGWindowLevelForKey(.modalPanelWindow)))] {
            let text = try s.open(tag, kind: "text", level: level == 0 ? nil : level)[0]
            try s.waitUntil("the \(tag) window to have focus") { try s.focused()?.id == text.id }
            CapsLock.set(true)
            defer { CapsLock.set(false) }
            try s.waitUntil("macOS to show the Caps Lock bubble over the \(tag) window") { Session.showsWindow(of: text.pid, above: level) }
            Thread.sleep(forTimeInterval: 1)
            let managed = try s.windows().filter { $0.pid == text.pid }.map(\.title)
            try s.expect(managed == [text.title], "Moss manages \(managed), not just \(text.title)")
            try s.expect(try s.focused()?.id == text.id, "focus moved to \(String(describing: try? s.focused()?.title))")
            try s.expect(Session.showsWindow(of: text.pid, above: level), "the bubble over the \(tag) window went away")
        }
    },

    Scenario(name: "notices over everything are left alone") { s in
        // Keyboard utilities show "Caps Lock On" in an untitled window over everything, from
        // an app in the background. Focusing it would take focus from the window in use.
        let notifier = try s.open("notifier", kind: "notice")[0]
        let typing = try s.open("typing")[0]
        try s.waitUntil("the typing window to have focus") { try s.focused()?.id == typing.id }
        kill(notifier.pid, SIGUSR1)
        try s.waitUntil("the notice to show") { Session.showsWindow(of: notifier.pid, above: 0) }
        Thread.sleep(forTimeInterval: 1)
        let managed = try s.windows().filter { $0.pid == notifier.pid }.map(\.title)
        try s.expect(managed == [notifier.title], "Moss manages \(managed), not just \(notifier.title)")
        try s.expect(try s.focused()?.id == typing.id, "focus moved to \(String(describing: try? s.focused()?.title))")
        try s.expect(Session.frontmostOwner() == typing.pid, "the notice's app came to the front")
    },

    Scenario(name: "floating windows stay above the tiles") { s in
        // A tile that a floating window overlaps takes focus where it is in the stacking order,
        // so the floating window of another application is not buried under it: coming from
        // that window, and coming from another window of the tile's own application.
        let tiles = try s.open("tile", count: 2)
        let floating = try s.open("floating", kind: "dialog", size: "300x200")[0]
        try s.expect(floating.isFloating, "the dialog is tiled")
        let over = Session.frame(of: floating)
        guard let covered = tiles.first(where: { Session.frame(of: $0).overlaps(over) }),
              let other = tiles.first(where: { $0.id != covered.id }) else {
            throw Failure("the floating window at \(over) is over no tile: \(tiles.map(Session.frame))")
        }
        try s.waitUntil("the floating window in front") { Session.isInFront(floating.id, of: covered.id) }
        for from in [floating, other] {
            try s.run("focus-window id:\(from.id)")
            try s.waitUntil("\(from.title) to have focus") { try s.focused()?.id == from.id }
            Thread.sleep(forTimeInterval: 0.3)
            try s.run("focus-window id:\(covered.id)")
            try s.waitUntil("\(covered.title) to have focus") { try s.focused()?.id == covered.id }
            Thread.sleep(forTimeInterval: 0.5)
            try s.expect(Session.isInFront(floating.id, of: covered.id), "coming from \(from.title), the tile came up over the floating window")
            try s.expect(Session.activeApplication() == covered.pid, "coming from \(from.title), the tile's application is not active")
            try s.expect(Session.keyWindow(of: covered.pid) == covered.id, "coming from \(from.title), \(String(describing: Session.keyWindow(of: covered.pid))) has the keyboard, not \(covered.title)")
        }
    },

    Scenario(name: "dialogs and fixed-size windows float") { s in
        let dialog = try s.open("dialog", kind: "dialog", size: "300x200")[0]
        let fixed = try s.open("fixed", kind: "fixed", size: "320x240")[0]
        try s.expect(dialog.isFloating, "dialog is tiled")
        try s.expect(fixed.isFloating, "fixed-size window is tiled")
    },

    Scenario(name: "a window in macOS fullscreen stays on its workspace") { s in
        // macOS fullscreen puts a window in a Space of its own. Its workspace takes the user
        // there, and the other workspaces back to the desktop.
        let desk = try s.open("desk")[0]
        let movie = try s.open("movie", kind: "fullscreen")[0]
        func spaceShows(_ what: String) throws {
            try s.waitUntil("its Space to show \(what)") { Session.isShown(movie.id) && !Session.isShown(desk.id) }
        }
        func desktopShows(_ what: String) throws {
            try s.waitUntil("the desktop to show \(what)") { !Session.isShown(movie.id) }
        }
        try s.run("send-to-workspace 5 id:\(movie.id)")
        try s.run("workspace 5")
        try s.waitUntil("the movie window to have focus") { try s.focused()?.id == movie.id }
        kill(movie.pid, SIGUSR1)
        try s.waitUntil("the movie window to leave the layout") { try !s.windows().contains { $0.id == movie.id } }
        try spaceShows("for fullscreen")
        let five = try s.query("workspaces", as: [WorkspaceInfo].self).first { $0.workspace == "5" }
        try s.expect(five?.windows == 1, "workspace 5 has \(five.map { String($0.windows) } ?? "no") windows")

        try s.run("workspace 1")
        try desktopShows("for workspace 1")
        try s.waitUntil("the desk window to have focus") { try s.focused()?.id == desk.id }
        try s.run("workspace 5")
        try spaceShows("for workspace 5")
        try s.waitUntil("the movie application to be active") { Session.activeApplication() == movie.pid }
        // An empty workspace has no window to take the display back, and gets the desktop.
        try s.run("workspace 6")
        try desktopShows("for an empty workspace")
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        try s.waitUntil("the desktop to have focus") { Session.activeApplication() == finder }
        Thread.sleep(forTimeInterval: 1)
        try s.expect(!Session.isShown(movie.id), "the Space came back")

        // Passing by its workspace quickly, the user ends up where they went.
        for target in ["6", "1"] {
            try s.run("workspace 5")
            Thread.sleep(forTimeInterval: 0.15)
            try s.run("workspace \(target)")
            Thread.sleep(forTimeInterval: 1.5)
            try desktopShows("after passing by to \(target)")
            let focused = try s.focusedWorkspace()
            try s.expect(focused == target, "workspace \(focused ?? "none") is focused, not \(target)")
        }
        try s.expect(Session.isShown(desk.id), "the desk window is out of sight")

        // Activated from a launcher, it shows its workspace again.
        Session.activate(movie.pid)
        try spaceShows("from a launcher")
        try s.waitUntil("workspace 5 to be focused, not \(String(describing: try? s.focusedWorkspace()))") { try s.focusedWorkspace() == "5" }
        Thread.sleep(forTimeInterval: 1)
        try s.run("workspace 1")
        try desktopShows("after the launcher")

        // Taken along to another workspace, it stays in its Space, which that workspace leads to.
        try s.run("workspace 5")
        try spaceShows("once more")
        try s.run("move-to-workspace 7")
        try s.waitUntil("workspace 7 to be focused") { try s.focusedWorkspace() == "7" }
        Thread.sleep(forTimeInterval: 1)
        try s.expect(Session.isShown(movie.id), "the Space went away as its window moved")
        try s.run("workspace 1")
        try desktopShows("after the move")
        try s.run("workspace 7")
        try spaceShows("from its new workspace")

        // Out of fullscreen, it is back in its workspace's layout.
        kill(movie.pid, SIGUSR1)
        try s.waitUntil("the movie window to be back on workspace 7") { try s.windows().first { $0.id == movie.id }?.workspace == "7" }
        try s.waitUntil("the movie window to have focus once back") { try s.focused()?.id == movie.id }
    },

    Scenario(name: "scratchpads drop down over the workspace") { s in
        try s.open("scratch", count: 2)
        try s.run("focus-window title:^scratch 2$")
        try s.run("send-to-workspace scratchpad:notes")
        try s.waitUntil("window hidden in the scratchpad") { try s.window("scratch 2").isHidden }
        try s.run("scratchpad notes")
        try s.waitUntil("scratchpad shown") { !(try s.window("scratch 2").isHidden) }
        try s.expect(try s.focused()?.title == "scratch 2", "the scratchpad's window is not focused")
        try s.run("scratchpad notes")
        try s.waitUntil("scratchpad hidden") { try s.window("scratch 2").isHidden }
    },

    Scenario(name: "stack layout") { s in
        try s.run("set layout.style stack")
        try s.open("stack", count: 3)
        let display = try s.display()
        let frames = try s.windows().filter { $0.title.hasPrefix("stack ") }.map(Session.frame).sorted { $0.width > $1.width }
        try s.expect(frames[0].height > display.frame.height * 0.7, "the main window does not span the height: \(frames)")
        try s.expect(frames[0].width > frames[1].width, "the main window is not the widest: \(frames)")
        try s.expectOnScreen(try s.windows())
    },

    Scenario(name: "scrolling layout") { s in
        try s.run("set layout.style scrolling")
        try s.open("scroll", count: 3)
        // Columns are half the screen wide, so the first scrolls out of view as the third opens.
        try s.waitUntil("first column scrolled out of view") { try s.window("scroll 1").isHidden }
        try s.run("focus-window title:^scroll 1$")
        try s.waitUntil("first column back in view") { !(try s.window("scroll 1").isHidden) }
        try s.waitUntil("third column scrolled out of view") { try s.window("scroll 3").isHidden }
        let display = try s.display()
        try s.waitUntil("first column at the left edge") {
            guard let frame = Session.screenFrame(of: try s.window("scroll 1").id) else { return false }
            return frame.x < display.frame.x + display.frame.width * 0.1 && frame.width < display.frame.width * 0.6
        }
        try s.run("column-width 1")
        try s.waitUntil("first column fills the screen") {
            guard let frame = Session.screenFrame(of: try s.window("scroll 1").id) else { return false }
            return frame.width > display.frame.width * 0.8
        }
    },

    Scenario(name: "windows that cannot shrink settle") { s in
        // The windows cannot shrink to their tiles. Moss must make room for them instead of
        // repeatedly resizing them, which would show up as frames that keep changing.
        let windows = try s.open("stubborn", count: 3, minimum: "900x200")
        let settled = try s.settledFrames(windows)
        var samples: [[Frame]] = []
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.1)
            samples.append(windows.compactMap { Session.screenFrame(of: $0.id) })
        }
        for sample in samples {
            for (frame, reference) in zip(sample, settled) where !frame.close(to: reference, tolerance: 2) {
                throw Failure("window moved from \(reference) to \(frame) after settling")
            }
        }
    },

    Scenario(name: "closing a window re-tiles the rest") { s in
        try s.open("close", count: 2)
        try s.run("close title:^close 2$")
        let display = try s.display()
        try s.waitUntil("remaining window fills the screen; windows: \(try s.windows().filter { $0.title.hasPrefix("close ") }.map { "\($0.title) \($0.frame)" })") {
            let remaining = try s.windows().filter { $0.title.hasPrefix("close ") }
            guard remaining.count == 1 else { return false }
            return remaining[0].frame.width > display.frame.width * 0.8
        }
    },

    Scenario(name: "focus walks the layout") { s in
        let windows = try s.open("focus", count: 2).sorted { $0.frame.x < $1.frame.x }
        let (left, right) = (windows[0].title, windows[1].title)
        try s.run("focus-window title:^\(right)$")
        try s.run("focus left")
        try s.expect(try s.focused()?.title == left, "focus did not move left, focused: \(String(describing: try? s.focused()?.title))")
        try s.run("focus right")
        try s.expect(try s.focused()?.title == right, "focus did not move right, focused: \(String(describing: try? s.focused()?.title))")
    },

    Scenario(name: "tabs show one window at a time") { s in
        let first = try s.open("tabs a")[0]
        try s.run("tabs")
        try s.run("set tabs.auto-join true")
        let second = try s.open("tabs b")[0]
        try s.waitUntil("one tab shown") {
            let windows = try s.windows().filter { $0.title.hasPrefix("tabs ") }
            return windows.count == 2 && windows.filter(\.isHidden).count == 1 && windows.allSatisfy { $0.tabs?.count == 2 }
        }
        let shown = try s.window("tabs b 1")
        try s.expectOnScreen([shown])
        try s.run("tab next")
        try s.waitUntil("the other tab shown in the same place") {
            let now = try s.window("tabs a 1")
            guard !now.isHidden, let frame = Session.screenFrame(of: first.id) else { return false }
            return frame.close(to: Session.frame(of: shown)) && Session.screenFrame(of: second.id).map { !$0.close(to: frame) } == true
        }
    },

    Scenario(name: "hidden applications come back to their workspaces") { s in
        let window = try s.open("hide")[0]
        try s.run("send-to-workspace 3 id:\(window.id)")
        guard let application = NSRunningApplication(processIdentifier: window.pid) else { throw Failure("no application for pid \(window.pid)") }
        application.hide()
        try s.waitUntil("window to leave the layout") { try !s.windows().contains { $0.id == window.id } }
        application.unhide()
        let back = try s.waitFor("window to return") { try s.windows().first { $0.id == window.id } }
        try s.expect(back.workspace == "3", "window came back on workspace \(back.workspace)")
        try s.expect(back.isHidden, "window on workspace 3 is visible while workspace 1 is shown")
    },

    Scenario(name: "a long stream of window events") { s in
        let windows = try s.open("stream", count: 2)
        // Every flip animates both windows, and each animation step is reported back.
        for _ in 0..<80 {
            try s.run("flip-split")
            Thread.sleep(forTimeInterval: 0.1)
        }
        let frames = try s.settledFrames(windows)
        try s.expect(frames.count == 2, "windows went missing")
        try s.expect(try s.windows().filter { $0.title.hasPrefix("stream ") }.count == 2, "Moss lost track of the windows")
    },

    Scenario(name: "workspace switches are fast") { s in
        let windows = try s.open("speed", count: 4)
        let display = try s.display()
        func parked(_ frame: Frame) -> Bool { frame.x >= display.frame.x + display.frame.width - 2 || frame.maxX <= display.frame.x + 2 }
        var samples: [Double] = []
        for round in 0..<10 {
            let hide = round.isMultiple(of: 2)
            let start = Date()
            try s.run("workspace \(hide ? 2 : 1)")
            // Measured on screen: until the window server shows every window moved.
            try s.waitUntil("switch \(round) on screen, frames: \(windows.compactMap { Session.screenFrame(of: $0.id) })", interval: 0.002) {
                let frames = windows.compactMap { Session.screenFrame(of: $0.id) }
                return frames.count == windows.count && frames.allSatisfy({ parked($0) == hide })
            }
            samples.append(Date().timeIntervalSince(start) * 1000)
        }
        let median = samples.sorted()[samples.count / 2]
        print("    workspace switch with 4 windows, on screen: median \(String(format: "%.1f", median)) ms, worst \(String(format: "%.1f", samples.max() ?? 0)) ms")
        try s.expect(median < 100, "median workspace switch took \(median) ms")
    },
]

// MARK: - Main

let arguments = CommandLine.arguments.dropFirst()
guard let factoryPath = arguments.first else {
    print("usage: moss-e2e <WindowFactory.app> [filter]")
    exit(2)
}
let filter = arguments.dropFirst().first?.lowercased()
let session = Session(factory: URL(fileURLWithPath: factoryPath))

do {
    try session.isolate()
} catch {
    print("could not prepare the session: \(error)")
    exit(1)
}

var failures = 0
/// Settings every scenario starts from, independent of the machine's configuration file.
let baseline = [
    "layout.style bsp",
    "layout.bsp.new-window-side after",
    "tabs.auto-join false",
]

for scenario in scenarios where filter.map({ scenario.name.lowercased().contains($0) }) ?? true {
    session.closeAll()
    _ = try? session.run("reload")
    for setting in baseline { _ = try? session.run("set \(setting)") }
    do {
        try scenario.body(session)
        print("✔ \(scenario.name)")
    } catch {
        failures += 1
        print("✘ \(scenario.name): \(error)")
    }
}
session.closeAll()
print(failures == 0 ? "All scenarios passed." : "\(failures) scenario(s) failed.")
exit(failures == 0 ? 0 : 1)
