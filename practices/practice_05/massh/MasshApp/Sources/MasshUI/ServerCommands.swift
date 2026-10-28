import MasshCore
import SwiftUI

/// The Server menu in the menu bar: the same actions as the context menu, for the selected Server.
public struct ServerCommands: Commands {
    var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandMenu("Server") {
            let server = model.selectedServer
            Button("Подключиться") { model.connect() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(server == nil)
            Button("Добавить Server…") { model.editor = .add }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(server?.isReadOnly == true ? "Посмотреть…" : "Изменить…") {
                if let server { model.editor = .edit(server) }
            }
            .disabled(server == nil)
            Button("Удалить…") { if let server { model.confirmation = .deleteServer(server) } }
                .disabled(server == nil || server?.isReadOnly == true)
            Divider()
            Button("Установить Agent…") { if let server { model.confirmation = .installAgent(server) } }
                .disabled(server == nil)
            Button("Обновить Agent…") { if let server { model.confirmation = .updateAgent(server) } }
                .disabled(server == nil)
            Button("Удалить Agent…") { if let server { model.confirmation = .uninstallAgent(server) } }
                .disabled(server == nil)
        }
    }
}
