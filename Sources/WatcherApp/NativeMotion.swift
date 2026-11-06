import AppKit
import SwiftUI
import Combine
import QuartzCore

/// Event-driven preferences, shared by the menu icon and visible session rows.
@MainActor final class MotionMonitor: ObservableObject {
    static let shared = MotionMonitor()
    @Published private(set) var enabled = false
    private var screenAwake = true
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private init() {
        observe(.default, .NSProcessInfoPowerStateDidChange)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification, awake: false)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification, awake: true)
        update()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, awake: Bool? = nil) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let awake { screenAwake = awake }
                update()
            }
        }
        observers.append((center, token))
    }
    private func update() {
        let value = screenAwake && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if enabled != value { enabled = value }
    }
}

struct WorkingGlyph: NSViewRepresentable {
    let moving: Bool
    let color: NSColor
    func makeNSView(context: Context) -> WorkingGlyphView { WorkingGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 20)) }
    func updateNSView(_ view: WorkingGlyphView, context: Context) { view.apply(moving: moving, color: color) }
    static func dismantleNSView(_ view: WorkingGlyphView, coordinator: ()) { view.stop() }
}

@MainActor final class WorkingGlyphView: NSView {
    private let bars = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private var moving = false
    var animationCount: Int { bars.filter { $0.animation(forKey: "work") != nil }.count }
    var presentationScales: [CGFloat] { bars.map { $0.presentation()?.transform.m22 ?? $0.transform.m22 } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        for (i, bar) in bars.enumerated() {
            bar.frame = bounds; bar.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            bar.lineWidth = 2; bar.lineCap = .round
            let height: CGFloat = [6, 12, 8][i], x = CGFloat(3 + i * 5)
            let path = CGMutablePath(); path.move(to: CGPoint(x: x, y: (20 - height) / 2)); path.addLine(to: CGPoint(x: x, y: (20 + height) / 2))
            bar.path = path; layer?.addSublayer(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sync() }
    func apply(moving: Bool, color: NSColor) {
        self.moving = moving
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bars.forEach { $0.strokeColor = color.cgColor }
        CATransaction.commit(); sync()
    }
    func stop() { bars.forEach { $0.removeAllAnimations() } }
    private func sync() {
        guard moving, window != nil else { stop(); return }
        for (i, bar) in bars.enumerated() where bar.animation(forKey: "work") == nil {
            let wave = CABasicAnimation(keyPath: "transform.scale.y")
            wave.fromValue = 1; wave.toValue = 0.35; wave.duration = 0.65
            wave.autoreverses = true; wave.repeatCount = .greatestFiniteMagnitude
            wave.beginTime = CACurrentMediaTime() + Double(i) * 0.16
            wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(wave, forKey: "work")
        }
    }
}
