import Foundation
import Testing
import MasshCore
@testable import MasshUI

/// Agent operations that report their steps and can fail, standing in for the Server.
private struct SteppingAgent: AgentOperations {
    var failure: AgentOperationError?

    func install(on server: Server, progress: @escaping @Sendable (AgentStep) -> Void) async throws -> TerminalCommand {
        progress(.checking)
        progress(.uploading)
        if let failure { throw failure }
        return TerminalCommand(title: "install", executable: "/usr/bin/true", arguments: [])
    }

    func update(on server: Server, progress: @escaping @Sendable (AgentStep) -> Void) async throws -> TerminalCommand {
        try await install(on: server, progress: progress)
    }

    func uninstall(from server: Server, progress: @escaping @Sendable (AgentStep) -> Void) async throws -> TerminalCommand {
        try await install(on: server, progress: progress)
    }
}

@MainActor
@Suite("Agent install progress in the Server List")
struct AgentActivityTests {
    let server = FakeServerStore.sampleServers[0]

    private func model(_ agent: SteppingAgent = SteppingAgent()) -> AppModel {
        var deps = Dependencies.fake()
        deps.agent = agent
        return AppModel(dependencies: deps)
    }

    @Test func installWaitsForSudoUntilTheInstallerTabEnds() async {
        let model = model()
        await model.perform(.installAgent(server))
        #expect(model.agentActivity[server.name] == .waitingForSudo)

        let tab = try! #require(model.tabs.last)
        model.terminalExited(tab.id, code: 0)
        #expect(model.agentActivity[server.name] == nil)
    }

    @Test func closingTheInstallerTabClearsTheActivity() async {
        let model = model()
        await model.perform(.installAgent(server))
        model.close(try! #require(model.tabs.last).id)
        #expect(model.agentActivity[server.name] == nil)
    }

    @Test func aFailedPreparationStaysOnTheServerRow() async {
        let model = model(SteppingAgent(failure: .noSystemd))
        await model.perform(.installAgent(server))
        #expect(model.agentActivity[server.name] == .failed(AgentOperationError.noSystemd.localizedDescription))
        #expect(model.tabs.isEmpty)
    }
}
