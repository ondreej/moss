/// Settings of one workspace, from a `[workspaces.N]` or `[scratchpads.NAME]` table:
///
///     [workspaces.5]
///     name = "Mail"
///     display = "built-in"
public struct WorkspaceRule: Hashable, Sendable {
    public var workspace: WorkspaceID
    /// The display the workspace opens on.
    public var display: MonitorSelector?
    /// The workspace its display shows when Moss starts.
    public var isDefault = false
    /// The workspace stays when it has no windows.
    public var isPersistent = false
    /// The name shown for a numbered workspace.
    public var name: String?
    public var layout: LayoutKind?
    public var gaps: Insets?
    public var margins: Insets?
    public var borderWidth: Double?
    /// `false` draws no borders or tab bars on the workspace.
    public var decorations: Bool?
    /// Windows on the workspace get square corners.
    public var squareCorners: Bool?
    /// The side of the main area in the stack layout.
    public var stackSide: StackSide?
    /// The direction of the scrolling layout.
    public var scrollingDirection: ScrollingDirection?
    /// A command run when the workspace is opened while it has no windows.
    public var whenEmpty: String?

    public init(workspace: WorkspaceID) {
        self.workspace = workspace
    }

    /// Reads a workspace's table. Values are written as text: `true`, `3`, `"built-in"`.
    public init(workspace: WorkspaceID, entries: [(key: String, value: String)]) throws(ActionError) {
        self.init(workspace: workspace)
        for (key, value) in entries {
            func flag() throws(ActionError) -> Bool { try WindowRule.Effect.flag(value, key) }
            func insets() throws(ActionError) -> Insets {
                guard let insets = Insets(cssNotation: value) else { throw .invalidArgument("\(key) expects one to four numbers") }
                return insets
            }
            switch key {
            case "display": display = try MonitorSelector(parsing: value)
            case "default": isDefault = try flag()
            case "persistent": isPersistent = try flag()
            case "name": name = value.isEmpty ? nil : value
            case "layout":
                guard let kind = LayoutKind(rawValue: value.lowercased()) else { throw .invalidArgument("layout expects bsp, stack or scrolling") }
                layout = kind
            case "gaps": gaps = try insets()
            case "margins": margins = try insets()
            case "border-width":
                guard let width = Double(value), width >= 0 else { throw .invalidArgument("border-width expects a number") }
                borderWidth = width
            case "decorations": decorations = try flag()
            case "square-corners": squareCorners = try flag()
            case "stack-side":
                guard let side = StackSide(rawValue: value.lowercased()) else { throw .invalidArgument("stack-side expects left, right, top, bottom or center") }
                stackSide = side
            case "direction":
                guard let direction = ScrollingDirection(rawValue: value.lowercased()) else { throw .invalidArgument("direction expects right, left, down or up") }
                scrollingDirection = direction
            case "when-empty": whenEmpty = value.isEmpty ? nil : value
            default:
                throw .invalidArgument("unknown workspace setting '\(key)'")
            }
        }
    }

    /// The settings as keys and values of the workspace's table.
    public var entries: [(key: String, value: String)] {
        var result: [(String, String)] = []
        if let name { result.append(("name", name)) }
        if let display { result.append(("display", display.description)) }
        if isDefault { result.append(("default", "true")) }
        if isPersistent { result.append(("persistent", "true")) }
        if let layout { result.append(("layout", layout.rawValue)) }
        if let gaps { result.append(("gaps", gaps.description)) }
        if let margins { result.append(("margins", margins.description)) }
        if let borderWidth { result.append(("border-width", borderWidth.compact)) }
        if let decorations { result.append(("decorations", decorations ? "true" : "false")) }
        if let squareCorners { result.append(("square-corners", squareCorners ? "true" : "false")) }
        if let stackSide { result.append(("stack-side", stackSide.rawValue)) }
        if let scrollingDirection { result.append(("direction", scrollingDirection.rawValue)) }
        if let whenEmpty { result.append(("when-empty", whenEmpty)) }
        return result
    }
}

extension Insets {
    /// Parses CSS-style shorthand: `5`, `5 10`, `5 10 15` or `5 10 15 20`.
    public init?(cssNotation text: String) {
        let values = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
        switch values.count {
        case 1: self.init(all: values[0])
        case 2: self.init(top: values[0], right: values[1], bottom: values[0], left: values[1])
        case 3: self.init(top: values[0], right: values[1], bottom: values[2], left: values[1])
        case 4: self.init(top: values[0], right: values[1], bottom: values[2], left: values[3])
        default: return nil
        }
    }
}
