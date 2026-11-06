import SwiftUI
import WatcherCore

/// Shared roles for the compact native panel; no new drawing or polling loop.
enum PanelStyle {
    static func secondary(_ scheme: ColorScheme) -> Color { scheme == .dark ? rgb(0xb8c2d1) : rgb(0x576170) }
    static func warning(_ scheme: ColorScheme) -> Color { scheme == .dark ? rgb(0xeebf78) : rgb(0x855000) }
    static func statusColor(_ status: SessionStatus, _ scheme: ColorScheme) -> Color {
        switch status {
        case .running, .tool: scheme == .dark ? rgb(0x9cc7ff) : rgb(0x245fa8)
        case .idle: scheme == .dark ? rgb(0x91d6ad) : rgb(0x286a45)
        case .waitingApproval, .waitingInput: warning(scheme)
        case .error: scheme == .dark ? rgb(0xffaaa4) : rgb(0xad3028)
        default: secondary(scheme)
        }
    }
    static func symbol(_ status: SessionStatus) -> String {
        switch status {
        case .running, .tool: "waveform"
        case .waitingApproval: "diamond.fill"
        case .waitingInput: "questionmark.circle"
        case .idle: "checkmark"
        case .error: "exclamationmark.circle"
        case .interrupted: "pause"
        case .ended: "stop.circle"
        case .unknown: "circle.dashed"
        }
    }
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct SessionStatusIcon: View {
    let status: SessionStatus
    var animate = true
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var motion = MotionMonitor.shared
    @State private var visible = false
    var body: some View {
        Group {
            if status.isWorking {
                WorkingGlyph(moving: animate && visible && motion.enabled, color: NSColor(PanelStyle.statusColor(status, scheme)))
            } else {
                Image(systemName: PanelStyle.symbol(status)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PanelStyle.statusColor(status, scheme))
            }
        }.frame(width: 16, height: 20)
            .accessibilityLabel(status.isWorking ? "正在工作" : status.label)
            .onAppear { visible = true }.onDisappear { visible = false }
    }
}

struct QuotaRing: View {
    let remaining: Int?
    var stale = false
    @Environment(\.colorScheme) private var scheme
    private var color: Color { stale || (remaining ?? 100) <= 15 ? PanelStyle.warning(scheme) : PanelStyle.statusColor(.running, scheme) }
    var body: some View {
        ZStack {
            if let remaining {
                Circle().stroke(PanelStyle.secondary(scheme).opacity(0.18), lineWidth: 2.5)
                Circle().trim(from: 0, to: CGFloat(min(100, max(0, remaining))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                if stale { Circle().fill(PanelStyle.warning(scheme)).frame(width: 4, height: 4) }
            } else {
                Circle().stroke(PanelStyle.secondary(scheme).opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                Rectangle().fill(PanelStyle.secondary(scheme)).frame(width: 6, height: 1.5)
            }
        }.frame(width: 19, height: 19).padding(2)
            .accessibilityLabel(remaining.map { "剩余 \($0)%" } ?? "剩余额度未知")
    }
}

/// Native Button semantics and focus are retained; only the hover/press surface
/// is customized. No animated hover, persistent timer, or extra view layer.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration) }
    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.10 : hovered ? 0.055 : 0) : 0), in: RoundedRectangle(cornerRadius: 6))
                .overlay { if focused { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2) } }
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}
