import MasshCore
import SwiftUI

/// The Inspector: one scrolling page with Overview, Containers, Processes and Ports for the selected Server (ADR 0007).
struct InspectorView: View {
    var model: AppModel

    var body: some View {
        if let server = model.selectedServer {
            InspectorContent(model: model, server: server)
        } else {
            ContentUnavailableView("No Server Selected", systemImage: "server.rack",
                                   description: Text("Select a Server in the list to see what is running on it."))
        }
    }
}

struct InspectorContent: View {
    var model: AppModel
    var server: Server

    // View state, so 1 Hz Snapshot updates keep the search, order and collapsed sections. It is kept on purpose
    // when another Server is selected: a search for "nginx" or a collapsed Overview applies to the next one too.
    @State private var query = ProcessQuery()
    @State private var collapsed: Set<InspectorPart> = []

    var inspector: InspectorModel { model.inspector }

    var body: some View {
        VStack(spacing: 0) {
            banners
            if let snapshot = inspector.snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        page(snapshot)
                    }
                }
                // Frozen numbers must not pass for live ones.
                .opacity(inspector.isLive ? 1 : 0.45)
                .saturation(inspector.isLive ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: inspector.isLive)
            } else {
                placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func page(_ snapshot: Snapshot) -> some View {
        InspectorSection(part: .overview, isExpanded: expanded(.overview)) {
            OverviewView(snapshot: snapshot, history: inspector.history)
        }
        InspectorSection(part: .containers, count: snapshot.docker.count, isExpanded: expanded(.containers)) {
            ContainersGrid(docker: snapshot.docker)
        }
        InspectorSection(part: .processes, count: snapshot.processes.count, isExpanded: expanded(.processes)) {
            ProcessControls(query: $query)
        } content: {
            ProcessList(processes: snapshot.processes, query: $query)
        }
        InspectorSection(part: .ports, count: snapshot.ports.count, isExpanded: expanded(.ports)) {
            PortsView(ports: snapshot.ports)
        }
    }

    private func expanded(_ part: InspectorPart) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(part) }, set: { if $0 { collapsed.remove(part) } else { collapsed.insert(part) } })
    }

    @ViewBuilder private var banners: some View {
        if let outdated = inspector.outdated {
            InspectorBanner(
                symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .orange,
                title: String(localized: "Update Agent"),
                detail: String(localized: "The Server runs Agent \(outdated.installed); massh ships \(outdated.bundled).")
            ) {
                Button("Update…") { model.confirmation = .updateAgent(server) }
            }
        }
        switch inspector.connection {
        case .lost(let reason):
            InspectorBanner(symbol: "bolt.horizontal.circle.fill", tint: .red, title: String(localized: "Connection to the Agent lost"),
                            detail: staleDetail(reason)) { ProgressView().controlSize(.small) }
        case .reconnecting(let attempt):
            InspectorBanner(symbol: "arrow.clockwise.circle.fill", tint: .secondary, title: String(localized: "Reconnecting…"),
                            detail: staleDetail(String(localized: "attempt \(attempt)"))) { ProgressView().controlSize(.small) }
        default:
            EmptyView()
        }
    }

    private func staleDetail(_ reason: String) -> String {
        guard let at = inspector.receivedAt else { return reason }
        return String(localized: "\(reason). Data as of \(at.formatted(date: .omitted, time: .standard)).")
    }

    @ViewBuilder private var placeholder: some View {
        switch inspector.connection {
        case .noAgent:
            NoAgentView(model: model, server: server)
        case .unsupportedFormat(let version):
            ContentUnavailableView("Agent Is Newer Than massh", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                                   description: Text("The Agent on \(server.name) sends format \(version), which this build of massh does not understand. Update massh."))
        case .lost(let reason):
            ContentUnavailableView("No Connection to the Agent", systemImage: "bolt.horizontal.circle", description: Text(reason))
        default:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(server.name)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// "No Agent" with the install offer; declining leaves the terminal and status untouched.
struct NoAgentView: View {
    var model: AppModel
    var server: Server

    var body: some View {
        let declined = model.declinedAgentInstall.contains(server.name)
        ContentUnavailableView {
            Label("No Agent on \(server.name)", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            declined
                ? Text("The terminal and status work without the Agent. System details, ports, processes and containers appear once it is installed.")
                : Text("The Agent is a small massh service that reports on the Server through an SSH tunnel. The terminal and status work without it.")
        } actions: {
            if declined {
                Button("Install Agent…") { model.confirmation = .installAgent(server) }
            } else {
                Button("Install Agent…") { model.confirmation = .installAgent(server) }
                    .buttonStyle(.glassProminent)
                Button("Not Now") { model.declinedAgentInstall.insert(server.name) }
            }
        }
    }
}

struct InspectorBanner<Accessory: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: Space.xs)
            accessory
        }
        .padding(Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.floating))
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .accessibilityElement(children: .combine)
    }
}

@MainActor private func inspectorPreview(_ scenario: FakeObservationService.Scenario) -> some View {
    let model = AppModel(dependencies: .fake(scenario: scenario))
    return InspectorView(model: model)
        .task {
            model.start()
            try? await Task.sleep(for: .milliseconds(100))
            model.selectedServerName = "web-1"
        }
        .frame(width: 1000, height: 760)
}

#Preview("Inspector — live") { inspectorPreview(.live) }
#Preview("Inspector — no Agent") { inspectorPreview(.noAgent) }
#Preview("Inspector — outdated Agent") { inspectorPreview(.outdatedAgent) }
#Preview("Inspector — connection drops") { inspectorPreview(.dropsConnection(after: 4)) }
#Preview("Inspector — no Docker") { inspectorPreview(.dockerMissing) }
