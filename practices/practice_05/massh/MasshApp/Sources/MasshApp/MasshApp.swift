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
    /// MasshCore fakes until the real implementations are wired in; `MASSH_FAKE=1` keeps them for demos.
    static func live() -> Dependencies { .fake() }
}
