import Testing
import MasshCore
@testable import MasshUI

@MainActor
@Suite("Window modes: Terminal and Inspector")
struct WindowModeTests {
    let server = FakeServerStore.sampleServers[0]

    @Test func connectSwitchesToTerminal() {
        let model = AppModel(dependencies: .fake())
        model.windowMode = .inspector
        model.connect(server)
        #expect(model.windowMode == .terminal)
    }

    @Test func agentOperationSwitchesToTerminal() async {
        let model = AppModel(dependencies: .fake())
        model.windowMode = .inspector
        await model.perform(.installAgent(server))
        #expect(model.windowMode == .terminal)
        #expect(model.tabs.last?.isAgentOperation == true)
    }

    @Test func selectingAnotherServerKeepsTheMode() {
        let model = AppModel(dependencies: .fake())
        model.windowMode = .inspector
        model.selectedServerName = FakeServerStore.sampleServers[1].name
        #expect(model.windowMode == .inspector)
    }
}
