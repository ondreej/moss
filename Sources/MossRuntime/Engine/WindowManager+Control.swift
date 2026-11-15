import MossCore
import MossConfig
import MossIPC
import Foundation
import os

/// Requests from the control socket.
extension WindowManager {
    /// Answers a request line from the control socket.
    public func respond(to line: String) -> String {
        do throws(ControlRequestError) {
            return respond(to: try ControlRequest(parsing: line))
        } catch {
            return "error: \(error)\n"
        }
    }

    func respond(to request: ControlRequest) -> String {
        switch request.command {
        case .action(let text):
            do {
                let action = try Action(parsing: text)
                try perform(action)
                if action == .reload {
                    let errors = configuration.errors.count
                    return errors == 0 ? "ok\n" : "ok, with \(errors) problem\(errors == 1 ? "" : "s") in the configuration\n"
                }
                return "ok\n"
            } catch {
                return "error: \(error)\n"
            }
        case .set(let path, let value):
            guard let option = OptionRegistry.option(path) else {
                return "error: \(ConfigError.unknownOption(path, suggestion: OptionRegistry.suggestion(for: path)))\n"
            }
            if let problem = option.validate(value) { return "error: \(option.path): \(problem)\n" }
            optionOverrides.removeAll { $0.option.path == option.path }
            optionOverrides.append((option, value))
            let before = world
            applyConfiguration(store.load(overrides: optionOverrides))
            commit(from: before)
            return "ok\n"
        case .notify(let notice):
            post(notice)
            return "ok\n"
        case .dismiss:
            dismissNotices(oldest: nil)
            return "ok\n"
        case .error(let message, let color):
            setError(ErrorBar(lines: message.components(separatedBy: "\n"), color: color))
            return "ok\n"
        case .clearError:
            setError(nil)
            return "ok\n"
        case .windows, .workspaces, .displays, .focused, .shortcuts, .status, .version, .get:
            return QueryResponder.respond(to: request.command, json: request.json, context: queryContext())
        }
    }

    func queryContext() -> QueryContext {
        let options = OptionRegistry.all.map { option in
            OptionState(
                path: option.path,
                value: option.value(in: world.settings),
                defaultValue: option.defaultValue,
                type: option.typeName,
                isSet: configuration.origins[option.path] != nil || optionOverrides.contains { $0.option.path == option.path }
            )
        }
        return QueryContext(
            world: world,
            bindings: configuration.bindings,
            configurationErrors: configuration.diagnostics.filter { $0.severity == .error }.map(\.description),
            options: options,
            version: MossVersion.current,
            accessibilityGranted: windowSystem.isTrusted,
            configFile: store.mainFile.path,
            socketDirectory: SocketPaths.standard.directory.path,
            isPaused: isPaused
        )
    }
}

extension OptionDescriptor {
    var typeName: String {
        switch type {
        case .bool: "boolean"
        case .integer: "integer"
        case .number: "number"
        case .choice: "choice"
        case .insets: "spacing"
        case .color: "color"
        case .string: "text"
        case .numbers: "numbers"
        case .modifiers: "modifiers"
        }
    }
}
