import AppKit
import SwiftTerm
import SwiftUI

/// Vercel's Geist colors (vercel.com/geist/colors), light and dark. Values come from Vercel's published tokens;
/// the app keeps system materials and controls and uses these for accent, status, charts and the terminal.
enum Geist {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let gray1000 = dynamic(light: 0x171717, dark: 0xEDEDED)
    static let gray900 = dynamic(light: 0x4D4D4D, dark: 0xA0A0A0)
    static let gray700 = dynamic(light: 0x8F8F8F, dark: 0x8F8F8F)
    static let blue = dynamic(light: 0x006BFF, dark: 0x006EFE)
    static let blueText = dynamic(light: 0x005FF2, dark: 0x47A8FF)
    static let green = dynamic(light: 0x28A948, dark: 0x00AC3A)
    static let amber = dynamic(light: 0xFFAE00, dark: 0xFFAE00)
    static let red = dynamic(light: 0xFC0035, dark: 0xF13242)

    /// 16 ANSI colors: normal 0–7, bright 8–15. Light mode uses the darker 900 steps so text stays readable on white.
    static func ansi(dark: Bool) -> [UInt32] {
        dark
            ? [0x1A1A1A, 0xF13242, 0x00AC3A, 0xFF9300, 0x0090FF, 0x9440D5, 0x00AA95, 0xA0A0A0,
               0x8F8F8F, 0xFF565F, 0x00CA50, 0xFFAE00, 0x47A8FF, 0xC472FB, 0x00CFB7, 0xEDEDED]
            : [0x171717, 0xD8001B, 0x107D32, 0xAA4D00, 0x005FF2, 0x7928CA, 0x0A7C72, 0x8F8F8F,
               0x4D4D4D, 0xFC0035, 0x28A948, 0xC77700, 0x006BFF, 0xFF0080, 0x00A88F, 0xA0A0A0]
    }

    static func nsColor(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func terminalColor(_ rgb: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xFF) * 257, green: UInt16((rgb >> 8) & 0xFF) * 257,
                        blue: UInt16(rgb & 0xFF) * 257)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            nsColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}
