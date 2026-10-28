import Foundation
import MasshCore
import Observation

/// The four MasshCore services the app runs on: real ones in the app, fakes in Previews.
public struct Dependencies: Sendable {
    public var store: any ServerStore
    public var monitor: any ReachabilityMonitor
    public var observation: any ObservationService
    public var agent: any AgentOperations

    public init(store: any ServerStore, monitor: any ReachabilityMonitor, observation: any ObservationService, agent: any AgentOperations) {
        self.store = store
        self.monitor = monitor
        self.observation = observation
        self.agent = agent
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
            agent: FakeAgentOperations()
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

@MainActor
@Observable
public final class AppModel {
    public let dependencies: Dependencies

    public private(set) var servers: [Server] = []
    public private(set) var statuses: [String: Reachability] = [:]
    public var selectedServerName: String? {
        didSet { if oldValue != selectedServerName { inspector.observe(selectedServer) } }
    }
    public var tabs: [TerminalTab] = []
    public var activeTabID: TerminalTab.ID? {
        didSet {
            // Switching tabs shows that tab's Server in the sidebar and the inspector.
            if let tab = tabs.first(where: { $0.id == activeTabID }) { selectedServerName = tab.serverName }
        }
    }
    public var isInspectorPresented = true
    public var editor: EditorMode?
    public var confirmation: PendingConfirmation?
    /// Problems from Agent operations, shown as an alert.
    public var alertMessage: String?
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
        open(TerminalTab(serverName: server.name, command: .ssh(server)))
    }

    public func open(_ tab: TerminalTab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    public func close(_ tabID: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        if activeTabID == tabID { activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id }
    }

    public func terminalExited(_ tabID: TerminalTab.ID, code: Int32?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].state = .exited(code: code)
        let tab = tabs[index]
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
    public func perform(_ confirmation: PendingConfirmation) async {
        do {
            let command: TerminalCommand
            let server: Server
            switch confirmation {
            case .deleteServer(let s):
                await delete(s)
                return
            case .installAgent(let s):
                server = s
                command = try await dependencies.agent.install(on: s)
            case .updateAgent(let s):
                server = s
                command = try await dependencies.agent.update(on: s)
            case .uninstallAgent(let s):
                server = s
                command = try await dependencies.agent.uninstall(from: s)
            }
            var tab = TerminalTab(serverName: server.name, command: command)
            tab.isAgentOperation = true
            open(tab)
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
