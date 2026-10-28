import Foundation

enum Format {
    static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        String(localized: "\(Int64(bytesPerSecond).formatted(.byteCount(style: .decimal, spellsOutZero: false)))/s", comment: "Rate, e.g. 12 kB/s")
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(value < 10 ? 1 : 0)))
    }

    static func uptime(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? String(localized: "\(seconds) s")
    }

    static func load(_ values: [Double]) -> String {
        values.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "  ")
    }
}
