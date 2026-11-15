import Synchronization

/// The receiver of a stream of events, connected and disconnected from any thread.
///
/// Platform adapters deliver events from their own threads through a sink. The receiver is
/// stored inside a struct rather than as a bare function value: a function value kept in
/// generic storage is re-wrapped in conversion thunks on every `inout` access, so reading it
/// once per event would make each delivery a little deeper than the last.
public final class EventSink<Event: Sendable>: Sendable {
    private struct Receiver: Sendable {
        let receive: @Sendable (Event) -> Void
    }

    private let receiver = Mutex<Receiver?>(nil)

    public init() {}

    public func connect(_ receive: @escaping @Sendable (Event) -> Void) {
        receiver.withLock { $0 = Receiver(receive: receive) }
    }

    public func disconnect() {
        receiver.withLock { $0 = nil }
    }

    /// Delivers an event, outside the lock, if a receiver is connected.
    public func send(_ event: Event) {
        receiver.withLock { $0 }?.receive(event)
    }
}
