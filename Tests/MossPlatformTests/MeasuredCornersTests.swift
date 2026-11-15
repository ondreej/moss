import MossCore
import Testing
@testable import MossPlatform

@Suite("Measured corners")
struct MeasuredCornersTests {
    let size = Size(width: 600, height: 400)

    @Test func aWindowIsReadOncePerSize() {
        var corners = MeasuredCorners()
        var reads = 0
        let read = { () -> Double? in reads += 1; return 26 }
        #expect(corners.radius(for: size, fallback: 16, read: read) == (26, nil))
        #expect(corners.radius(for: size, fallback: 16, read: read) == (26, nil))
        #expect(reads == 1)
        _ = corners.radius(for: Size(width: 300, height: 400), fallback: 16, read: read)
        #expect(reads == 2)
    }

    @Test func aWindowThatReadsSquareAtFirstIsReadAgain() {
        var corners = MeasuredCorners()
        // Just opened: the window server does not know the window's shape yet.
        let first = corners.radius(for: size, fallback: 16) { 0 }
        #expect(first.radius == 16)
        #expect(first.retryAfter == MeasuredCorners.retryDelays[0])
        // Until the reading is due, the same size keeps the fallback without reading.
        #expect(corners.radius(for: size, fallback: 16) { Issue.record("read too early"); return nil } == (16, nil))
        corners.invalidate()
        #expect(corners.radius(for: size, fallback: 16) { 16 } == (16, nil))
        corners.invalidate()
        #expect(corners.radius(for: size, fallback: 12) { 26 } == (26, nil))
    }

    @Test func windowsThatStaySquareGetSquareBorders() {
        var corners = MeasuredCorners()
        var result = corners.radius(for: size, fallback: 16) { 0 }
        var delays: [Double] = []
        while let retry = result.retryAfter {
            delays.append(retry)
            corners.invalidate()
            result = corners.radius(for: size, fallback: 16) { 0 }
        }
        #expect(delays == MeasuredCorners.retryDelays)
        #expect(result.radius == 0)
    }

    @Test func unknownRadiiFallBackAndAreReadAgain() {
        var corners = MeasuredCorners()
        let result = corners.radius(for: size, fallback: 16) { nil }
        #expect(result.radius == 16)
        #expect(result.retryAfter != nil)
    }

    @Test func resizingStartsTheAttemptsAgain() {
        var corners = MeasuredCorners()
        var result = corners.radius(for: size, fallback: 16) { 0 }
        while result.retryAfter != nil {
            corners.invalidate()
            result = corners.radius(for: size, fallback: 16) { 0 }
        }
        let resized = corners.radius(for: Size(width: 800, height: 400), fallback: 16) { 0 }
        #expect(resized == (16, MeasuredCorners.retryDelays[0]))
    }
}
