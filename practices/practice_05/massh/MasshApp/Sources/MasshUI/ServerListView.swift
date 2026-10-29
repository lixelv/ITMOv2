import MasshCore
import SwiftUI

struct ServerListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedServerName) {
            Section("Servers") {
                ForEach(model.servers) { server in
                    ServerRow(server: server, status: model.status(of: server), activity: model.agentActivity[server.name])
                        .tag(server.name)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { names in
            if let name = names.first, names.count == 1, let server = model.servers.first(where: { $0.name == name }) {
                ServerActions(model: model, server: server)
            }
        } primaryAction: { names in
            // Double click opens a terminal.
            for name in names { if let s = model.servers.first(where: { $0.name == name }) { model.connect(s) } }
        }
        .overlay {
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a Server — it is written to ~/.ssh/config.")
                } actions: {
                    Button("Add Server") { model.editor = .add }
                }
            }
        }
    }
}

struct ServerRow: View {
    var server: Server
    var status: Reachability
    var activity: AgentActivity?

    var body: some View {
        HStack(spacing: 8) {
            StatusSymbol(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                if let activity {
                    AgentActivityLine(activity: activity)
                } else {
                    Text(server.proxyJump.map { String(localized: "\(server.address) via \($0)") } ?? server.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if server.isReadOnly {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("From Include file \(server.source.lastPathComponent): read-only")
                    .accessibilityLabel("Read-only")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.title)
    }
}

/// The step of an Agent operation in place of the address: spinner while massh works, an error when it failed.
struct AgentActivityLine: View {
    var activity: AgentActivity

    var body: some View {
        HStack(spacing: Space.xs) {
            switch activity {
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Geist.red)
            case .waitingForSudo:
                Image(systemName: "key.fill").foregroundStyle(Geist.amber)
            case .checking, .uploading:
                ProgressView().controlSize(.mini)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(help)
        .transition(.opacity)
    }

    private var text: String {
        switch activity {
        case .checking: String(localized: "Checking the Server…")
        case .uploading: String(localized: "Uploading the Agent…")
        case .waitingForSudo: String(localized: "Waiting for sudo…")
        case .failed(let message): message
        }
    }

    private var help: String {
        if case .failed(let message) = activity { return message }
        return text
    }
}

/// Status by shape and color, so it reads without color too.
struct StatusSymbol: View {
    var status: Reachability

    var body: some View {
        Image(systemName: status.symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, status.tint)
            .imageScale(.medium)
            .help(status.explanation)
            .accessibilityLabel(status.title)
            .contentTransition(.symbolEffect(.replace))
    }
}

extension Reachability {
    var title: String {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .offline: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .online: Geist.green
        case .offline: Geist.red
        case .unknown: Geist.gray700
        }
    }

    var explanation: String {
        switch self {
        case .online: String(localized: "Online: the SSH port accepts connections")
        case .offline: String(localized: "Offline: the SSH port does not answer")
        case .unknown: String(localized: "Unknown: the Server is behind a Bastion with no open connection")
        }
    }
}

/// Every action on a Server, shared by the context menu.
struct ServerActions: View {
    var model: AppModel
    var server: Server

    var body: some View {
        Button("Connect", systemImage: "terminal") { model.connect(server) }
        Button("Show Details", systemImage: WindowMode.inspector.symbol) {
            model.selectedServerName = server.name
            model.windowMode = .inspector
        }
        Divider()
        Button(server.isReadOnly ? String(localized: "View…") : String(localized: "Edit…"), systemImage: "pencil") { model.editor = .edit(server) }
        Button("Delete…", systemImage: "trash", role: .destructive) { model.confirmation = .deleteServer(server) }
            .disabled(server.isReadOnly)
        Divider()
        Button("Install Agent…", systemImage: "arrow.down.circle") { model.confirmation = .installAgent(server) }
        Button("Update Agent…", systemImage: "arrow.triangle.2.circlepath") { model.confirmation = .updateAgent(server) }
        Button("Remove Agent…", systemImage: "xmark.bin", role: .destructive) { model.confirmation = .uninstallAgent(server) }
    }
}

#Preview("Server List") {
    let model = AppModel(dependencies: .fake())
    NavigationSplitView {
        ServerListView(model: model).task { model.start() }
    } detail: {
        Text("Workspace")
    }
    .frame(width: 700, height: 420)
}
