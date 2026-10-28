import Foundation
import Testing
@testable import MasshCore

private let fastTiming = SSHObservationService.Timing(
    staleAfter: .milliseconds(500), agentRecheck: .milliseconds(100), reconnectDelays: [.milliseconds(50)]
)

private func service(_ tunnel: DirectTunnel, bundled: String = "0.1.0") -> SSHObservationService {
    SSHObservationService(bundledVersion: bundled, timing: fastTiming) { _ in tunnel }
}

private let box = server("box")

/// Next events until `match` returns true, with an overall time limit.
private func events(
    _ it: inout AsyncStream<ObservationEvent>.Iterator, until match: (ObservationEvent) -> Bool
) async -> [ObservationEvent] {
    var seen: [ObservationEvent] = []
    while seen.count < 200, let e = await it.next() {
        seen.append(e)
        if match(e) { break }
    }
    return seen
}

private func isSnapshot(_ e: ObservationEvent) -> Bool {
    if case .snapshot = e { true } else { false }
}

@Suite("Observation session")
struct ObservationSessionTests {
    @Test func streamsSnapshots() async throws {
        let agent = try FakeAgentServer(message: try contractFixture("normal.json"))
        defer { agent.stop() }
        var it = service(DirectTunnel(port: agent.port)).observe(box).makeAsyncIterator()

        #expect(await it.next() == .connecting)
        var snapshots = 0
        for _ in 0..<3 where isSnapshot(await it.next() ?? .connecting) { snapshots += 1 }
        #expect(snapshots == 3)
    }

    @Test func noAgentOnServer() async throws {
        let agent = try FakeAgentServer(message: try contractFixture("normal.json"))
        defer { agent.stop() }
        let tunnel = DirectTunnel(port: agent.port, agentListening: false)
        var it = service(tunnel).observe(box).makeAsyncIterator()
        #expect(await it.next() == .connecting)
        #expect(await it.next() == .noAgent)

        // Installed later: the session picks it up by itself.
        tunnel.listening.withLock { $0 = true }
        #expect(await events(&it, until: isSnapshot).last.map(isSnapshot) == true)
    }

    @Test func outdatedAgentIsReportedAndDataKeepsFlowing() async throws {
        let agent = try FakeAgentServer(message: try contractFixture("normal.json")) // agentVersion 0.1.0
        defer { agent.stop() }
        var it = service(DirectTunnel(port: agent.port), bundled: "0.2.0").observe(box).makeAsyncIterator()
        #expect(await it.next() == .connecting)
        #expect(await it.next() == .agentOutdated(installed: "0.1.0", bundled: "0.2.0"))
        #expect(isSnapshot(await it.next()!))
        #expect(isSnapshot(await it.next()!))
    }

    @Test func lostConnectionReconnectsAutomatically() async throws {
        let agent = try FakeAgentServer(message: try contractFixture("normal.json"))
        defer { agent.stop() }
        let tunnel = DirectTunnel(port: agent.port)
        var it = service(tunnel).observe(box).makeAsyncIterator()
        _ = await events(&it, until: isSnapshot)

        agent.dropConnections()
        let afterDrop = await events(&it) { if case .reconnecting = $0 { true } else { false } }
        #expect(afterDrop.contains { if case .connectionLost = $0 { true } else { false } })
        #expect(await events(&it, until: isSnapshot).last.map(isSnapshot) == true)
        #expect(tunnel.opens.withLock { $0 } >= 2)
    }

    @Test func silentAgentCountsAsLost() async throws {
        let agent = try FakeAgentServer(message: try contractFixture("normal.json"), interval: .seconds(60))
        defer { agent.stop() }
        var it = service(DirectTunnel(port: agent.port)).observe(box).makeAsyncIterator()
        let start = ContinuousClock.now
        let seen = await events(&it) { if case .connectionLost = $0 { true } else { false } }
        #expect(seen.first == .connecting)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func newerFormatIsReportedNotCrashed() async throws {
        let agent = try FakeAgentServer(message: try contractFixture("future.json"))
        defer { agent.stop() }
        var it = service(DirectTunnel(port: agent.port)).observe(box).makeAsyncIterator()
        #expect(await it.next() == .connecting)
        #expect(await it.next() == .unsupportedFormat(version: 99))
    }

    @Test func cancellingClosesTheTunnel() async throws {
        let agent = try FakeAgentServer(message: try contractFixture("normal.json"))
        defer { agent.stop() }
        let tunnel = DirectTunnel(port: agent.port)
        let task = Task {
            for await event in service(tunnel).observe(box) where isSnapshot(event) { break }
        }
        await task.value
        for _ in 0..<50 where tunnel.closed.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(tunnel.closed.withLock { $0 } == 1)
    }
}
