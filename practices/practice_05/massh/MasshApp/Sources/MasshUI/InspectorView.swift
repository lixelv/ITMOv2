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
        if let snapshot = inspector.snapshot {
            Group {
                switch tab {
                case .overview: OverviewView(snapshot: snapshot, history: inspector.history)
                case .ports: Text("Порты")
                case .processes: Text("Процессы")
                case .containers: Text("Контейнеры")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Подключение к \(server.name)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview("Inspector") {
    let model = AppModel(dependencies: .fake())
    model.selectedServerName = "web-1"
    return InspectorView(model: model)
        .task { model.start() }
        .frame(width: 360, height: 760)
}
