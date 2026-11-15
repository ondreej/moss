import MossConfig
import MossCore
import MossIPC
import Foundation

/// `moss`: control a running Moss, or check a configuration file without one.
struct Invocation {
    var json = false
    var words: [String] = []

    enum Failure: Error {
        case usage(String)
    }

    static func parse(_ arguments: [String]) throws(Failure) -> Invocation {
        var result = Invocation()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json":
                result.json = true
            case "-h", "--help":
                result.words = ["help"]
                return result
            default:
                result.words.append(argument)
                while let rest = iterator.next() {
                    if rest == "--json" { result.json = true } else { result.words.append(rest) }
                }
            }
        }
        return result
    }
}

enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    case notRunning = 3
}

/// A first column of help text; text too long for it gets a line of its own.
func column(_ text: String) -> String {
    let width = 46
    if text.count >= width { return "  " + text + "\n" + String(repeating: " ", count: width + 2) }
    return "  " + text.padding(toLength: width, withPad: " ", startingAt: 0)
}

let help = """
Usage: moss [--json] <action or request>

Run an action, such as:
  moss focus left
  moss move-to-workspace 3
  moss run open -a Safari
'moss actions' lists every action.

Ask the running window manager:
\(ControlCommand.catalog.map { column($0.usage) + $0.summary }.joined(separator: "\n"))
\(column("events"))Print events as they happen, one JSON object per line

Without a running window manager:
\(column("check [FILE]"))Check a configuration file for problems
\(column("actions [--markdown]"))List every action
\(column("options [FILTER] [--markdown]"))List the configuration options and their defaults
\(column("init"))Write the default configuration if there is none
\(column("config-path"))Print the configuration file's path

Options:
\(column("--json"))Answer in JSON
\(column("-h, --help"))Show this help
"""

func write(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data(text.utf8))
}

func send(_ request: String) -> ExitCode {
    do {
        let response = try IPCClient().send(request)
        write(response.hasSuffix("\n") || response.isEmpty ? response : response + "\n")
        return response.hasPrefix("error:") ? .failure : .success
    } catch {
        return report(error)
    }
}

func report(_ error: any Error) -> ExitCode {
    if let error = error as? SocketError, error.isConnectionRefused {
        write("moss: Moss is not running\n", to: .standardError)
        return .notRunning
    }
    write("moss: \(error)\n", to: .standardError)
    return .failure
}

func streamEvents() async -> ExitCode {
    do {
        for try await line in IPCClient().events() {
            write(line + "\n")
        }
        return .success
    } catch {
        return report(error)
    }
}

func check(_ path: String?) -> ExitCode {
    let url = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? ConfigPaths.mainFile
    let config = ConfigEvaluator().evaluate(fileAt: url)
    for diagnostic in config.diagnostics { write(diagnostic.description + "\n") }
    let errors = config.errors.count
    write(errors == 0 ? "\(url.path): no problems\n" : "\(url.path): \(errors) problem\(errors == 1 ? "" : "s")\n")
    return errors == 0 ? .success : .failure
}

func listActions(markdown: Bool) -> ExitCode {
    let groups: [(title: String, layout: LayoutKind?)] = [("", nil), ("BSP layout", .bsp), ("Stack layout", .stack), ("Scrolling layout", .scrolling)]
    for (title, layout) in groups {
        let entries = Action.catalog.filter { $0.layout == layout }
        if markdown {
            if !title.isEmpty { write("\n**\(title)**\n\n") }
            write("| Action | Arguments | What it does |\n| --- | --- | --- |\n")
            for entry in entries {
                let arguments = entry.arguments.isEmpty ? "" : "`\(entry.arguments.replacing("|", with: "\\|"))`"
                write("| `\(entry.verb)` | \(arguments) | \(entry.summary) |\n")
            }
        } else {
            if !title.isEmpty { write("\n\(title):\n") }
            for entry in entries {
                write(column("\(entry.verb) \(entry.arguments)") + entry.summary + "\n")
            }
        }
    }
    return .success
}

func listOptions(matching filter: String?, markdown: Bool) -> ExitCode {
    let options = OptionRegistry.all.filter { option in filter.map { option.path.contains($0.lowercased()) } ?? true }
    guard markdown else {
        for option in options { write("\(option.path) = \(option.tomlValue(fromText: option.defaultValue).text)\n    \(option.summary)\n") }
        return .success
    }
    for (category, members) in OptionRegistry.categories {
        let shown = members.filter { option in options.contains { $0.path == option.path } }
        guard !shown.isEmpty else { continue }
        write("\n### `[\(category)]`\n\n| Option | Type | Default | Description |\n| --- | --- | --- | --- |\n")
        for option in shown {
            let defaultValue = option.tomlValue(fromText: option.defaultValue).text
            write("| `\(option.name)` | \(typeDescription(option.type)) | `\(defaultValue)` | \(option.summary) |\n")
        }
    }
    return .success
}

func typeDescription(_ type: OptionType) -> String {
    switch type {
    case .bool: "true or false"
    case .integer(let range): "whole number" + (range.map { " (\($0.lowerBound)–\($0.upperBound))" } ?? "")
    case .number(let range): "number" + (range.map { " (\(trim($0.lowerBound))–\(trim($0.upperBound)))" } ?? "")
    case .choice(let choices): choices.map { "`\"\($0.value)\"`" }.joined(separator: ", ")
    case .insets(let range): "number (\(trim(range.lowerBound))–\(trim(range.upperBound))), or up to four"
    case .color: "color"
    case .string: "text"
    case .numbers: "list of numbers"
    case .modifiers: "modifier keys"
    }
}

func trim(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

func run() async -> ExitCode {
    let command: Invocation
    do {
        command = try Invocation.parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        if case .usage(let message) = error { write("moss: \(message)\n", to: .standardError) }
        return .usage
    }

    guard let name = command.words.first?.lowercased() else {
        write(help + "\n")
        return .usage
    }
    let arguments = Array(command.words.dropFirst())

    switch name {
    case "help":
        write(help + "\n")
        return .success
    case "events":
        return await streamEvents()
    case "check":
        return check(arguments.first)
    case "actions":
        return listActions(markdown: arguments.contains("--markdown"))
    case "options":
        return listOptions(matching: arguments.first { !$0.hasPrefix("--") }, markdown: arguments.contains("--markdown"))
    case "init":
        let store = ConfigPaths.mainFile
        if FileManager.default.fileExists(atPath: store.path) {
            write("\(store.path) already exists\n")
            return .success
        }
        do {
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DefaultConfiguration.text.write(to: store, atomically: true, encoding: .utf8)
            write("wrote \(store.path)\n")
            return .success
        } catch {
            write("moss: \(error)\n", to: .standardError)
            return .failure
        }
    case "config-path":
        write(ConfigPaths.mainFile.path + "\n")
        return .success
    default:
        let text = command.words.joined(separator: " ")
        do {
            let parsed = try ControlCommand(parsing: text)
            if case .action(let action) = parsed {
                // Check the action here, so mistakes are reported even when Moss is not running.
                do {
                    _ = try Action(parsing: action)
                } catch {
                    write("moss: \(error)\nRun 'moss help' for the requests, or 'moss actions' for the actions.\n", to: .standardError)
                    return .usage
                }
            }
            return send(ControlRequest(json: command.json, command: parsed).wireText)
        } catch {
            write("moss: \(error)\n", to: .standardError)
            return .usage
        }
    }
}

exit(await run().rawValue)
