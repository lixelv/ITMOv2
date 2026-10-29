import MasshCore
import SwiftUI

/// The window: Server List on the left, and to its right either the Terminal or the Inspector (ADR 0007).
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
            // The Terminal stays in the hierarchy under the Inspector so its sessions keep running.
            let showsTerminal = model.windowMode == .terminal
            ZStack {
                WorkspaceView(model: model)
                    .opacity(showsTerminal ? 1 : 0)
                    .allowsHitTesting(showsTerminal)
                    .accessibilityHidden(!showsTerminal)
                if !showsTerminal {
                    InspectorView(model: model)
                        .background(.background)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Connect", systemImage: "terminal") { model.connect() }
                    .help("Open a terminal to the selected Server")
                    .disabled(model.selectedServer == nil)
                Button("Add Server", systemImage: "plus") { model.editor = .add }
                    .help("Add a Server to ~/.ssh/config")
            }
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.windowMode) {
                    ForEach(WindowMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).labelStyle(.iconOnly).help(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
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
            Button("Cancel", role: .cancel) {
                if case .installAgent(let s) = pending { model.declinedAgentInstall.insert(s.name) }
            }
        } message: { pending in
            Text(ConfirmationText(pending).message)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .tint(Geist.blue)
        .task { model.start() }
    }
}

extension WindowMode {
    var title: String {
        switch self {
        case .terminal: String(localized: "Terminal")
        case .inspector: String(localized: "Inspector")
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .inspector: "gauge.with.dots.needle.33percent"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .terminal: "1"
        case .inspector: "2"
        }
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
            title = String(localized: "Delete “\(s.name)”?")
            message = String(localized: "The Host block will be removed from \(s.source.lastPathComponent). A backup, config.massh.bak, is made before writing.")
            action = String(localized: "Delete")
            isDestructive = true
        case .installAgent(let s):
            title = String(localized: "Install the Agent on \(s.name)?")
            message = String(localized: "massh uploads the Agent and opens a terminal tab with the installer. You type the sudo password yourself — massh never sees it. The Agent runs as a systemd service under the massh user and listens on localhost only.")
            action = String(localized: "Install")
            isDestructive = false
        case .updateAgent(let s):
            title = String(localized: "Update the Agent on \(s.name)?")
            message = String(localized: "The installer replaces the binary and restarts the service. You type the sudo password in the terminal tab.")
            action = String(localized: "Update")
            isDestructive = false
        case .uninstallAgent(let s):
            title = String(localized: "Remove the Agent from \(s.name)?")
            message = String(localized: "The massh-agent service, its binary and the massh user will be removed. You type the sudo password in the terminal tab.")
            action = String(localized: "Remove Agent")
            isDestructive = true
        }
    }
}

#Preview("Window") {
    ContentView(model: AppModel(dependencies: .fake()))
        .frame(width: 1200, height: 720)
}
