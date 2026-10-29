import AppKit
import MasshCore
import SwiftTerm
import SwiftUI

/// SwiftTerm running one command (normally the system `ssh <server>`) in a pseudo-terminal.
struct TerminalSurface: NSViewRepresentable {
    var command: TerminalCommand
    var isActive: Bool
    var onExit: @MainActor (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = MasshTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.optionAsMetaKey = true
        Self.applyColors(to: view)
        context.coordinator.colorScheme = context.environment.colorScheme

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        view.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: NSHomeDirectory()
        )
        context.coordinator.watch(pid: view.process.shellPid)
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        if context.coordinator.colorScheme != context.environment.colorScheme {
            context.coordinator.colorScheme = context.environment.colorScheme
            Self.applyColors(to: view)
        }
        if isActive, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !isActive, view.window?.firstResponder === view {
            // A hidden terminal (another tab, or the Inspector on top) must not keep receiving keystrokes.
            DispatchQueue.main.async { if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) } }
        }
    }

    /// Geist (Vercel) terminal colors. SwiftTerm resolves colors once, so they are re-applied on every light/dark change.
    private static func applyColors(to view: LocalProcessTerminalView) {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        view.nativeBackgroundColor = Geist.nsColor(dark ? 0x000000 : 0xFFFFFF)
        view.nativeForegroundColor = Geist.nsColor(dark ? 0xEDEDED : 0x171717)
        view.caretColor = Geist.nsColor(dark ? 0xEDEDED : 0x171717)
        view.selectedTextBackgroundColor = Geist.nsColor(dark ? 0x00418B : 0xCDE6FF)
        view.installColors(Geist.ansi(dark: dark).map(Geist.terminalColor))
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        // Closing a tab ends its ssh.
        coordinator.stop()
        view.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
        var onExit: @MainActor (Int32?) -> Void
        var colorScheme: ColorScheme?

        init(onExit: @escaping @MainActor (Int32?) -> Void) {
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            // SwiftTerm's fork path hands over the raw waitpid status; the exit code is its high byte.
            report(exitCode.map { $0 > 255 ? ($0 >> 8) & 0xff : $0 })
        }

        private var reported = false
        private var timer: Timer?

        /// SwiftTerm registers its exit watcher after the fork, so a command that fails at once (unknown host)
        /// can exit unnoticed. Poll for the child as a fallback.
        func watch(pid: pid_t) {
            guard pid > 0 else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                guard result == pid || (result == -1 && errno == ECHILD && kill(pid, 0) != 0) else { return }
                let exited = result == pid && (status & 0x7f) == 0
                self?.report(exited ? (status >> 8) & 0xff : nil)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func report(_ code: Int32?) {
            DispatchQueue.main.async { [self] in
                guard !reported else { return }
                reported = true
                stop()
                MainActor.assumeIsolated { onExit(code) }
            }
        }
    }
}
