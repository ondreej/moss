import AppKit

/// Opens test windows for the end-to-end suite.
///
///     WindowFactory --tag NAME [--count N] [--kind standard|dialog|fixed|video|fullscreen|text|notice]
///                   [--size WxH] [--min WxH] [--level N]
///
/// Window titles are `NAME 1`, `NAME 2`, … so the suite can find them. A `video` window goes
/// fullscreen and back on SIGUSR1, the way browsers show video in fullscreen; a `fullscreen`
/// window goes into macOS fullscreen, in a Space of its own, and back. A `text`
/// window holds a text view with the cursor in it. A `notice` window puts up a notice over
/// everything on SIGUSR1, as keyboard utilities show "Caps Lock On". `--level` raises the
/// windows above others, as launchers do.
struct Options {
    var tag = "window"
    var count = 1
    var kind = "standard"
    var size = NSSize(width: 480, height: 320)
    var minimum: NSSize?
    var level: Int?

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
            case "--level": level = Int(iterator.next() ?? "")
            default: break
            }
        }
    }
}

final class DialogWindow: NSWindow {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

/// A borderless window over the whole screen, like the one browsers put up for a video in
/// fullscreen.
final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }
}

@MainActor
final class Factory: NSObject, NSApplicationDelegate {
    let options = Options(Array(CommandLine.arguments.dropFirst()))
    var windows: [NSWindow] = []
    var cover: NSWindow?
    var notice: NSWindow?
    var signalSource: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 1...max(1, options.count) {
            let window = makeWindow(index)
            window.setFrameOrigin(NSPoint(x: 80 + index * 30, y: 120 + index * 30))
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        if ["video", "fullscreen", "notice"].contains(options.kind) {
            signal(SIGUSR1, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.signalled() } }
            source.resume()
            signalSource = source
        }
        NSApp.activate()
    }

    func signalled() {
        switch options.kind {
        case "video": toggleFullscreen()
        case "fullscreen": windows.first?.toggleFullScreen(nil)
        default: showNotice()
        }
    }

    /// Keyboard utilities show "Caps Lock On" in an untitled window over everything, without
    /// activating themselves, and raise it to its level a moment after it appears.
    func showNotice() {
        notice?.close()
        let notice = DialogWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 212), styleMask: .borderless, backing: .buffered, defer: false)
        notice.isReleasedWhenClosed = false
        notice.contentView = LabelView(text: "Caps Lock On")
        notice.center()
        notice.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { notice.level = .screenSaver }
        self.notice = notice
    }

    /// Browsers show a video in fullscreen without a Space of its own by closing the window
    /// and covering the screen with another; leaving, they close that and open a new window.
    func toggleFullscreen() {
        if let cover {
            let window = makeWindow(1)
            cover.close()
            self.cover = nil
            window.makeKeyAndOrderFront(nil)
            windows = [window]
        } else if let window = windows.first, let screen = window.screen ?? NSScreen.main {
            let cover = CoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.setFrame(screen.frame, display: true)
            cover.contentView = LabelView(text: "\(options.tag) fullscreen")
            // Closed first, so the window is reported gone before the cover is reported focused.
            window.close()
            windows = []
            cover.makeKeyAndOrderFront(nil)
            self.cover = cover
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { options.kind != "video" }

    private func makeWindow(_ index: Int) -> NSWindow {
        let rect = NSRect(origin: .zero, size: options.size)
        let window = switch options.kind {
        case "dialog":
            DialogWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        case "fixed":
            NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        default:
            NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.title = "\(options.tag) \(index)"
        if let minimum = options.minimum { window.contentMinSize = minimum }
        if let level = options.level { window.level = NSWindow.Level(rawValue: level) }
        if options.kind == "text" {
            let text = NSTextView(frame: rect)
            text.string = window.title
            window.contentView = text
            window.initialFirstResponder = text
        } else {
            window.contentView = LabelView(text: window.title)
        }
        return window
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
