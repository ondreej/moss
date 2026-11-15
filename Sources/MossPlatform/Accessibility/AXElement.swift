import ApplicationServices
import MossCore

/// A typed view over an accessibility element.
///
/// Accessibility calls are synchronous messages to the target application, so they must
/// only be made from that application's agent thread, never from the engine or main thread.
struct AXElement: Hashable, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) { self.ref = ref }

    static func application(_ pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }

    static let systemWide = AXElement(AXUIElementCreateSystemWide())

    // MARK: - Attributes

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }

    func element(_ attribute: String) -> AXElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXElement] {
        guard let array = value(attribute) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? AXElement(item as! AXUIElement) : nil
        }
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value)
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(ref, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(ref, action as CFString)
    }

    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ref, seconds)
    }

    // MARK: - Common properties

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) ?? false }
    var isFullscreen: Bool { bool("AXFullScreen") ?? false }
    var windows: [AXElement] { elements(kAXWindowsAttribute) }
    var focusedWindow: AXElement? { element(kAXFocusedWindowAttribute) }
    var hasCloseButton: Bool { element(kAXCloseButtonAttribute) != nil }
    var hasFullScreenButton: Bool { element(kAXFullScreenButtonAttribute) != nil }

    var windowID: WindowID? {
        guard let getWindow = PrivateAPI.getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(ref, &id) == .success, id != 0 else { return nil }
        return WindowID(id)
    }

    var position: CGPoint? {
        guard let value = value(kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value = value(kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    var frame: Rect? {
        guard let position, let size else { return nil }
        return Rect(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    @discardableResult
    func setPosition(_ point: Point) -> AXError {
        var value = CGPoint(x: point.x, y: point.y)
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return .failure }
        return set(kAXPositionAttribute, axValue)
    }

    @discardableResult
    func setSize(_ size: Size) -> AXError {
        var value = CGSize(width: size.width, height: size.height)
        guard let axValue = AXValueCreate(.cgSize, &value) else { return .failure }
        return set(kAXSizeAttribute, axValue)
    }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.ref, rhs.ref) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(ref)) }
}
