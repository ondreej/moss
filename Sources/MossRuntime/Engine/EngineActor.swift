import Dispatch

/// The actor all window-management state lives on.
///
/// It runs on a dedicated serial queue at user-interactive priority, so the window
/// manager never competes with the main thread (used by the settings window) and
/// never blocks on applications: all accessibility calls happen on per-application
/// threads in the platform layer.
@globalActor
public actor EngineActor {
    public static let shared = EngineActor()

    static let queue = DispatchSerialQueue(label: "moss.engine", qos: .userInteractive)

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.queue.asUnownedSerialExecutor()
    }

    /// Runs `body` on the engine. Unlike `Task { @EngineActor in … }`, calls made from the
    /// same thread run in the order they were made, which keeps platform events ordered.
    public nonisolated static func enqueue(_ body: @escaping @Sendable @EngineActor () -> Void) {
        queue.async {
            shared.preconditionIsolated()
            // This is the actor's executor, so running the isolated closure is safe.
            let run = unsafeBitCast(body, to: (@Sendable () -> Void).self)
            run()
        }
    }
}
