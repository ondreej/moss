import ApplicationServices
import Darwin
import Foundation

/// Private functions resolved at runtime, so a missing symbol degrades a feature instead of
/// preventing launch. None of them requires System Integrity Protection to be disabled.
enum PrivateAPI {
    private static let applicationServices = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private static func symbol<T>(_ name: String, in library: String, as type: T.Type) -> T? {
        guard let handle = dlopen(library, RTLD_LAZY), let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    /// Maps an accessibility window element to its window server identifier.
    static let getWindow = symbol("_AXUIElementGetWindow", in: applicationServices, as: GetWindow.self)
    static let getProcessForPID = symbol("GetProcessForPID", in: applicationServices, as: GetProcessForPID.self)
    /// Makes a process the active one with a specific window, without raising its other windows.
    static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", in: skyLight, as: SetFrontProcess.self)
    static let postEventRecord = symbol("SLPSPostEventRecordTo", in: skyLight, as: PostEventRecord.self)
    typealias GetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> CGError
    static let getFrontProcess = symbol("_SLPSGetFrontProcess", in: skyLight, as: GetFrontProcess.self)

    typealias MainConnection = @convention(c) () -> Int32
    typealias QueryWindows = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
    typealias CopyQueryWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias AdvanceIterator = @convention(c) (CFTypeRef) -> Bool
    typealias CopyCornerRadii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

    static let mainConnection = symbol("SLSMainConnectionID", in: skyLight, as: MainConnection.self)
    static let queryWindows = symbol("SLSWindowQueryWindows", in: skyLight, as: QueryWindows.self)
    static let copyQueryWindows = symbol("SLSWindowQueryResultCopyWindows", in: skyLight, as: CopyQueryWindows.self)
    static let advanceIterator = symbol("SLSWindowIteratorAdvance", in: skyLight, as: AdvanceIterator.self)
    /// Despite its name, returns a new array the caller owns: one number per corner.
    static let copyCornerRadii = symbol("SLSWindowIteratorGetResolvedCornerRadii", in: skyLight, as: CopyCornerRadii.self)

    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias MoveWindowsToManagedSpace = @convention(c) (Int32, CFArray, UInt64) -> Void

    /// Every display's Spaces, with the one shown.
    static let copyManagedDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", in: skyLight, as: CopyManagedDisplaySpaces.self)
    static let moveWindowsToManagedSpace = symbol("SLSMoveWindowsToManagedSpace", in: skyLight, as: MoveWindowsToManagedSpace.self)

    /// The type of a fullscreen Space in the window server's description of a display's Spaces;
    /// a desktop's is `0`.
    private static let fullscreenSpaceType = 4

    /// Puts one of Moss's own windows on the desktop of the display showing a fullscreen Space.
    /// Returns `false` when no display shows one, or the private functions are unavailable.
    static func moveToDesktop(_ window: CGWindowID) -> Bool {
        guard let mainConnection, let copyManagedDisplaySpaces, let moveWindowsToManagedSpace else { return false }
        let connection = mainConnection()
        guard let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return false }
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any], current["type"] as? Int == fullscreenSpaceType,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let desktop = spaces.first(where: { $0["type"] as? Int == 0 }),
                  let id = (desktop["id64"] as? NSNumber ?? desktop["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
            moveWindowsToManagedSpace(connection, [NSNumber(value: window)] as CFArray, id)
            return true
        }
        return false
    }

    /// The radius of a window's rounded corners, as the window server draws them. Applications
    /// choose it (larger for windows with toolbars), and the accessibility API does not report it.
    static func cornerRadius(of window: CGWindowID) -> Double? {
        guard let mainConnection, let queryWindows, let copyQueryWindows, let advanceIterator, let copyCornerRadii else { return nil }
        let windows = [NSNumber(value: window)] as CFArray
        guard let query = queryWindows(mainConnection(), windows, 0)?.takeRetainedValue(),
              let iterator = copyQueryWindows(query)?.takeRetainedValue(),
              advanceIterator(iterator),
              let radii = copyCornerRadii(iterator)?.takeRetainedValue() as? [Double] else { return nil }
        return radii.max()
    }

    /// How long, in microseconds, Moss holds the front when it passes focus on.
    private static let relayPause: useconds_t = 20_000

    /// Makes `window` the key window of process `pid`, bringing it to the front with `raise`
    /// and otherwise leaving every window where it is in the stacking order.
    /// Returns `false` when the private functions are unavailable.
    static func focus(window: CGWindowID, pid: pid_t, raise: Bool) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        let noWindows: UInt32 = 0x400
        if !raise, isFront(psn) {
            // An active application moves its key window only by raising it. Made active anew,
            // it takes the window it is given where it is, so Moss takes the front for a moment.
            var own = ProcessSerialNumber()
            guard getProcessForPID(getpid(), &own) == noErr else { return false }
            FocusRelay.pass()
            guard setFrontProcess(&own, 0, noWindows) == .success else { return false }
            // The application must have let go before it is made active again.
            usleep(relayPause)
        }
        guard setFrontProcess(&psn, window, raise ? userGenerated : noWindows) == .success else { return false }

        // Synthesise the window server events that make the window key.
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x3A] = 0x10
        withUnsafeBytes(of: window) { bytes in
            for index in 0..<4 { record[0x3C + index] = bytes[index] }
        }
        for index in 0x20..<0x30 { record[index] = 0xFF }
        record[0x08] = 0x01
        _ = postEventRecord(&psn, &record)
        record[0x08] = 0x02
        _ = postEventRecord(&psn, &record)
        return true
    }

    private static func isFront(_ psn: ProcessSerialNumber) -> Bool {
        var front = ProcessSerialNumber()
        guard let getFrontProcess, getFrontProcess(&front) == .success else { return false }
        return front.highLongOfPSN == psn.highLongOfPSN && front.lowLongOfPSN == psn.lowLongOfPSN
    }
}
