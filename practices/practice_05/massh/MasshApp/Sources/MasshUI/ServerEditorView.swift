import MasshCore
import SwiftUI

/// Add or edit the six fields of a Server. Servers from Include files open read-only.
struct ServerEditorView: View {
    var model: AppModel
    var mode: EditorMode
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var proxyJump = ""
    @State private var error: String?
    @State private var saving = false
    @State private var pickingKey = false

    private var server: Server? {
        if case .edit(let s) = mode { s } else { nil }
    }

    private var readOnly: Bool { server?.isReadOnly ?? false }

    private var portIsValid: Bool { port.isEmpty || (Int(port).map { (1...65535).contains($0) } ?? false) }

    private var canSave: Bool { !readOnly && !saving && !name.trimmingCharacters(in: .whitespaces).isEmpty && portIsValid }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("web-1"))
                    TextField("HostName", text: $hostName, prompt: Text("203.0.113.10 or host.example.com"))
                    TextField("User", text: $user, prompt: Text(NSUserName()))
                    TextField("Port", text: $port, prompt: Text("22"))
                    if !portIsValid {
                        Text("The port is a number from 1 to 65535").font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        TextField("IdentityFile", text: $identityFile, prompt: Text("~/.ssh/id_ed25519"))
                        Button("Choose…") { pickingKey = true }
                            .disabled(readOnly)
                    }
                    Picker("ProxyJump", selection: $proxyJump) {
                        Text("None").tag("")
                        ForEach(model.servers.filter { $0.name != server?.name }) { s in
                            Text(s.name).tag(s.name)
                        }
                        if !proxyJump.isEmpty, !model.servers.contains(where: { $0.name == proxyJump }) {
                            Text(proxyJump).tag(proxyJump)
                        }
                    }
                } header: {
                    Text(title)
                } footer: {
                    footer
                }
            }
            .formStyle(.grouped)
            .disabled(readOnly)

            Divider()
            HStack {
                if server != nil, !readOnly {
                    Button("Delete…", role: .destructive) {
                        dismiss()
                        if let server { model.confirmation = .deleteServer(server) }
                    }
                }
                Spacer()
                Button(readOnly ? String(localized: "Close") : String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !readOnly {
                    Button(server == nil ? String(localized: "Add") : String(localized: "Save")) { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .padding(16)
        }
        .frame(width: 460)
        .fileImporter(isPresented: $pickingKey, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { identityFile = Self.tildePath(url.path) }
        }
        .fileDialogDefaultDirectory(URL(filePath: NSHomeDirectory()).appending(path: ".ssh"))
        .onAppear(perform: load)
        .onChange(of: [name, hostName, user, port, identityFile, proxyJump]) { error = nil }
    }

    private var title: String {
        switch mode {
        case .add: String(localized: "New Server")
        case .edit(let s): s.isReadOnly ? String(localized: "\(s.name) — Read-Only") : String(localized: "Edit \(s.name)")
        }
    }

    @ViewBuilder private var footer: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(error)")
        } else if let server, server.isReadOnly {
            Label("Defined in \(Self.tildePath(server.source.path)) through Include. massh does not write to Include files — edit it by hand.",
                  systemImage: "lock")
                .foregroundStyle(.secondary)
        } else {
            Text("Only this Server’s Host block in ~/.ssh/config changes; other directives, comments and order stay as they are. A backup, config.massh.bak, is made before writing.")
                .foregroundStyle(.secondary)
        }
    }

    private func load() {
        guard let server else { return }
        name = server.name
        hostName = server.hostName ?? ""
        user = server.user ?? ""
        port = server.port.map(String.init) ?? ""
        identityFile = server.identityFile ?? ""
        proxyJump = server.proxyJump ?? ""
    }

    private func save() async {
        saving = true
        defer { saving = false }
        func value(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let fields = ServerFields(
            name: name.trimmingCharacters(in: .whitespaces),
            hostName: value(hostName),
            user: value(user),
            port: Int(port),
            identityFile: value(identityFile),
            proxyJump: value(proxyJump)
        )
        do {
            try await model.save(fields, mode: mode)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

#Preview("Add") {
    ServerEditorView(model: AppModel(dependencies: .fake()), mode: .add)
}

#Preview("Read-only") {
    ServerEditorView(model: AppModel(dependencies: .fake()), mode: .edit(FakeServerStore.sampleServers[3]))
}
