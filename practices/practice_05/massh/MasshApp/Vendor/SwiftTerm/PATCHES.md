# Changes from SwiftTerm 1.11.2

Vendored because massh needs one behaviour change upstream does not have (1.20 still throttles the same way), and
1.12+ needs the separately downloaded Metal toolchain to build.

1. `queuePendingDisplay` (Apple/AppleTerminalView.swift) redrew the screen always 1/60 s after new data. After a
   quiet period it now redraws on the next main-loop turn, so typed characters echo without the extra delay; bursts
   of output are still coalesced to at most 60 redraws a second. `lastDisplayUptime` (Mac/MacTerminalView.swift)
   records the last redraw.

Removed: the fuzz, termcast and benchmark targets, tests and the demo apps.
