import MasshCore
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview, ports, processes, containers
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .ports: String(localized: "Ports")
        case .processes: String(localized: "Processes")
        case .containers: String(localized: "Containers")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .ports: "point.3.connected.trianglepath.dotted"
        case .processes: "list.bullet.rectangle"
        case .containers: "shippingbox"
        }
    }
}

struct InspectorView: View {
    var model: AppModel
    @State private var tab: InspectorTab = .overview

    var body: some View {
        if let server = model.selectedServer {
            VStack(spacing: 0) {
                // Icon selector like Xcode's inspector tabs.
                Picker("Section", selection: $tab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).labelStyle(.iconOnly).help(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                InspectorContent(model: model, server: server, tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            ContentUnavailableView("No Server Selected", systemImage: "server.rack",
                                   description: Text("Select a Server in the list to see what is running on it."))
        }
    }
}

struct InspectorContent: View {
    var model: AppModel
    var server: Server
    var tab: InspectorTab

    var inspector: InspectorModel { model.inspector }

    var body: some View {
        VStack(spacing: 0) {
            banners
            if let snapshot = inspector.snapshot {
                Group {
                    switch tab {
                    case .overview: OverviewView(snapshot: snapshot, history: inspector.history)
                    case .ports: PortsTable(ports: snapshot.ports)
                    case .processes: ProcessesTable(processes: snapshot.processes)
                    case .containers: ContainersTable(docker: snapshot.docker)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Frozen numbers must not pass for live ones.
                .opacity(inspector.isLive ? 1 : 0.45)
                .saturation(inspector.isLive ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: inspector.isLive)
            } else {
                placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
            Spacer(minLength: 4)
            accessory
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 10)
        .padding(.top, 8)
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
        .frame(width: 360, height: 760)
}

#Preview("Inspector — live") { inspectorPreview(.live) }
#Preview("Inspector — no Agent") { inspectorPreview(.noAgent) }
#Preview("Inspector — outdated Agent") { inspectorPreview(.outdatedAgent) }
#Preview("Inspector — connection drops") { inspectorPreview(.dropsConnection(after: 4)) }
#Preview("Inspector — no Docker") { inspectorPreview(.dockerMissing) }
