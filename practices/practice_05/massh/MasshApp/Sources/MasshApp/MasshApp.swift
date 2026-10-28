import AppKit
import MasshCore
import MasshUI
import SwiftUI

@main
struct MasshApp: App {
    @State private var model = AppModel(dependencies: .live())

    var body: some Scene {
        WindowGroup("massh") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            InspectorCommands()
        }
    }
}

extension Dependencies {
    /// MasshCore fakes until the real implementations are wired in. `MASSH_FAKE_SCENARIO` picks a fake
    /// observation scenario for demos: live, noAgent, outdated, drops, noDocker.
    static func live() -> Dependencies {
        let scenario: FakeObservationService.Scenario = switch ProcessInfo.processInfo.environment["MASSH_FAKE_SCENARIO"] {
        case "noAgent": .noAgent
        case "outdated": .outdatedAgent
        case "drops": .dropsConnection(after: 5)
        case "noDocker": .dockerMissing
        default: .live
        }
        return .fake(scenario: scenario)
    }
}
