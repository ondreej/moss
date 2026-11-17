public import MossCore

/// Plain-language descriptions of shortcuts and rules for the interface.
public enum Describe {
    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case launch = "Launch"
        case windows = "Windows"
        case focus = "Focus & Movement"
        case workspaces = "Workspaces"
        case layout = "Layout"
        case tabs = "Tabs"
        case mouse = "Mouse"
        case system = "Moss"

        public var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .launch: "app.badge"
            case .windows: "macwindow"
            case .focus: "arrow.up.and.down.and.arrow.left.and.right"
            case .workspaces: "square.stack.3d.up"
            case .layout: "rectangle.split.2x1"
            case .tabs: "rectangle.stack"
            case .mouse: "computermouse"
            case .system: "gearshape"
            }
        }
    }

    public static func category(of command: KeyBinding.Command) -> Category {
        guard case .action(let action) = command else { return .mouse }
        switch action {
        case .run, .sendKeys: return .launch
        case .close, .quitApp, .signal, .float, .fullscreen, .maximize, .keepSize, .pin, .center, .tag, .bringToFront, .resize, .position:
            return .windows
        case .focus, .focusLast, .focusWindow, .cycle, .move, .moveToDisplay, .swap, .swapInOrder, .focusDisplay:
            return .focus
        case .workspace, .moveToWorkspace, .bringWorkspace, .renameWorkspace, .scratchpad, .moveWorkspaceToDisplay, .swapWorkspaces:
            return .workspaces
        case .splitRatio, .useLayout, .layout:
            return .layout
        case .tabs, .tab, .joinTabs, .leaveTabs, .moveTab:
            return .tabs
        case .mode, .emit, .show, .pause, .startAtLogin, .reload, .quit:
            return .system
        }
    }

    public static func command(_ command: KeyBinding.Command) -> String {
        switch command {
        case .drag(.move): "Drag to move a window"
        case .drag(.resize): "Drag to resize a window"
        case .action(let action): self.action(action)
        }
    }

    public static func action(_ action: Action) -> String {
        func toggled(_ change: Action.Switch, _ on: String, _ off: String, _ toggle: String) -> String {
            switch change {
            case .on: on
            case .off: off
            case .toggle: toggle
            }
        }
        switch action {
        case .run(let command): return launchDescription(command)
        case .close(nil): return "Close window"
        case .close(let selector?): return "Close \(selector)"
        case .quitApp(nil): return "Quit application"
        case .quitApp(let selector?): return "Quit \(selector)"
        case .signal(let number, _): return "Send signal \(number)"
        case .sendKeys(let chord, _): return "Press \(keys(chord))"
        case .workspace(let selector): return "Go to " + workspace(selector)
        case .moveToWorkspace(let selector, _, let follow): return (follow ? "Move window to " : "Send window to ") + workspace(selector)
        case .bringWorkspace(let selector): return "Bring " + workspace(selector) + " here"
        case .renameWorkspace(let number, let name): return "Rename workspace \(number)" + (name.map { " to \($0)" } ?? "")
        case .scratchpad(let name): return "Show or hide " + (name.map { "scratchpad “\($0)”" } ?? "the scratchpad")
        case .float(let change, _): return toggled(change, "Float window", "Tile window", "Float or tile window")
        case .fullscreen(let change): return toggled(change, "Enter fullscreen", "Leave fullscreen", "Toggle fullscreen")
        case .maximize(let change): return toggled(change, "Maximize", "Unmaximize", "Toggle maximize")
        case .keepSize(let change, _): return toggled(change, "Keep window size", "Fill tile", "Keep window size or fill tile")
        case .pin(let change, _): return toggled(change, "Pin to all workspaces", "Unpin", "Pin or unpin window")
        case .center: return "Center window"
        case .tag(let change, _): return "Tag window \(change)"
        case .bringToFront: return "Bring to front"
        case .focus(let direction): return "Focus " + direction.rawValue
        case .focusLast: return "Focus last window"
        case .focusWindow(let selector): return "Focus \(selector)"
        case .cycle(let options): return options.previous ? "Focus previous window" : "Focus next window"
        case .move(let direction): return "Move window " + direction.rawValue
        case .moveToDisplay(let display): return "Move window to display \(display)"
        case .swap(let direction): return "Swap window " + direction.rawValue
        case .swapInOrder(let forward): return forward ? "Swap with next window" : "Swap with previous window"
        case .resize(let parameter): return parameter.exact ? "Resize window to \(parameter.x) × \(parameter.y)" : "Resize window by \(parameter.x), \(parameter.y)"
        case .position(let parameter): return parameter.exact ? "Move window to \(parameter.x), \(parameter.y)" : "Move window by \(parameter.x), \(parameter.y)"
        case .splitRatio: return "Change the split"
        case .useLayout(.style(let kind)): return "Use the \(layoutName(kind)) layout"
        case .useLayout(.configured): return "Use the configured layout"
        case .useLayout(.toggle(let kind)): return "Toggle the \(layoutName(kind)) layout"
        case .layout(let message): return layoutAction(message)
        case .focusDisplay(let display): return "Focus display \(display)"
        case .moveWorkspaceToDisplay(let display, _): return "Move workspace to display \(display)"
        case .swapWorkspaces: return "Swap workspaces between displays"
        case .tabs: return "Put window in tabs, or take tabs apart"
        case .tab(.next): return "Next tab"
        case .tab(.previous): return "Previous tab"
        case .tab(.index(let index)): return "Tab \(index)"
        case .joinTabs(let direction): return "Join tabs " + direction.rawValue
        case .leaveTabs: return "Leave tabs"
        case .moveTab(let forward): return forward ? "Move tab forward" : "Move tab back"
        case .mode(let name): return name.map { "Enter “\($0)” mode" } ?? "Leave mode"
        case .emit(let text): return "Send event “\(text)”"
        case .show(.palette): return "Open the palette"
        case .show(.overview): return "Show all workspaces"
        case .show(.overviewPrevious): return "Show all workspaces, stepping back"
        case .pause(let change): return toggled(change, "Pause tiling", "Resume tiling", "Pause or resume tiling")
        case .startAtLogin(let change): return toggled(change, "Open Moss at login", "Stop opening Moss at login", "Turn opening Moss at login on or off")
        case .reload: return "Reload configuration"
        case .quit: return "Quit Moss"
        }
    }

    static func keys(_ chord: KeyChord) -> String {
        let key = switch chord.key {
        case .key(let name): KeyNames.displayName(for: name)
        case .keyCode(let code): "key \(code)"
        default: chord.key.description
        }
        return chord.modifiers.symbols + key
    }

    static func workspace(_ selector: WorkspaceSelector) -> String {
        switch selector {
        case .id(let number): "workspace \(number)"
        case .named(let name): "workspace “\(name)”"
        case .scratchpad(let name): name == WorkspaceID.defaultScratchpadName ? "the scratchpad" : "scratchpad “\(name)”"
        case .relative(let delta): delta >= 0 ? "the next workspace number" : "the previous workspace number"
        case .adjacent(let delta): delta >= 0 ? "the next workspace" : "the previous workspace"
        case .last: "the last workspace"
        case .empty: "an empty workspace"
        }
    }

    static func layoutName(_ kind: LayoutKind) -> String {
        switch kind {
        case .bsp: "BSP"
        case .stack: "stack"
        case .scrolling: "scrolling"
        }
    }

    static func layoutAction(_ message: LayoutMessage) -> String {
        Action.catalog.first { $0.verb == message.command }?.summary ?? message.description
    }

    /// Recognises `open -a App` style commands.
    static func launchDescription(_ command: String) -> String {
        let command = (try? Action.splitRunRules(command).command) ?? command
        let words = command.split(separator: " ").map(String.init)
        // `open PATH` opens a folder or file.
        if words.first == "open", words.count == 2, !words[1].hasPrefix("-") {
            return words[1] == "~" ? "Open the home folder" : "Open \((words[1] as NSString).lastPathComponent)"
        }
        guard words.first == "open", let flag = words.firstIndex(where: { $0 == "-a" || $0 == "-na" }), flag + 1 < words.count else {
            return "Run \(command)"
        }
        let name = words[(flag + 1)...]
            .prefix { !$0.hasPrefix("-") && !$0.hasPrefix("~") && !$0.hasPrefix("/") }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return name.isEmpty ? "Run \(command)" : "Open \(name)"
    }
}

import Foundation
