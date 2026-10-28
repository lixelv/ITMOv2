import AppKit
import SwiftTerm

/// When the user last typed into a terminal. Inspector updates wait for a pause in typing, so a keystroke's echo
/// never queues behind a 1 Hz relayout of the inspector.
@MainActor
enum TypingActivity {
    private(set) static var lastInput: ContinuousClock.Instant?

    static func noteInput() { lastInput = .now }

    /// Whether a keystroke arrived within `window`.
    static func isTyping(within window: Duration = .milliseconds(300)) -> Bool {
        lastInput.map { ContinuousClock.now - $0 < window } ?? false
    }
}

/// SwiftTerm's local-process view that reports user input to `TypingActivity`.
class MasshTerminalView: LocalProcessTerminalView {
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { TypingActivity.noteInput() }
        super.send(source: source, data: data)
    }
}
