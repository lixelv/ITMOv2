import MasshCore
import SwiftUI

/// The Server menu in the menu bar: the same actions as the context menu, for the selected Server.
public struct ServerCommands: Commands {
    var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(before: .sidebar) {
            ForEach(WindowMode.allCases, id: \.self) { mode in
                Toggle(mode.title, isOn: Binding(get: { model.windowMode == mode }, set: { if $0 { model.windowMode = mode } }))
                    .keyboardShortcut(mode.shortcut, modifiers: .command)
            }
            Divider()
        }
        CommandMenu("Server") {
            let server = model.selectedServer
            Button("Connect") { model.connect() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(server == nil)
            Button("Add Server…") { model.editor = .add }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(server?.isReadOnly == true ? String(localized: "View…") : String(localized: "Edit…")) {
                if let server { model.editor = .edit(server) }
            }
            .disabled(server == nil)
            Button("Delete…") { if let server { model.confirmation = .deleteServer(server) } }
                .disabled(server == nil || server?.isReadOnly == true)
            Divider()
            Button("Install Agent…") { if let server { model.confirmation = .installAgent(server) } }
                .disabled(server == nil)
            Button("Update Agent…") { if let server { model.confirmation = .updateAgent(server) } }
                .disabled(server == nil)
            Button("Remove Agent…") { if let server { model.confirmation = .uninstallAgent(server) } }
                .disabled(server == nil)
        }
    }
}
