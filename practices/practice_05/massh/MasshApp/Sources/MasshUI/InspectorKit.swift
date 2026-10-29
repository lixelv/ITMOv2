import MasshCore
import SwiftUI

/// Thin fill bar (DESIGN.md: 4 pt, threshold colors). Above 80 % amber, above 90 % red when `warns` is set.
/// Not animated: rows re-sort instantly on each Snapshot, and a sliding bar would lag behind its row.
struct MeterBar: View {
    var fraction: Double
    var warns = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    private var tint: Color {
        guard warns else { return Geist.blue }
        return clamped > 0.9 ? Geist.red : clamped > 0.8 ? Geist.amber : Geist.blue
    }
}

/// Label, live value and a `MeterBar` underneath; the value never shifts layout on 1 Hz updates.
struct Meter: View {
    var title: String
    var value: String
    var fraction: Double
    var warns = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: Space.xs)
                Text(value).monospacedDigit().contentTransition(.numericText())
            }
            .font(.caption)
            MeterBar(fraction: fraction, warns: warns)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Capsule with monospaced machine text: a port, an address.
struct Chip: View {
    enum Tone { case accent, neutral }

    var text: String
    var tone = Tone.neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: Space.xxs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.machine)
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xxs)
        .foregroundStyle(tone == .accent ? AnyShapeStyle(Geist.blueText) : AnyShapeStyle(.secondary))
        .background(Capsule().fill(tone == .accent ? AnyShapeStyle(Geist.accentFill) : AnyShapeStyle(.quaternary)))
    }
}

/// Container state as symbol, color and text together: never color alone.
struct StatusBadge: View {
    var state: ContainerState
    var text: String

    var body: some View {
        let look = Self.look(state)
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: look.symbol).foregroundStyle(look.color)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private static func look(_ state: ContainerState) -> (symbol: String, color: Color) {
        switch state {
        case .running: ("checkmark.circle.fill", Geist.green)
        case .paused: ("pause.circle.fill", Geist.amber)
        case .failing: ("exclamationmark.triangle.fill", Geist.red)
        case .stopped: ("xmark.circle.fill", Geist.red)
        case .unknown: ("questionmark.circle", Geist.gray700)
        }
    }
}

/// One line of machine text in small print, cut in the middle with the whole of it in the tooltip.
struct MachineLine: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.machine).lineLimit(1).truncationMode(.middle).help(text)
    }
}

extension View {
    /// DESIGN.md depth level 1: 1 pt outline, no fill or shadow. Fills its grid cell, so cards in a row are one height.
    func card() -> some View {
        padding(Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Geist.cardStroke))
    }
}

/// The Inspector page's sections, in page order.
enum InspectorPart: CaseIterable {
    case overview, containers, processes, ports

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .containers: String(localized: "Containers")
        case .processes: String(localized: "Processes")
        case .ports: String(localized: "Ports")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .containers: "shippingbox"
        case .processes: "list.bullet.rectangle"
        case .ports: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Collapsible Inspector section with a pinned header, a count and optional controls on the right.
struct InspectorSection<Content: View, Accessory: View>: View {
    var part: InspectorPart
    var count: Int?
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            if isExpanded {
                content
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.xl)
            }
        } header: {
            HStack(spacing: Space.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Label(part.title, systemImage: part.symbol).font(.title3.weight(.semibold))
                        if let count {
                            Text("\(count)").font(.callout).monospacedDigit().contentTransition(.numericText()).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
                Spacer()
                if isExpanded { accessory }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background(.bar)
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(part: InspectorPart, count: Int? = nil, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(part: part, count: count, isExpanded: isExpanded, accessory: { EmptyView() }, content: content)
    }
}
