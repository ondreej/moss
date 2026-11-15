public import MossIPC
import Foundation
public import Observation

/// What the running window manager is doing, kept up to date through its event socket.
@MainActor
@Observable
public final class LiveState {
    public private(set) var isConnected = false
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var workspaces: [WorkspaceInfo] = []
    public private(set) var windows: [WindowInfo] = []
    public private(set) var focusedWindow: WindowInfo?
    public private(set) var status: StatusInfo?

    /// The focused workspace, as written in actions.
    public var focusedWorkspace: String? { workspaces.first(where: \.isFocused)?.workspace }

    /// Whether tiling is paused, leaving windows where they are.
    public var isPaused: Bool { status?.isPaused ?? false }

    /// Called on the main actor after every update.
    @ObservationIgnored public var onUpdate: (() -> Void)?

    @ObservationIgnored private let client: IPCClient
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(client: IPCClient = IPCClient()) {
        self.client = client
    }

    /// Starts following the window manager, reconnecting whenever it restarts.
    public func start() {
        guard listener == nil else { return }
        listener = Task { [weak self, client] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    for try await _ in client.events() {
                        self?.scheduleRefresh()
                    }
                } catch {}
                self?.isConnected = false
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Coalesces bursts of events into one refresh.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            await self?.refresh()
            self?.refreshTask = nil
        }
    }

    public func refresh() async {
        let client = client
        let snapshot = await Task.detached { () -> Snapshot? in
            do {
                return Snapshot(
                    displays: try client.query(.displays),
                    workspaces: try client.query(.workspaces),
                    windows: try client.query(.windows),
                    focusedWindow: try? client.query(.focused),
                    status: try? client.query(.status)
                )
            } catch {
                return nil
            }
        }.value

        guard let snapshot else {
            isConnected = false
            return
        }
        apply(snapshot)
    }

    func apply(_ snapshot: Snapshot) {
        isConnected = true
        displays = snapshot.displays
        workspaces = snapshot.workspaces
        windows = snapshot.windows
        focusedWindow = snapshot.focusedWindow
        status = snapshot.status
        onUpdate?()
    }

    /// Runs an action, e.g. `workspace 3`.
    @discardableResult
    public func perform(_ action: String) async -> String {
        await send(action)
    }

    @discardableResult
    public func send(_ request: String) async -> String {
        let client = client
        let response = await Task.detached { (try? client.send(request)) ?? "error: Moss is not running" }.value
        scheduleRefresh()
        return response
    }

    struct Snapshot: Sendable {
        var displays: [DisplayInfo]
        var workspaces: [WorkspaceInfo]
        var windows: [WindowInfo]
        var focusedWindow: WindowInfo?
        var status: StatusInfo?
    }
}
