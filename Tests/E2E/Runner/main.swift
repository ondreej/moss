import AppKit
import MossIPC

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
    func open(_ tag: String, count: Int = 1, kind: String = "standard", size: String? = nil, minimum: String? = nil) throws -> [WindowInfo] {
        var arguments = ["-n", "-W", factory.path, "--args", "--tag", tag, "--count", String(count), "--kind", kind]
        if let size { arguments += ["--size", size] }
        if let minimum { arguments += ["--min", minimum] }
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
        let pids = Set((try? windows().filter { $0.bundleID.contains("WindowFactory") }.map(\.pid)) ?? [])
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

    Scenario(name: "dialogs and fixed-size windows float") { s in
        let dialog = try s.open("dialog", kind: "dialog", size: "300x200")[0]
        let fixed = try s.open("fixed", kind: "fixed", size: "320x240")[0]
        try s.expect(dialog.isFloating, "dialog is tiled")
        try s.expect(fixed.isFloating, "fixed-size window is tiled")
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
