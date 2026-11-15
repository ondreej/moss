import AppKit

/// Opens test windows for the end-to-end suite.
///
///     WindowFactory --tag NAME [--count N] [--kind standard|dialog|fixed] [--size WxH] [--min WxH]
///
/// Window titles are `NAME 1`, `NAME 2`, … so the suite can find them.
struct Options {
    var tag = "window"
    var count = 1
    var kind = "standard"
    var size = NSSize(width: 480, height: 320)
    var minimum: NSSize?

    init(_ arguments: [String]) {
        var iterator = arguments.makeIterator()
        func parseSize(_ text: String?) -> NSSize? {
            guard let parts = text?.split(separator: "x"), parts.count == 2,
                  let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
            return NSSize(width: width, height: height)
        }
        while let argument = iterator.next() {
            switch argument {
            case "--tag": tag = iterator.next() ?? tag
            case "--count": count = Int(iterator.next() ?? "") ?? count
            case "--kind": kind = iterator.next() ?? kind
            case "--size": size = parseSize(iterator.next()) ?? size
            case "--min": minimum = parseSize(iterator.next())
            default: break
            }
        }
    }
}

final class DialogWindow: NSWindow {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

@MainActor
final class Factory: NSObject, NSApplicationDelegate {
    let options = Options(Array(CommandLine.arguments.dropFirst()))
    var windows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 1...max(1, options.count) {
            let window = makeWindow()
            window.title = "\(options.tag) \(index)"
            window.setFrameOrigin(NSPoint(x: 80 + index * 30, y: 120 + index * 30))
            if let minimum = options.minimum { window.contentMinSize = minimum }
            window.contentView = LabelView(text: window.title)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeWindow() -> NSWindow {
        let rect = NSRect(origin: .zero, size: options.size)
        switch options.kind {
        case "dialog":
            return DialogWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        case "fixed":
            return NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        default:
            return NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        }
    }
}

/// A plain label filling the window, so screenshots show which window is which.
final class LabelView: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

let application = NSApplication.shared
let factory = Factory()
application.delegate = factory
application.setActivationPolicy(.regular)
application.run()
