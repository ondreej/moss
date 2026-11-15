public import MossCore
import Dispatch

/// Moves windows smoothly to new frames.
///
/// Positions are interpolated along the animation curve while sizes change at once, at the
/// start: resizing makes applications lay themselves out again, which is far too slow to do
/// on every frame. Each tick hands its frames to `step`; the per-application agents coalesce
/// them, so a slow application skips frames rather than falling behind.
@EngineActor
final class FrameAnimator {
    private struct Track {
        var from: Rect
        var to: Rect
        /// Where the window goes once it arrives, such as its parking place after sliding out
        /// of view.
        var then: Rect?
        var start: ContinuousClock.Instant
        var spec: AnimationSpec
    }

    private var tracks: [WindowID: Track] = [:]
    private var timer: (any DispatchSourceTimer)?
    private let step: @EngineActor ([WindowID: Rect]) -> Void

    /// Ticks at 120 Hz, the refresh rate of ProMotion displays.
    private static let interval = DispatchTimeInterval.microseconds(8_333)

    init(step: @escaping @EngineActor ([WindowID: Rect]) -> Void) {
        self.step = step
    }

    var isAnimating: Bool { !tracks.isEmpty }

    func isAnimating(_ window: WindowID) -> Bool { tracks[window] != nil }

    /// Where the window ends up, if it is moving.
    func target(of window: WindowID) -> Rect? { tracks[window].map { $0.then ?? $0.to } }

    /// Where the window is now, if it is moving.
    func frame(of window: WindowID, at now: ContinuousClock.Instant = .now) -> Rect? {
        tracks[window].map { Self.interpolate($0, at: now).frame }
    }

    /// Moves `window` from `from` to `to`, then puts it at `then`, if given, at once.
    func animate(_ window: WindowID, from: Rect, to: Rect, then: Rect? = nil, spec: AnimationSpec) {
        tracks[window] = Track(from: Rect(origin: from.origin, size: to.size), to: to, then: then, start: .now, spec: spec)
        startTimer()
    }

    func cancel(_ window: WindowID) {
        tracks[window] = nil
        if tracks.isEmpty { stopTimer() }
    }

    func cancelAll() {
        tracks.removeAll()
        stopTimer()
    }

    // MARK: - Ticking

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: EngineActor.queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            EngineActor.enqueue { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = ContinuousClock.now
        var frames: [WindowID: Rect] = [:]
        for (window, track) in tracks {
            let (frame, isFinished) = Self.interpolate(track, at: now)
            frames[window] = isFinished ? track.then ?? frame : frame
            if isFinished { tracks[window] = nil }
        }
        if tracks.isEmpty { stopTimer() }
        if !frames.isEmpty { step(frames) }
    }

    private static func interpolate(_ track: Track, at now: ContinuousClock.Instant) -> (frame: Rect, isFinished: Bool) {
        let elapsed = now - track.start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let t = track.spec.duration > 0 ? seconds / track.spec.duration : 1
        guard t < 1 else { return (track.to, true) }
        let progress = track.spec.curve.value(at: t)
        let origin = Point(
            x: track.from.minX + (track.to.minX - track.from.minX) * progress,
            y: track.from.minY + (track.to.minY - track.from.minY) * progress
        )
        return (Rect(origin: origin, size: track.to.size).integral, false)
    }
}
