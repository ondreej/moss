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
    /// Brings a process to the front with a specific window, without raising its other windows.
    static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", in: skyLight, as: SetFrontProcess.self)
    static let postEventRecord = symbol("SLPSPostEventRecordTo", in: skyLight, as: PostEventRecord.self)

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

    /// Makes `window` the key window of process `pid` and brings it to the front.
    /// Returns `false` when the private functions are unavailable.
    static func focus(window: CGWindowID, pid: pid_t) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFrontProcess(&psn, window, userGenerated) == .success else { return false }

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
}
