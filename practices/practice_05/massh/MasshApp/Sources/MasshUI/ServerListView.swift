import MasshCore
import SwiftUI

struct ServerListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedServerName) {
            Section("Servers") {
                ForEach(model.servers) { server in
                    ServerRow(server: server, status: model.status(of: server))
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

    var body: some View {
        HStack(spacing: 8) {
            StatusSymbol(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                Text(server.proxyJump.map { String(localized: "\(server.address) via \($0)") } ?? server.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        Button("Show Details", systemImage: "sidebar.right") {
            model.selectedServerName = server.name
            model.isInspectorPresented = true
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
