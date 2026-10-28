import AppKit
import MasshCore
import MasshUI
import SwiftUI

@main
struct MasshApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
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
            ServerCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Session tasks are not cancelled at quit; make sure no tunnel ssh outlives massh.
        SSHObservationService.terminateAllSessions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Dependencies {
    /// Real MasshCore by default. `MASSH_FAKE=1` runs on fakes (`MASSH_FAKE_SCENARIO`: live, noAgent, outdated,
    /// drops, noDocker); `MASSH_SSH_CONFIG=<file>` uses another ssh config instead of `~/.ssh/config`.
    static func live() -> Dependencies {
        let env = ProcessInfo.processInfo.environment
        guard env["MASSH_FAKE"] == "1" else {
            let binaries = Bundle.main.resourceURL!.appending(path: "agent")
            return .live(agentBinaries: binaries, configFile: env["MASSH_SSH_CONFIG"].map { URL(filePath: $0) })
        }
        let scenario: FakeObservationService.Scenario = switch env["MASSH_FAKE_SCENARIO"] {
        case "noAgent": .noAgent
        case "outdated": .outdatedAgent
        case "drops": .dropsConnection(after: 5)
        case "noDocker": .dockerMissing
        default: .live
        }
        return .fake(scenario: scenario)
    }
}
