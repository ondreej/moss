import AppKit
import MossConfig
import MossCore
import SwiftUI
import UniformTypeIdentifiers

enum ShortcutEditorTarget: Identifiable, Hashable {
    case new
    case existing(ShortcutRow)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let row): row.id
        }
    }
}

/// Everything about a shortcut that can be edited.
struct ShortcutDraft: Equatable {
    enum Kind: String, CaseIterable { case key = "Keyboard", mouse = "Mouse" }

    var kind: Kind = .key
    var usesMainKey = true
    /// Modifiers besides the main key, or all modifiers when it is not used.
    var modifiers: Modifiers = []
    var key: String?
    var button: MouseButton = .left
    var drag: DragAction = .move
    var verb = "run"
    var arguments = ""
    var summary = ""
    var repeats = false
    var onRelease = false
    var passesThrough = false
    var mode: String?

    init() {}

    init(binding: KeyBinding, mainKey: Modifiers) {
        usesMainKey = !mainKey.isEmpty && binding.modifiers.isSuperset(of: mainKey)
        modifiers = usesMainKey ? binding.modifiers.subtracting(mainKey) : binding.modifiers
        mode = binding.mode
        switch binding.trigger {
        case .key(let name): key = name
        case .drag(let mouseButton): kind = .mouse; button = mouseButton
        default: break
        }
        switch binding.command {
        case .drag(let action):
            drag = action
        case .action(let action):
            let text = action.description
            verb = action.verb
            arguments = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        }
        summary = binding.summary ?? ""
        repeats = binding.options.contains(.repeats)
        onRelease = binding.options.contains(.onRelease)
        passesThrough = binding.options.contains(.passesThrough)
    }

    /// The shortcut, or why it cannot be made yet.
    func binding(mainKey: Modifiers) -> Result<KeyBinding, ShortcutDraftError> {
        let held = modifiers.union(usesMainKey ? mainKey : [])
        switch kind {
        case .mouse:
            return .success(KeyBinding(modifiers: held, trigger: .drag(button), command: .drag(drag)))
        case .key:
            guard let key else { return .failure(ShortcutDraftError("Record a shortcut.")) }
            let action: Action
            do {
                action = try Action(parsing: arguments.isEmpty ? verb : "\(verb) \(arguments)")
            } catch {
                return .failure(ShortcutDraftError(error.description))
            }
            var options: KeyBinding.Options = []
            if repeats { options.insert(.repeats) }
            if onRelease { options.insert(.onRelease) }
            if passesThrough { options.insert(.passesThrough) }
            let summary = summary.trimmingCharacters(in: .whitespaces)
            return .success(KeyBinding(modifiers: held, trigger: .key(key), command: .action(action), options: options, summary: summary.isEmpty ? nil : summary, mode: mode))
        }
    }
}

struct ShortcutDraftError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

struct ShortcutEditor: View {
    let target: ShortcutEditorTarget
    @Environment(SettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ShortcutDraft()

    var body: some View {
        let result = draft.binding(mainKey: store.mainKey)
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Shortcut" : "Edit Shortcut")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            Form {
                Section {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(ShortcutDraft.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Start with the main key (\(store.mainKey.symbols))", isOn: $draft.usesMainKey)
                    if draft.kind == .key {
                        LabeledContent("Shortcut") {
                            KeyRecorder(modifiers: recordedModifiers, key: $draft.key)
                        }
                    } else {
                        LabeledContent(draft.usesMainKey ? "Extra modifiers" : "Modifiers") {
                            ModifierPicker(modifiers: $draft.modifiers)
                        }
                        Picker("Drag with", selection: $draft.button) {
                            Text("Left button").tag(MouseButton.left)
                            Text("Right button").tag(MouseButton.right)
                            Text("Middle button").tag(MouseButton.middle)
                        }
                        Picker("To", selection: $draft.drag) {
                            Text("Move the window").tag(DragAction.move)
                            Text("Resize the window").tag(DragAction.resize)
                        }
                    }
                }
                if draft.kind == .key {
                    Section("Action") {
                        Picker("Action", selection: $draft.verb) {
                            ForEach(Action.catalog, id: \.verb) { entry in
                                Text("\(entry.verb) — \(entry.summary)").tag(entry.verb)
                            }
                        }
                        ArgumentField(verb: draft.verb, arguments: $draft.arguments)
                        TextField("Description", text: $draft.summary, prompt: Text("Optional, shown in the palette"))
                    }
                    Section("Behaviour") {
                        Toggle("Repeat while held", isOn: $draft.repeats)
                        Toggle("Run when released", isOn: $draft.onRelease)
                        Toggle("Also send the keys to the app", isOn: $draft.passesThrough)
                    }
                }
                if let conflict = conflict(with: try? result.get()) {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if case .success(let binding) = result {
                    Section("In the configuration file") {
                        Text(preview(of: binding)).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if case .failure(let error) = result {
                    Text(error.message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled((try? result.get()) == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            if case .existing(let row) = target, let binding = row.binding {
                draft = ShortcutDraft(binding: binding, mainKey: store.mainKey)
            } else {
                draft = ShortcutDraft()
            }
        }
    }

    private var isNew: Bool { target == .new }

    /// The recorder works with all modifiers held; the main key is factored out on the way in.
    private var recordedModifiers: Binding<Modifiers> {
        Binding {
            draft.modifiers.union(draft.usesMainKey ? store.mainKey : [])
        } set: { recorded in
            if draft.usesMainKey && recorded.isSuperset(of: store.mainKey) {
                draft.modifiers = recorded.subtracting(store.mainKey)
            } else {
                draft.usesMainKey = false
                draft.modifiers = recorded
            }
        }
    }

    private func preview(of binding: KeyBinding) -> String {
        let table = Declarations.table(for: binding)
        let keys = binding.chord.description(mainKey: store.mainKey)
        return "[\(table.joined(separator: "."))]\n\(TOMLValue.key(keys)) = \(Declarations.value(for: binding).text)"
    }

    private func conflict(with binding: KeyBinding?) -> String? {
        guard let binding else { return nil }
        let clash = store.shortcutRows.first { row in
            if case .existing(let current) = target, current.id == row.id { return false }
            guard let other = row.binding, other.mode == binding.mode else { return false }
            return other.modifiers == binding.modifiers && other.trigger == binding.trigger
        }
        return clash.map { "Replaces “\($0.binding.map { Describe.command($0.command) } ?? $0.keys)”." }
    }

    private func save() {
        guard case .success(let binding) = draft.binding(mainKey: store.mainKey) else { return }
        if case .existing(let row) = target {
            store.saveShortcut(binding, replacing: row)
        } else {
            store.saveShortcut(binding)
        }
        dismiss()
    }
}

/// An input for the action's arguments, suited to the chosen action.
private struct ArgumentField: View {
    let verb: String
    @Binding var arguments: String

    var body: some View {
        switch verb {
        case "focus", "move", "swap", "join-tabs", "preselect":
            DirectionPicker(arguments: $arguments)
        case "run":
            HStack {
                TextField("Command", text: $arguments, prompt: Text("open -a Safari"))
                Button("Choose App…") { chooseApplication() }
            }
        case "workspace", "move-to-workspace", "send-to-workspace", "bring-workspace":
            TextField("Workspace", text: $arguments, prompt: Text("1, mail, next, previous, last or scratchpad"))
        default:
            let entry = Action.catalog.first { $0.verb == verb }
            if let entry, !entry.arguments.isEmpty {
                TextField("Arguments", text: $arguments, prompt: Text(entry.arguments))
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            arguments = "open -a \"\(url.deletingPathExtension().lastPathComponent)\""
        }
    }
}

private struct DirectionPicker: View {
    @Binding var arguments: String

    var body: some View {
        Picker("Direction", selection: $arguments) {
            Label("Left", systemImage: "arrow.left").tag("left")
            Label("Right", systemImage: "arrow.right").tag("right")
            Label("Up", systemImage: "arrow.up").tag("up")
            Label("Down", systemImage: "arrow.down").tag("down")
        }
        .pickerStyle(.segmented)
    }
}
