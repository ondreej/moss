import Combine
import MossConfig
import MossCore
import SwiftUI

/// The first-launch tour: the Accessibility permission, the main key, and the keys to know.
struct WelcomeView: View {
    let finish: (_ openSettings: Bool) -> Void
    @Environment(SettingsStore.self) private var store
    @Environment(\.services) private var services
    @State private var step: Step

    init(startingAt step: Step = .permission, finish: @escaping (_ openSettings: Bool) -> Void) {
        _step = State(initialValue: step)
        self.finish = finish
    }
    @State private var isTrusted = false

    enum Step: Int, CaseIterable {
        case permission, mainKey, keys
    }

    private let permissionCheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .permission: permission
                case .mainKey: mainKey
                case .keys: keys
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Capsule()
                            .fill(item == step ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.quaternary))
                            .frame(width: item == step ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if step != .permission {
                    Button("Back") { move(by: -1) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(step == .keys ? "Done" : "Continue") {
                    if step == .keys { finish(false) } else { move(by: 1) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 640, height: 560)
        .onAppear { isTrusted = services.isAccessibilityGranted() }
        .onReceive(permissionCheck) { _ in isTrusted = services.isAccessibilityGranted() }
        .animation(.snappy(duration: 0.3), value: step)
        .animation(.snappy, value: isTrusted)
    }

    private func move(by offset: Int) {
        step = Step(rawValue: step.rawValue + offset) ?? step
    }

    // MARK: - Steps

    private var permission: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Moss").font(.largeTitle.weight(.semibold))
            Text("Windows tile themselves as they open, and the keyboard moves them, switches workspaces and changes the layout.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 14) {
                Image(systemName: isTrusted ? "checkmark.circle.fill" : "hand.raised.fill")
                    .font(.title)
                    .foregroundStyle(isTrusted ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isTrusted ? "Accessibility access granted" : "Allow Accessibility access").font(.headline)
                    Text("macOS asks before an app may move other applications’ windows.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isTrusted {
                    Button("Open Settings") { services.requestAccessibility() }
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
            .padding(.top, 8)
        }
    }

    private var mainKey: some View {
        let current = store.mainKey
        return VStack(spacing: 18) {
            Text("Choose your main key").font(.largeTitle.weight(.semibold))
            Text("Every shortcut starts with it. It is written mod in the configuration and can be changed at any time.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            VStack(spacing: 10) {
                choice(.capsLock, "⇪", "Caps Lock", "Recommended. Hold it for shortcuts, tap it to lock capitals as usual. Other apps can use it as a Hyper key.", current)
                choice(.option, "⌥", "Option", "Easy to reach, but it also types special characters on many keyboard layouts.", current)
                choice(.command, "⌘", "Command", "Applications use Command for their own shortcuts, so many combinations are taken.", current)
            }
            .padding(.top, 4)
        }
    }

    private func choice(_ modifiers: Modifiers, _ symbol: String, _ title: String, _ detail: String, _ current: Modifiers) -> some View {
        let selected = current == modifiers
        return Button {
            if let option = OptionRegistry.option("keyboard.main-key") { store.set(option, to: modifiers.description) }
        } label: {
            HStack(spacing: 14) {
                KeyCap(text: symbol)
                    .font(.title2)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.tertiary))
            }
            .padding(14)
            .background(selected ? AnyShapeStyle(Design.accent.opacity(0.1)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.clear), lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var keys: some View {
        VStack(spacing: 18) {
            Text("The keys to know").font(.largeTitle.weight(.semibold))
            Text("Everything else is in the palette, which searches windows, actions and every shortcut.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            VStack(spacing: 0) {
                ForEach(Array(Self.essentials.enumerated()), id: \.offset) { index, essential in
                    if index > 0 { Divider() }
                    HStack {
                        Text(essential.title)
                        Spacer()
                        if let binding = binding(for: essential.action) {
                            KeyComboView(modifiers: binding.modifiers, trigger: binding.trigger)
                        } else {
                            Text("Not bound").foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
            Button("Open Settings") { finish(true) }
                .buttonStyle(.link)
        }
    }

    private static let essentials: [(title: String, action: String)] = [
        ("Open the palette", "palette"),
        ("Move focus left", "focus left"),
        ("Move the window left", "move left"),
        ("Make the window wider", "resize by 40 0"),
        ("Go to workspace 2", "workspace 2"),
        ("Move the window to workspace 2", "move-to-workspace 2"),
        ("Float or tile the window", "float"),
        ("See every workspace", "overview"),
    ]

    /// The shortcut that runs an action in the current configuration.
    private func binding(for text: String) -> KeyBinding? {
        guard let action = try? Action(parsing: text) else { return nil }
        return store.config.bindings.first { $0.mode == nil && $0.action == action }
    }
}
