public import MossCore
import Foundation

/// Everything needed to answer requests that only read state.
public struct QueryContext: Sendable {
    public var world: World
    public var bindings: [KeyBinding]
    public var configurationErrors: [String]
    /// Every option, in documentation order.
    public var options: [OptionState]
    public var version: String
    public var accessibilityGranted: Bool
    public var configFile: String
    public var socketDirectory: String
    public var isPaused: Bool

    public init(
        world: World,
        bindings: [KeyBinding] = [],
        configurationErrors: [String] = [],
        options: [OptionState] = [],
        version: String = "dev",
        accessibilityGranted: Bool = true,
        configFile: String = "",
        socketDirectory: String = "",
        isPaused: Bool = false
    ) {
        self.world = world
        self.bindings = bindings
        self.configurationErrors = configurationErrors
        self.options = options
        self.version = version
        self.accessibilityGranted = accessibilityGranted
        self.configFile = configFile
        self.socketDirectory = socketDirectory
        self.isPaused = isPaused
    }
}

/// The current value of a configuration option.
public struct OptionState: Hashable, Sendable {
    public var path: String
    public var value: String
    public var defaultValue: String
    public var type: String
    public var isSet: Bool

    public init(path: String, value: String, defaultValue: String, type: String, isSet: Bool) {
        self.path = path
        self.value = value
        self.defaultValue = defaultValue
        self.type = type
        self.isSet = isSet
    }

    var info: OptionInfo { OptionInfo(option: path, value: value, defaultValue: defaultValue, type: type, isSet: isSet) }
}

/// Answers requests that only read state, as JSON or as text for people.
public enum QueryResponder {
    public static func respond(to command: ControlCommand, json: Bool, context: QueryContext) -> String {
        let snapshot = Snapshot(context.world)
        switch command {
        case .windows:
            let windows = snapshot.windows()
            return json ? encode(windows) : TextTable.windows(windows)
        case .focused:
            guard let window = snapshot.focusedWindow() else { return json ? "null\n" : "No window has focus.\n" }
            return json ? encode(window) : TextTable.details(of: window)
        case .workspaces:
            let workspaces = snapshot.workspaces()
            return json ? encode(workspaces) : TextTable.workspaces(workspaces)
        case .displays:
            let displays = snapshot.displays()
            return json ? encode(displays) : TextTable.displays(displays)
        case .shortcuts:
            let shortcuts = context.bindings.map { Snapshot.shortcut($0, mainKey: context.world.settings.keyboard.mainKey) }
            return json ? encode(shortcuts) : TextTable.shortcuts(shortcuts)
        case .status:
            let status = StatusInfo(
                version: context.version,
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                accessibility: context.accessibilityGranted,
                configFile: context.configFile,
                socketDirectory: context.socketDirectory,
                windows: context.world.windows.count,
                displays: context.world.monitors.count,
                isPaused: context.isPaused,
                mode: context.world.mode ?? "default",
                problems: context.configurationErrors
            )
            return json ? encode(status) : TextTable.status(status)
        case .version:
            let info = VersionInfo(name: "Moss", version: context.version, macOS: ProcessInfo.processInfo.operatingSystemVersionString)
            return json ? encode(info) : "Moss \(info.version) on \(info.macOS)\n"
        case .get(nil):
            return json ? encode(context.options.map(\.info)) : context.options.map { "\($0.path) = \($0.value)\n" }.joined()
        case .get(let path?):
            guard let option = context.options.first(where: { $0.path == path.lowercased() }) else {
                return json ? encode(ErrorInfo(error: "no option named '\(path)'")) : "error: no option named '\(path)'\n"
            }
            return json ? encode(option.info) : "\(option.path) = \(option.value)\(option.isSet ? "" : " (default)")\n"
        case .action, .set, .notify, .dismiss, .error, .clearError:
            return "error: not a query\n"
        }
    }

    public static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// An event as a line of JSON on the event stream.
    public static func line(for event: Event) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event) else { return "{\"event\":\"\(event.name)\"}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds the JSON models from the window manager's state.
public struct Snapshot {
    let world: World
    let arrangement: Arrangement
    /// Where each window is, or would be when its workspace is shown.
    let frames: [WindowID: Rect]
    let history: [WindowID]

    public init(_ world: World) {
        self.world = world
        let arrangement = world.arrangement()
        var frames = arrangement.frames
        let hiddenWorkspaces = Set(arrangement.hidden.keys.compactMap { world.windows[$0]?.workspace })
        for workspace in hiddenWorkspaces {
            frames.merge(world.layoutFrames(of: workspace)) { visible, _ in visible }
        }
        self.arrangement = arrangement
        self.frames = frames
        self.history = world.focusHistory
    }

    static func frame(_ rect: Rect) -> FrameInfo {
        FrameInfo(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public func window(_ window: Window) -> WindowInfo {
        let monitor = world.workspaces[window.workspace].flatMap { world.monitor($0.monitor) }
        return WindowInfo(
            id: window.id.address,
            app: window.properties.appName,
            bundleID: window.properties.appID,
            title: window.properties.title,
            pid: window.properties.pid,
            workspace: window.workspace.name,
            display: monitor?.name ?? "",
            frame: Self.frame(frames[window.id] ?? window.floatingFrame),
            isFloating: window.isFloating,
            fullscreen: window.fullscreen?.description,
            isPinned: window.isPinned,
            keepsSize: window.keepsSize,
            isHidden: arrangement.frames[window.id] == nil,
            tabs: world.group(of: window.id)?.members.map(\.address),
            focusOrder: history.firstIndex(of: window.id),
            tags: window.allTags.sorted()
        )
    }

    public func windows() -> [WindowInfo] { world.sortedWindows.map(window) }

    public func focusedWindow() -> WindowInfo? { world.focusedWindow.map(window) }

    public func workspace(_ workspace: Workspace) -> WorkspaceInfo {
        WorkspaceInfo(
            workspace: workspace.id.name,
            name: world.displayName(of: workspace.id),
            number: workspace.id.number,
            isScratchpad: workspace.id.isScratchpad,
            display: world.monitor(workspace.monitor)?.name ?? "",
            windows: world.windowCount(on: workspace.id),
            isFocused: workspace.id == world.focusedWorkspaceID,
            isVisible: world.isVisible(workspace.id),
            layout: workspace.tiling.kind.rawValue,
            hasFullscreen: workspace.fullscreenWindow != nil,
            isPersistent: workspace.isPersistent,
            lastFocusedWindow: workspace.lastFocused?.address
        )
    }

    public func workspaces() -> [WorkspaceInfo] { world.sortedWorkspaces.map(workspace) }

    public func displays() -> [DisplayInfo] {
        world.monitors.map { monitor in
            DisplayInfo(
                id: Int(monitor.id.rawValue),
                name: monitor.name,
                frame: Self.frame(monitor.frame),
                usableFrame: Self.frame(monitor.usableFrame),
                scale: monitor.scale,
                isBuiltIn: monitor.isBuiltin,
                isMain: monitor.isMain,
                isFocused: monitor.id == world.focusedMonitorID,
                workspace: monitor.activeWorkspace.name,
                scratchpad: monitor.activeScratchpad?.name
            )
        }
    }

    public static func shortcut(_ binding: KeyBinding, mainKey: Modifiers) -> ShortcutInfo {
        let action = switch binding.command {
        case .action(let action): action.description
        case .drag(let drag): drag.rawValue
        }
        return ShortcutInfo(
            keys: binding.chord.description(mainKey: mainKey),
            mode: binding.mode,
            action: action,
            description: binding.summary,
            repeats: binding.options.contains(.repeats),
            onRelease: binding.options.contains(.onRelease),
            passesThrough: binding.options.contains(.passesThrough)
        )
    }
}

// MARK: - Text

/// Answers formatted for reading in a terminal.
enum TextTable {
    static func windows(_ windows: [WindowInfo]) -> String {
        guard !windows.isEmpty else { return "No windows.\n" }
        return table(windows.map { window in
            [window.id, window.workspace, state(of: window), window.title.isEmpty ? window.app : "\(window.app) — \(window.title)"]
        })
    }

    static func details(of window: WindowInfo) -> String {
        let frame = window.frame
        return lines([
            ("window", window.id),
            ("app", "\(window.app) (\(window.bundleID))"),
            ("title", window.title),
            ("workspace", window.workspace),
            ("display", window.display),
            ("state", state(of: window)),
            ("frame", "\(number(frame.width))×\(number(frame.height)) at \(number(frame.x)), \(number(frame.y))"),
            ("tabs", window.tabs?.joined(separator: " ") ?? "none"),
            ("tags", window.tags.isEmpty ? "none" : window.tags.joined(separator: " ")),
            ("pid", String(window.pid)),
        ])
    }

    static func workspaces(_ workspaces: [WorkspaceInfo]) -> String {
        table(workspaces.map { workspace in
            [
                workspace.isFocused ? "▸" : workspace.isVisible ? "·" : " ",
                workspace.workspace,
                workspace.name == workspace.workspace ? "" : workspace.name,
                workspace.display,
                "\(workspace.windows) window\(workspace.windows == 1 ? "" : "s")",
                workspace.layout,
            ]
        })
    }

    static func displays(_ displays: [DisplayInfo]) -> String {
        table(displays.map { display in
            [
                display.isFocused ? "▸" : " ",
                String(display.id),
                display.name,
                "\(number(display.frame.width))×\(number(display.frame.height)) @\(number(display.scale))x",
                "workspace \(display.workspace)" + (display.scratchpad.map { ", \($0)" } ?? ""),
            ]
        })
    }

    static func shortcuts(_ shortcuts: [ShortcutInfo]) -> String {
        let modes = shortcuts.reduce(into: [String?]()) { modes, shortcut in
            if !modes.contains(shortcut.mode) { modes.append(shortcut.mode) }
        }
        return modes.map { mode in
            let rows = shortcuts.filter { $0.mode == mode }.map { [$0.keys, $0.action] }
            return (mode.map { "mode \($0):\n" } ?? "") + table(rows)
        }.joined(separator: "\n")
    }

    static func status(_ status: StatusInfo) -> String {
        lines([
            ("version", status.version),
            ("macOS", status.macOS),
            ("accessibility", status.accessibility ? "granted" : "not granted"),
            ("tiling", status.isPaused ? "paused" : "active"),
            ("mode", status.mode),
            ("windows", String(status.windows)),
            ("displays", String(status.displays)),
            ("config", status.configFile),
            ("sockets", status.socketDirectory),
        ]) + (status.problems.isEmpty ? "" : "\nproblems in the configuration:\n" + status.problems.map { "  \($0)\n" }.joined())
    }

    private static func state(of window: WindowInfo) -> String {
        var words = [window.fullscreen ?? (window.isFloating ? "floating" : "tiled")]
        if window.isPinned { words.append("pinned") }
        if window.isHidden { words.append("hidden") }
        return words.joined(separator: ", ")
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Rows padded into columns.
    private static func table(_ rows: [[String]]) -> String {
        guard let columns = rows.map(\.count).max() else { return "" }
        let widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, text in
                column == row.count - 1 ? text : text.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingTrailingSpaces
        }.joined(separator: "\n") + "\n"
    }

    private static func lines(_ pairs: [(String, String)]) -> String {
        let width = pairs.map(\.0.count).max() ?? 0
        return pairs.map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)\n" }.joined()
    }
}

private extension String {
    /// The text without spaces at its end; leading spaces keep columns aligned.
    var trimmingTrailingSpaces: String {
        String(reversed().drop { $0 == " " }.reversed())
    }
}
