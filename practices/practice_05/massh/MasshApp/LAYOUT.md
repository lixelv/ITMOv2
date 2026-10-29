# massh window layout

Design maturity: **L0** — no DESIGN.md. The design language is Apple's own (ADR 0003): system controls,
system colors and materials, Liquid Glass from the OS. No custom palette or type scale is defined; sizes marked
*provisional* below are starting points to revisit if a DESIGN.md is ever written.

**Pattern:** list-detail with two modes (ADR 0007). `NavigationSplitView` (sidebar + detail); the detail is either
the Terminal or the Inspector, full width. The Terminal stays in the hierarchy under the Inspector so its sessions
keep running.

| Zone | Components | Notes |
|------|------------|-------|
| Toolbar | Connect (`terminal`), Add Server (`plus`), `Terminal \| Inspector` segmented mode picker (principal) | Glass toolbar from the system. ⌘1/⌘2 in the View menu. Connect, double click and Agent actions switch to Terminal; selecting a Server keeps the mode |
| Sidebar | `List(selection:)`, one row per Server: status symbol, name, `HostName` secondary | Status uses shape *and* color (`checkmark.circle.fill` / `xmark.circle.fill` / `questionmark.circle`) plus an accessibility value, never color alone. `Include` Servers carry a `lock` badge and their file in the tooltip. Context menu holds every Server action. Width ideal 220 (*provisional*) |
| Terminal | Tab strip (one tab per terminal, close buttons) over a SwiftTerm view | Empty state: `ContentUnavailableView` with Connect. Ended session: bar at the bottom of the tab with exit code and Reconnect |
| Inspector | Icon tab picker (Overview, Ports, Processes, Containers); state banner above content | Full width of the detail. Overview is a grouped `Form` with gauges and Swift Charts (chart height 56, *provisional*); the other tabs are sortable `Table`s |
| Sheets | Server editor (`Form`, six fields), confirmation dialogs for delete and Agent install/update/remove | Errors from the store shown inline in the form footer |

## Heuristic notes

- *Visibility of status:* connection state lives in a banner at the top of the inspector; when the connection is
  lost, numbers are dimmed and labelled with how stale they are, so frozen data never reads as live.
- *Error prevention / user control:* deletes and every Agent action are confirmed; declining the Agent leaves the
  terminal and status fully usable.
- *Consistency:* standard controls only; the toolbar and context menu expose the same actions.
- *No flicker:* numbers use `monospacedDigit()` so 1 Hz updates do not shift layout.

## Icon, languages, appearance

- **Icon:** `Resources/AppIcon.icon`, made in Icon Composer (one glass panel with a `>_` prompt, Default/Dark/Mono
  variants); `bundle.sh` compiles it with `actool` into `Assets.car` and `AppIcon.icns`.
- **Languages:** English is the source language, Russian a translation (`Resources/Localizable.xcstrings` for the UI,
  `MasshCore/Sources/MasshCore/Resources/Localizable.xcstrings` for MasshCore). massh shows Russian when the system's
  first language is Russian and English otherwise. After changing UI text run `./sync-strings.sh` and translate the
  new keys.
- **Colors:** Vercel's Geist palette (`Sources/MasshUI/Geist.swift`, values from Vercel's published tokens):
  Geist blue as the app's AccentColor (asset catalog, so standard controls pick it up), Geist green/red/gray for
  Online/Offline/Unknown, blue/amber/red gauges, blue and gray charts, and a black-or-white Geist terminal with a
  Geist ANSI palette. Sidebar, inspector and toolbar keep the system materials (ADR 0003).
- **Terminal latency:** SwiftTerm is vendored with a redraw patch (`Vendor/SwiftTerm/PATCHES.md`), and inspector
  updates wait for a pause in typing (`TypingActivity`). Measured echo-to-screen latency with the inspector
  streaming: median ≈2 ms, worst ≈13 ms (was ≈21 ms and up to 130 ms).
- **Appearance:** system light/dark throughout, the terminal included. `MASSH_APPEARANCE=light|dark` pins one for checks.
