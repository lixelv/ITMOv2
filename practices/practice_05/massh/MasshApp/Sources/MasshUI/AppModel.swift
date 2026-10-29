import Foundation
import MasshCore
import Observation

/// The four MasshCore services the app runs on: real ones in the app, fakes in Previews.
public struct Dependencies: Sendable {
    public var store: any ServerStore
    public var monitor: any ReachabilityMonitor
    public var observation: any ObservationService
    public var agent: any AgentOperations
    /// Command for a plain terminal tab to a Server.
    public var terminal: @Sendable (Server) -> TerminalCommand
    /// Opens the terminal connection to a selected Server ahead of Connect.
    public var warmUp: @Sendable (Server) async -> Void

    public init(
        store: any ServerStore, monitor: any ReachabilityMonitor, observation: any ObservationService,
        agent: any AgentOperations, terminal: @escaping @Sendable (Server) -> TerminalCommand = { .ssh($0) },
        warmUp: @escaping @Sendable (Server) async -> Void = { _ in }
    ) {
        self.store = store
        self.monitor = monitor
        self.observation = observation
        self.agent = agent
        self.terminal = terminal
        self.warmUp = warmUp
    }

    /// The real thing: `~/.ssh/config`, the system `ssh`, and the Agent binaries bundled in `agentBinaries`.
    /// `configFile` replaces `~/.ssh/config` for both massh and the `ssh` it runs (handy for testing).
    public static func live(agentBinaries: URL, configFile: URL? = nil) -> Dependencies {
        let ssh = SSHCommand(configFile: configFile)
        let store = configFile.map { SSHConfigStore(configURL: $0) } ?? SSHConfigStore()
        return Dependencies(
            store: store,
            monitor: SSHReachabilityMonitor(ssh: ssh),
            observation: SSHObservationService(ssh: ssh),
            agent: SSHAgentOperations(ssh: ssh, binaries: agentBinaries),
            terminal: { .ssh($0, using: ssh) },
            warmUp: { await ssh.warmUp($0) }
        )
    }

    public static func fake(
        servers: [Server] = FakeServerStore.sampleServers,
        scenario: FakeObservationService.Scenario = .live,
        processCount: Int = 40
    ) -> Dependencies {
        Dependencies(
            store: FakeServerStore(servers: servers),
            monitor: FakeReachabilityMonitor(),
            observation: FakeObservationService(scenario: scenario, processCount: processCount),
            agent: FakeAgentOperations(),
            // Fake Servers do not exist; their terminal tabs open a local shell instead.
            terminal: { server in TerminalCommand(title: server.name, executable: "/bin/zsh", arguments: ["-f"]) }
        )
    }
}

/// One terminal tab: a process (normally `ssh <server>`) shown in SwiftTerm.
public struct TerminalTab: Identifiable, Hashable {
    public enum State: Hashable {
        case running
        case exited(code: Int32?)
    }

    public let id = UUID()
    public var serverName: String
    public var command: TerminalCommand
    public var state: State = .running
    /// Set for installer tabs: a successful run reconnects the inspector to pick up the new Agent.
    public var isAgentOperation = false
    /// Bumped to start the command again in the same tab.
    public var generation = 0
}

/// Actions waiting for the user's confirmation.
public enum PendingConfirmation: Identifiable, Hashable {
    case deleteServer(Server)
    case installAgent(Server)
    case updateAgent(Server)
    case uninstallAgent(Server)

    public var id: String {
        switch self {
        case .deleteServer(let s): "delete-\(s.name)"
        case .installAgent(let s): "install-\(s.name)"
        case .updateAgent(let s): "update-\(s.name)"
        case .uninstallAgent(let s): "uninstall-\(s.name)"
        }
    }
}

public enum EditorMode: Identifiable, Hashable {
    case add
    case edit(Server)

    public var id: String {
        switch self {
        case .add: "add"
        case .edit(let s): "edit-\(s.name)"
        }
    }
}

/// An Agent operation as the Server List shows it, from the confirmation until its terminal tab ends.
public enum AgentActivity: Hashable, Sendable {
    case checking
    case uploading
    /// The installer tab is open; the user types the sudo password there.
    case waitingForSudo
    case failed(String)
}

/// What the window shows to the right of the Server List (ADR 0007).
public enum WindowMode: Hashable, CaseIterable, Sendable {
    case terminal, inspector
}

@MainActor
@Observable
public final class AppModel {
    public let dependencies: Dependencies

    public private(set) var servers: [Server] = []
    public private(set) var statuses: [String: Reachability] = [:]
    public var selectedServerName: String? {
        didSet {
            guard oldValue != selectedServerName else { return }
            inspector.observe(selectedServer)
            if let server = selectedServer { Task { [warmUp = dependencies.warmUp] in await warmUp(server) } }
        }
    }
    public var tabs: [TerminalTab] = []
    public var activeTabID: TerminalTab.ID? {
        didSet {
            // Switching tabs shows that tab's Server in the sidebar and the inspector.
            if let tab = tabs.first(where: { $0.id == activeTabID }) { selectedServerName = tab.serverName }
        }
    }
    public var windowMode: WindowMode = .terminal
    public var editor: EditorMode?
    public var confirmation: PendingConfirmation?
    /// Problems deleting a Server, shown as an alert. Agent operation errors stay on the Server's row instead.
    public var alertMessage: String?
    /// Agent operations in progress or failed, by Server name.
    public var agentActivity: [String: AgentActivity] = [:]
    /// Servers whose "install Agent" offer the user declined in this run.
    public var declinedAgentInstall: Set<String> = []

    public let inspector: InspectorModel

    private var serverTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        self.inspector = InspectorModel(observation: dependencies.observation)
    }

    public var selectedServer: Server? { servers.first { $0.name == selectedServerName } }

    public func status(of server: Server) -> Reachability { statuses[server.name] ?? .unknown }

    /// Starts following the Server List and reachability; call once when the window appears.
    public func start() {
        guard serverTask == nil else { return }
        serverTask = Task { [weak self, store = dependencies.store] in
            for await list in store.serverListUpdates() {
                self?.apply(list)
            }
        }
    }

    private func apply(_ list: [Server]) {
        let changed = list != servers
        servers = list
        if let name = selectedServerName, !list.contains(where: { $0.name == name }) { selectedServerName = nil }
        // The selection may arrive before its Server does (just added), or the Server may have been edited.
        if inspector.server != selectedServer { inspector.observe(selectedServer) }
        if changed { watchStatuses() }
    }

    private func watchStatuses() {
        statusTask?.cancel()
        let servers = servers
        statusTask = Task { [weak self, monitor = dependencies.monitor] in
            for await map in monitor.statuses(of: servers) {
                self?.statuses = map
            }
        }
    }

    // MARK: Terminal

    public func connect(_ server: Server? = nil) {
        guard let server = server ?? selectedServer else { return }
        open(TerminalTab(serverName: server.name, command: dependencies.terminal(server)))
    }

    public func open(_ tab: TerminalTab) {
        tabs.append(tab)
        activeTabID = tab.id
        windowMode = .terminal
    }

    public func close(_ tabID: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if tabs[index].isAgentOperation { agentActivity[tabs[index].serverName] = nil }
        tabs.remove(at: index)
        if activeTabID == tabID { activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id }
    }

    public func terminalExited(_ tabID: TerminalTab.ID, code: Int32?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].state = .exited(code: code)
        let tab = tabs[index]
        if tab.isAgentOperation { agentActivity[tab.serverName] = nil }
        if tab.isAgentOperation, code == 0, tab.serverName == inspector.server?.name {
            inspector.reconnect()
        }
    }

    public func restart(_ tabID: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].state = .running
        tabs[index].generation += 1
    }

    // MARK: Servers

    public func save(_ fields: ServerFields, mode: EditorMode) async throws {
        switch mode {
        case .add: try await dependencies.store.add(fields)
        case .edit(let server): try await dependencies.store.update(server.name, to: fields)
        }
        selectedServerName = fields.name
    }

    public func delete(_ server: Server) async {
        do {
            try await dependencies.store.remove(server.name)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Agent

    /// Runs a confirmed Agent operation: MasshCore prepares the Server, the installer runs in a new terminal tab.
    /// Each step shows on the Server's row; a failure stays there until the next attempt.
    public func perform(_ confirmation: PendingConfirmation) async {
        let server: Server
        switch confirmation {
        case .deleteServer(let s):
            await delete(s)
            return
        case .installAgent(let s), .updateAgent(let s), .uninstallAgent(let s):
            server = s
        }
        let name = server.name
        agentActivity[name] = .checking
        let progress: @Sendable (AgentStep) -> Void = { step in
            Task { @MainActor [weak self] in
                // A late step must not overwrite the result.
                guard let self, self.agentActivity[name] == .checking || self.agentActivity[name] == .uploading else { return }
                self.agentActivity[name] = step == .checking ? .checking : .uploading
            }
        }
        do {
            let command: TerminalCommand = switch confirmation {
            case .installAgent: try await dependencies.agent.install(on: server, progress: progress)
            case .updateAgent: try await dependencies.agent.update(on: server, progress: progress)
            case .uninstallAgent: try await dependencies.agent.uninstall(from: server, progress: progress)
            case .deleteServer: fatalError("handled above")
            }
            agentActivity[name] = .waitingForSudo
            var tab = TerminalTab(serverName: name, command: command)
            tab.isAgentOperation = true
            open(tab)
        } catch {
            agentActivity[name] = .failed(error.localizedDescription)
        }
    }
}
