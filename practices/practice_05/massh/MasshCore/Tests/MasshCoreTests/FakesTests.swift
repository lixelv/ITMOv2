import Foundation
import Testing
import MasshCore

@Suite("Fakes for previews")
struct FakesTests {
    @Test func fakeStoreListsServersAndPublishesEdits() async throws {
        let store = FakeServerStore()
        let initial = try await store.servers()
        #expect(initial.count >= 3)
        #expect(initial.contains { $0.isReadOnly })

        var updates = store.serverListUpdates().makeAsyncIterator()
        #expect(await updates.next() == initial)

        try await store.add(ServerFields(name: "new-box", hostName: "10.0.0.9"))
        let afterAdd = try #require(await updates.next())
        #expect(afterAdd.map(\.name).contains("new-box"))

        await #expect(throws: ServerStoreError.nameTaken("new-box")) {
            try await store.add(ServerFields(name: "new-box"))
        }
        let readOnly = try #require(initial.first { $0.isReadOnly })
        await #expect(throws: ServerStoreError.readOnly(readOnly.name)) {
            try await store.remove(readOnly.name)
        }
    }

    @Test func fakeObservationStreamsLiveSnapshots() async throws {
        let service = FakeObservationService(interval: .milliseconds(5))
        let server = try #require(try await FakeServerStore().servers().first)
        var events = service.observe(server).makeAsyncIterator()
        #expect(await events.next() == .connecting)

        var snapshots: [Snapshot] = []
        while snapshots.count < 3, let event = await events.next() {
            if case .snapshot(let s) = event { snapshots.append(s) }
        }
        #expect(snapshots.count == 3)
        #expect(snapshots[0].time < snapshots[2].time)
        #expect(snapshots.allSatisfy { !$0.processes.isEmpty && !$0.overview.cpu.perCorePercent.isEmpty })
        #expect(snapshots.allSatisfy { (0...100).contains($0.overview.cpu.usagePercent) })
    }

    @Test func fakeObservationScenarios() async throws {
        let server = try #require(try await FakeServerStore().servers().first)

        var noAgent = FakeObservationService(scenario: .noAgent, interval: .milliseconds(5))
            .observe(server).makeAsyncIterator()
        #expect(await noAgent.next() == .connecting)
        #expect(await noAgent.next() == .noAgent)

        var outdated = FakeObservationService(scenario: .outdatedAgent, interval: .milliseconds(5))
            .observe(server).makeAsyncIterator()
        _ = await outdated.next()
        #expect(await outdated.next() == .agentOutdated(installed: "0.0.9", bundled: AgentRelease.bundledVersion))
        if case .snapshot = await outdated.next() {} else { Issue.record("data keeps flowing for an outdated Agent") }

        var flaky = FakeObservationService(scenario: .dropsConnection(after: 2), interval: .milliseconds(5))
            .observe(server).makeAsyncIterator()
        var sawLost = false, sawReconnect = false
        for _ in 0..<10 {
            switch await flaky.next() {
            case .connectionLost: sawLost = true
            case .reconnecting: sawReconnect = sawLost
            default: break
            }
        }
        #expect(sawLost && sawReconnect)
    }

    @Test func manyProcessesForTablePreviews() {
        #expect(FakeSnapshots.make(tick: 0, processCount: 400).processes.count == 400)
    }

    @Test func versionComparison() {
        #expect(AgentRelease.isOutdated("0.0.9", comparedTo: "0.1.0"))
        #expect(!AgentRelease.isOutdated("0.1.0", comparedTo: "0.1.0"))
        #expect(!AgentRelease.isOutdated("0.10.0", comparedTo: "0.9.1"))
        #expect(AgentRelease.isOutdated("1.2", comparedTo: "1.2.1"))
    }
}
