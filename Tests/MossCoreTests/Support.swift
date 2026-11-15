@testable public import MossCore

/// Settings without gaps or borders, so layout boxes equal window frames.
func flatSettings() -> Settings {
    var settings = Settings()
    settings.layout.gaps = .zero
    settings.layout.margins = .zero
    settings.borders.width = 0
    return settings
}

let area = Rect(x: 0, y: 0, width: 1000, height: 600)

extension WindowID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt32) { self.init(value) }
}

extension MonitorID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt32) { self.init(value) }
}

func properties(_ app: String = "com.example.app", title: String = "") -> WindowProperties {
    WindowProperties(appID: app, appName: app.split(separator: ".").last.map(String.init) ?? app, title: title, pid: 1)
}

/// A world with one 1000×600 monitor (or several, side by side) and the given settings.
func makeWorld(settings: Settings = flatSettings(), monitors: Int = 1) -> World {
    var world = World(settings: settings)
    let displays = (0..<monitors).map { index in
        DisplayDescription(
            id: MonitorID(UInt32(index + 1)),
            name: "Display \(index + 1)",
            frame: Rect(x: Double(index) * 1000, y: 0, width: 1000, height: 600),
            visibleFrame: Rect(x: Double(index) * 1000, y: 0, width: 1000, height: 600),
            isMain: index == 0
        )
    }
    world.updateDisplays(displays)
    return world
}

extension World {
    @discardableResult
    mutating func open(_ id: WindowID, app: String = "com.example.app", title: String = "", frame: Rect = Rect(x: 100, y: 100, width: 400, height: 300), kind: WindowProperties.Kind = .standard) -> WindowID {
        var props = properties(app, title: title)
        props.kind = kind
        addWindow(id, properties: props, frame: frame)
        return id
    }

    mutating func run(_ command: String) throws {
        try perform(Action(parsing: command))
    }

    func frame(_ id: WindowID) -> Rect? { arrangement().frames[id] }
}
