import MasshCore
import SwiftUI

/// Terminal tabs. Every tab's terminal stays alive while another tab is shown.
struct WorkspaceView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.tabs.isEmpty {
            ContentUnavailableView {
                Label("Нет открытых терминалов", systemImage: "terminal")
            } description: {
                Text("Дважды щёлкните Server в списке или нажмите «Подключиться».")
            } actions: {
                if let server = model.selectedServer {
                    Button("Подключиться к \(server.name)") { model.connect(server) }
                        .buttonStyle(.glassProminent)
                }
            }
        } else {
            VStack(spacing: 0) {
                TabStrip(model: model)
                Divider()
                ZStack {
                    ForEach(model.tabs) { tab in
                        let active = tab.id == model.activeTabID
                        TerminalPane(model: model, tab: tab, isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                    }
                }
            }
        }
    }
}

private struct TerminalPane: View {
    var model: AppModel
    var tab: TerminalTab
    var isActive: Bool

    var body: some View {
        TerminalSurface(command: tab.command, isActive: isActive) { code in
            model.terminalExited(tab.id, code: code)
        }
        .id(tab.generation) // a new generation starts the command again
        .padding(.leading, 6)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) {
            if case .exited(let code) = tab.state {
                SessionEndedBar(code: code, restart: { model.restart(tab.id) }, close: { model.close(tab.id) })
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: tab.state)
    }
}

private struct SessionEndedBar: View {
    var code: Int32?
    var restart: () -> Void
    var close: () -> Void

    var body: some View {
        // Narrow workspaces get icon-only buttons instead of wrapped text.
        ViewThatFits(in: .horizontal) {
            content(compact: false)
            content(compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func content(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Label {
                Text(code.map { "Сессия завершена · код \($0)" } ?? "Сессия завершена")
            } icon: {
                Image(systemName: code == 0 ? "checkmark.circle" : "bolt.horizontal.circle")
            }
            .foregroundStyle(.secondary)
            .fixedSize()
            Spacer(minLength: 8)
            Button("Переподключить", systemImage: "arrow.clockwise", action: restart)
                .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .help("Переподключить")
            Button("Закрыть вкладку", systemImage: "xmark", action: close)
                .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleOnly))
                .help("Закрыть вкладку")
        }
        .fixedSize(horizontal: !compact, vertical: false)
    }
}

/// Type-erased label style so one button can switch styles.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Xcode-like editor tabs.
private struct TabStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    TabButton(
                        tab: tab,
                        isActive: tab.id == model.activeTabID,
                        select: { model.activeTabID = tab.id },
                        close: { model.close(tab.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.never)
        .background(.bar)
    }
}

private struct TabButton: View {
    var tab: TerminalTab
    var isActive: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.state == .running ? "terminal" : "terminal.fill")
                .foregroundStyle(tab.state == .running ? .secondary : .tertiary)
            Text(tab.command.title)
                .lineLimit(1)
                .foregroundStyle(tab.state == .running ? .primary : .secondary)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isActive ? 1 : 0)
            .help("Закрыть вкладку")
            .accessibilityLabel("Закрыть вкладку \(tab.command.title)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.state == .running ? tab.command.title : "\(tab.command.title) — сессия завершена")
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Tabs") {
    let model = AppModel(dependencies: .fake())
    model.open(TerminalTab(serverName: "web-1", command: TerminalCommand(title: "web-1", executable: "/bin/sh",
                                                                          arguments: ["-c", "echo привет из massh; top -l 1 | head -12"])))
    model.open(TerminalTab(serverName: "db-1", command: TerminalCommand(title: "db-1", executable: "/bin/sh",
                                                                         arguments: ["-c", "echo done"])))
    return WorkspaceView(model: model).frame(width: 800, height: 420)
}
