/// A side effect requested by the model that the runtime has to carry out.
/// Window geometry and focus are not effects: they are state, reconciled from `World`.
public enum Effect: Hashable, Sendable {
    /// Run a shell command.
    case run(String)
    /// Rules queued by `run [rules]` should be dropped after a while if no window used them.
    case expireRunRules(token: Int)
    /// Ask a window to close, as if its close button was pressed.
    case close(WindowID)
    /// Quit the application with this process.
    case quit(pid: Int32)
    /// Send a POSIX signal to a process.
    case signal(pid: Int32, Int32)
    /// Press keys in an application, or in whichever is frontmost when `pid` is `nil`.
    case sendKeys(KeyChord, pid: Int32?)
    /// Move the mouse cursor.
    case warpCursor(Point)
    /// Publish an event that cannot be derived from state changes.
    case emit(Event)
    /// Open one of Moss's own interfaces.
    case show(Action.Surface)
    /// Stop or resume arranging windows.
    case pause(Action.Switch)
    /// Read the configuration file again.
    case reload
    /// Quit Moss.
    case quitMoss
}
