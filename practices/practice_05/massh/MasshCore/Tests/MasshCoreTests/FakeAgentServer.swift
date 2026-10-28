import Foundation
import Network
import Synchronization
@testable import MasshCore

/// A WebSocket server on 127.0.0.1 that behaves like the Agent: it streams a fixture Snapshot on a timer.
final class FakeAgentServer: Sendable {
    let port: Int
    private let queue = DispatchQueue(label: "fake-agent")
    private let state = Mutex<(listener: NWListener?, connections: [NWConnection], message: Data, timer: DispatchSourceTimer?)>(
        (nil, [], Data(), nil)
    )
    private let interval: DispatchTimeInterval

    init(message: Data, interval: DispatchTimeInterval = .milliseconds(50), port: Int = 0) throws {
        self.interval = interval
        self.port = port == 0 ? try SSHTunnel.freeLocalPort() : port
        let listener = try Self.makeListener(port: self.port)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        state.withLock { $0.message = message; $0.listener = listener }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        ready.wait()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        state.withLock { $0.timer = timer }
    }

    static func makeListener(port: Int) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        return try NWListener(using: params)
    }

    func setMessage(_ data: Data) { state.withLock { $0.message = data } }

    /// Drops every client, like the Agent or the tunnel dying.
    func dropConnections() {
        let conns = state.withLock { s in
            defer { s.connections = [] }
            return s.connections
        }
        conns.forEach { $0.cancel() }
    }

    func stop() {
        dropConnections()
        state.withLock { s in
            s.timer?.cancel()
            s.listener?.cancel()
            s.listener = nil
        }
    }

    deinit { stop() }

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        connection.start(queue: queue)
    }

    private func tick() {
        let (conns, message) = state.withLock { ($0.connections, $0.message) }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "snapshot", metadata: [meta])
        for c in conns where c.state == .ready {
            c.send(content: message, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}

/// Tunnel straight to a local port, with a switch for "Agent present".
final class DirectTunnel: AgentTunnel {
    let port: Mutex<Int>
    let listening: Mutex<Bool>
    let closed = Mutex(0)
    let opens = Mutex(0)

    init(port: Int, agentListening: Bool = true) {
        self.port = Mutex(port)
        self.listening = Mutex(agentListening)
    }

    func open() async throws -> Int {
        opens.withLock { $0 += 1 }
        return port.withLock { $0 }
    }
    func agentListening() async -> Bool { listening.withLock { $0 } }
    func close() async { closed.withLock { $0 += 1 } }
}
