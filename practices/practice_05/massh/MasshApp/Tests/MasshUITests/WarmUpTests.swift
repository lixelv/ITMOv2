import Foundation
import Synchronization
import Testing
import MasshCore
@testable import MasshUI

@MainActor
@Suite("Terminal warm-up")
struct WarmUpTests {
    @Test func selectingAServerWarmsUpItsTerminalConnection() async throws {
        let warmed = Mutex<[String]>([])
        var deps = Dependencies.fake()
        deps.warmUp = { server in warmed.withLock { $0.append(server.name) } }
        let model = AppModel(dependencies: deps)
        model.start()
        let name = FakeServerStore.sampleServers[1].name
        for _ in 0..<50 where model.servers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        model.selectedServerName = name
        for _ in 0..<50 where warmed.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(warmed.withLock { $0 } == [name])
    }
}
