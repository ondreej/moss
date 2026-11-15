public import os

/// Loggers for the unified logging system. Inspect them with
/// `log stream --level debug --predicate 'subsystem == "app.moss"'`.
public enum Log {
    public static let subsystem = "app.moss"

    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let platform = Logger(subsystem: subsystem, category: "platform")
    public static let input = Logger(subsystem: subsystem, category: "input")
    public static let config = Logger(subsystem: subsystem, category: "config")
}
