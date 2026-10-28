import MasshCore
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview, ports, processes, containers
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Обзор"
        case .ports: "Порты"
        case .processes: "Процессы"
        case .containers: "Контейнеры"
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
                Picker("Раздел", selection: $tab) {
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
            ContentUnavailableView("Server не выбран", systemImage: "server.rack",
                                   description: Text("Выберите Server в списке, чтобы увидеть сведения о нём."))
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
                title: "Обновить Agent",
                detail: "На Server Agent \(outdated.installed), в massh — \(outdated.bundled)."
            ) {
                Button("Обновить…") { model.confirmation = .updateAgent(server) }
            }
        }
        switch inspector.connection {
        case .lost(let reason):
            InspectorBanner(symbol: "bolt.horizontal.circle.fill", tint: .red, title: "Соединение с Agent потеряно",
                            detail: staleDetail(reason)) { ProgressView().controlSize(.small) }
        case .reconnecting(let attempt):
            InspectorBanner(symbol: "arrow.clockwise.circle.fill", tint: .secondary, title: "Переподключение…",
                            detail: staleDetail("попытка \(attempt)")) { ProgressView().controlSize(.small) }
        default:
            EmptyView()
        }
    }

    private func staleDetail(_ reason: String) -> String {
        guard let at = inspector.receivedAt else { return reason }
        return "\(reason). Данные на \(at.formatted(date: .omitted, time: .standard))."
    }

    @ViewBuilder private var placeholder: some View {
        switch inspector.connection {
        case .noAgent:
            NoAgentView(model: model, server: server)
        case .unsupportedFormat(let version):
            ContentUnavailableView("Agent новее massh", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                                   description: Text("Agent на \(server.name) отдаёт формат \(version), а эта сборка massh его не понимает. Обновите massh."))
        case .lost(let reason):
            ContentUnavailableView("Нет связи с Agent", systemImage: "bolt.horizontal.circle", description: Text(reason))
        default:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Подключение к \(server.name)…").foregroundStyle(.secondary)
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
            Label("На \(server.name) нет Agent", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(declined
                 ? "Терминал и статус работают и без Agent. Сведения о системе, портах, процессах и контейнерах появятся после установки."
                 : "Agent — небольшой сервис massh, который отдаёт сведения о Server через SSH-туннель. Без него работают терминал и статус.")
        } actions: {
            if declined {
                Button("Установить Agent…") { model.confirmation = .installAgent(server) }
            } else {
                Button("Установить Agent…") { model.confirmation = .installAgent(server) }
                    .buttonStyle(.glassProminent)
                Button("Не сейчас") { model.declinedAgentInstall.insert(server.name) }
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
