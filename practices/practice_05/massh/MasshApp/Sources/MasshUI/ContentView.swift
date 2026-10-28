import MasshCore
import SwiftUI

/// The Xcode-style window: Server List, terminal workspace, inspector.
public struct ContentView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            ServerListView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            WorkspaceView(model: model)
                .inspector(isPresented: $model.isInspectorPresented) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Подключиться", systemImage: "terminal") { model.connect() }
                    .help("Открыть терминал к выбранному Server")
                    .disabled(model.selectedServer == nil)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Добавить Server", systemImage: "plus") { model.editor = .add }
                    .help("Добавить Server в ~/.ssh/config")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Инспектор", systemImage: "sidebar.right") { model.isInspectorPresented.toggle() }
                    .help(model.isInspectorPresented ? "Скрыть инспектор" : "Показать инспектор")
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
        .navigationTitle(model.selectedServerName ?? "massh")
        .sheet(item: $model.editor) { mode in
            ServerEditorView(model: model, mode: mode)
        }
        .confirmationDialog(
            model.confirmation.map(ConfirmationText.init)?.title ?? "",
            isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
            titleVisibility: .visible,
            presenting: model.confirmation
        ) { pending in
            let text = ConfirmationText(pending)
            Button(text.action, role: text.isDestructive ? .destructive : nil) {
                Task { await model.perform(pending) }
            }
            Button("Отмена", role: .cancel) {
                if case .installAgent(let s) = pending { model.declinedAgentInstall.insert(s.name) }
            }
        } message: { pending in
            Text(ConfirmationText(pending).message)
        }
        .alert(
            "Не получилось",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task { model.start() }
    }
}

struct ConfirmationText {
    var title: String
    var message: String
    var action: String
    var isDestructive: Bool

    init(_ pending: PendingConfirmation) {
        switch pending {
        case .deleteServer(let s):
            title = "Удалить «\(s.name)»?"
            message = "Блок Host будет удалён из \(s.source.lastPathComponent). Перед записью делается бэкап config.massh.bak."
            action = "Удалить"
            isDestructive = true
        case .installAgent(let s):
            title = "Установить Agent на \(s.name)?"
            message = "massh загрузит Agent и откроет терминальную вкладку с установщиком. Пароль sudo вы вводите сами — massh его не видит. Agent работает как systemd-сервис от пользователя massh и слушает только localhost."
            action = "Установить"
            isDestructive = false
        case .updateAgent(let s):
            title = "Обновить Agent на \(s.name)?"
            message = "Установщик заменит бинарник и перезапустит сервис. Пароль sudo вводится в терминальной вкладке."
            action = "Обновить"
            isDestructive = false
        case .uninstallAgent(let s):
            title = "Удалить Agent с \(s.name)?"
            message = "Будут удалены сервис massh-agent, бинарник и пользователь massh. Пароль sudo вводится в терминальной вкладке."
            action = "Удалить Agent"
            isDestructive = true
        }
    }
}

#Preview("Window") {
    ContentView(model: AppModel(dependencies: .fake()))
        .frame(width: 1200, height: 720)
}
