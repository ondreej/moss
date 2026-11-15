public import Foundation

/// File access used by the evaluator, abstracted so configurations can be evaluated in tests.
public protocol ConfigFileSystem: Sendable {
    func read(_ url: URL) throws -> String
    /// Expands `~` and glob patterns in an included path, relative to `directory`.
    func resolve(_ pattern: String, relativeTo directory: URL?) -> [URL]
}

/// The real file system.
public struct LocalFileSystem: ConfigFileSystem {
    public init() {}

    public func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public func resolve(_ pattern: String, relativeTo directory: URL?) -> [URL] {
        let path = ConfigPaths.included(pattern, relativeTo: directory)
        guard ConfigPaths.isPattern(path) else {
            return [URL(fileURLWithPath: path)]
        }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }
}

/// An in-memory file system keyed by absolute path.
public struct MemoryFileSystem: ConfigFileSystem {
    public var files: [String: String]

    public init(_ files: [String: String]) {
        self.files = files
    }

    public func read(_ url: URL) throws -> String {
        guard let text = files[url.path] else { throw CocoaError(.fileNoSuchFile) }
        return text
    }

    public func resolve(_ pattern: String, relativeTo directory: URL?) -> [URL] {
        let path = pattern.hasPrefix("/") || directory == nil ? pattern : directory!.appendingPathComponent(pattern).path
        guard pattern.contains("*") else { return [URL(fileURLWithPath: path)] }
        let prefix = String(path.prefix { $0 != "*" })
        return files.keys.filter { $0.hasPrefix(prefix) }.sorted().map { URL(fileURLWithPath: $0) }
    }
}

/// Standard locations of Moss's files.
public enum ConfigPaths {
    /// The absolute path an `include` names: `~` expanded, relative to `directory`, patterns kept.
    public static func included(_ pattern: String, relativeTo directory: URL?) -> String {
        let path = (pattern as NSString).expandingTildeInPath
        guard !path.hasPrefix("/"), let directory else { return path }
        return directory.appendingPathComponent(path).path
    }

    /// Whether an included path is a pattern such as `themes/*.toml`.
    public static func isPattern(_ path: String) -> Bool {
        path.contains { "*?[".contains($0) }
    }

    /// `$XDG_CONFIG_HOME/moss`, defaulting to `~/.config/moss`.
    public static var directory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("moss", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("moss", isDirectory: true)
    }

    /// The main configuration file, overridable with `MOSS_CONFIG`.
    public static var mainFile: URL {
        if let override = ProcessInfo.processInfo.environment["MOSS_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return directory.appendingPathComponent("moss.toml")
    }
}
