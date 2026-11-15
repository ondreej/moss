public import MossConfig
public import Foundation
import CoreServices
import Synchronization

/// Loads the configuration file, creating it on first launch, and watches it for changes.
public final class ConfigurationStore: Sendable {
    public let mainFile: URL
    private let evaluator: ConfigEvaluator
    private let watcher = Mutex<FileWatcher?>(nil)

    public init(mainFile: URL = ConfigPaths.mainFile, evaluator: ConfigEvaluator = ConfigEvaluator()) {
        self.mainFile = mainFile
        self.evaluator = evaluator
    }

    /// Writes the default configuration if no configuration file exists yet.
    public func createDefaultIfMissing() throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: mainFile.path) else { return }
        try manager.createDirectory(at: mainFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DefaultConfiguration.text.write(to: mainFile, atomically: true, encoding: .utf8)
    }

    /// Evaluates the configuration. `overrides` are option values set at runtime with
    /// `moss set`, applied over the file without changing it.
    public func load(overrides: [(option: OptionDescriptor, value: String)] = []) -> EvaluatedConfig {
        guard !overrides.isEmpty else { return evaluator.evaluate(fileAt: mainFile) }
        var document = TOMLDocument(text: (try? evaluator.fileSystem.read(mainFile)) ?? "")
        for (option, value) in overrides {
            document.setValue(option.tomlValue(fromText: value), at: option.keyPath)
        }
        return evaluator.evaluate(document, at: mainFile)
    }

    /// Calls `onChange` (debounced) whenever one of `files` or the main file changes on disk, or
    /// a file matching one of `patterns`. Files are watched even while missing, so recreating
    /// them is noticed.
    public func watch(_ files: [URL], patterns: [String] = [], onChange: @escaping @Sendable () -> Void) {
        let files = files + [mainFile]
        let paths = Set(files.map(\.path) + files.compactMap(Self.realPath))
        let patterns = Set(patterns + patterns.compactMap { Self.realPath(of: URL(fileURLWithPath: $0)) })
        watcher.withLock { current in
            current?.stop()
            current = FileWatcher(paths: paths, patterns: patterns, onChange: onChange)
        }
    }

    /// The path FSEvents reports for `file`: symbolic links resolved, `/private` included, and
    /// for a missing file, its directory's.
    private static func realPath(of file: URL) -> String? {
        if let path = realpath(file.path, nil) {
            defer { free(path) }
            return String(cString: path)
        }
        guard let directory = realpath(file.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(directory) }
        return String(cString: directory) + "/" + file.lastPathComponent
    }

    public func stopWatching() {
        watcher.withLock { current in
            current?.stop()
            current = nil
        }
    }
}

/// Watches individual files, and files matching patterns, through FSEvents on their
/// directories, which also catches editors that save by replacing the file.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let paths: Set<String>
    private let patterns: Set<String>
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "moss.config-watcher", qos: .utility)

    init(paths: Set<String>, patterns: Set<String> = [], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.patterns = patterns
        self.onChange = onChange
        let directories = Array(Set((paths.union(patterns)).map { ($0 as NSString).deletingLastPathComponent }.filter { !ConfigPaths.isPattern($0) }))
        guard !directories.isEmpty else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            if changed.prefix(count).contains(where: watcher.isWatching) {
                watcher.onChange()
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, directories as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func isWatching(_ path: String) -> Bool {
        paths.contains(path) || patterns.contains { fnmatch($0, path, 0) == 0 }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
