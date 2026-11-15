import Foundation
import Synchronization
import Testing
@testable import MossRuntime

@Suite("Event sink")
struct EventSinkTests {
    struct Event: Sendable {
        var name: String
        var value: Int
    }

    /// Each delivery must take the same path, however many events came before it.
    @Test func deliveryDoesNotGetDeeper() {
        let sink = EventSink<Event>()
        let depths = Mutex<[Int]>([])
        sink.connect { _ in depths.withLock { $0.append(Thread.callStackReturnAddresses.count) } }
        for value in 0..<200 { sink.send(Event(name: "event", value: value)) }
        let recorded = depths.withLock { $0 }
        #expect(recorded.count == 200)
        #expect(recorded.first == recorded.last)
    }

    @Test func disconnectedSinksDropEvents() {
        let sink = EventSink<Event>()
        let count = Mutex(0)
        sink.connect { _ in count.withLock { $0 += 1 } }
        sink.send(Event(name: "a", value: 1))
        sink.disconnect()
        sink.send(Event(name: "b", value: 2))
        #expect(count.withLock { $0 } == 1)
    }
}
