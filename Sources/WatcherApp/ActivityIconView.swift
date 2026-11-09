import AppKit
import QuartzCore
import SwiftUI
import WatcherCore

/// Working session count + continuous native waveform; completion stays unread.
/// Core Animation owns motion. No drawing timer or periodic source scans.
@MainActor final class ActivityIconView: NSView {
    private var bars = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let mark = CAShapeLayer(), badge = CAShapeLayer(), pulse = CAShapeLayer(), attentionBadge = CAShapeLayer()
    private let count = CATextLayer()
    private var active = 0, attention = 0
    private var mode: ActivityMode = .idle
    private var unread = 0
    private var configured = false
    static func width(for active: Int) -> CGFloat { active == 0 ? 24 : active < 10 ? 42 : active < 100 ? 50 : 62 }
    var displayedCount: String { active > 0 ? (active > 999 ? "999+" : String(active)) : "" }
    var workRepeatCounts: [Float] { bars.compactMap { ($0.animation(forKey: "work") as? CABasicAnimation)?.repeatCount } }
    var presentationScales: [CGFloat] { bars.map { $0.presentation()?.transform.m22 ?? $0.transform.m22 } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in bars + [mark, pulse, badge, attentionBadge] {
            shape.frame = bounds; shape.fillColor = nil; shape.lineWidth = 1.7; shape.lineCap = .round; shape.lineJoin = .round
            shape.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(shape)
        }
        count.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        count.alignmentMode = .center
        layer?.addSublayer(count)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); configure() }
    func apply(_ update: ActivityUpdate, animate: Bool = true) {
        let changed = mode != update.mode || unread != update.unread || active != update.active || attention != update.attention || !configured
        mode = update.mode; unread = update.unread; active = update.active; attention = update.attention
        if changed { configure() }
        let motion = animate && MotionMonitor.shared.enabled
        guard motion else { layer?.removeAllAnimations(); (bars + [mark, pulse, badge, attentionBadge]).forEach { $0.removeAllAnimations() }; return }
        if update.completed > 0 {
            if mode == .completed {
                let draw = CABasicAnimation(keyPath: "strokeEnd"); draw.fromValue = 0; draw.toValue = 1; draw.duration = 0.4
                mark.add(draw, forKey: "completion")
            }
            let flash = CABasicAnimation(keyPath: "opacity"); flash.fromValue = 0.85; flash.toValue = 0; flash.duration = 0.65
            pulse.add(flash, forKey: "completion")
        }
        if update.started {
            let arrive = CABasicAnimation(keyPath: "opacity"); arrive.fromValue = 0.3; arrive.toValue = 1; arrive.duration = 0.4
            layer?.add(arrive, forKey: "start")
        }
        if active > 0 {
            for (i, bar) in bars.enumerated() where bar.animation(forKey: "work") == nil {
                let wave = CABasicAnimation(keyPath: "transform.scale.y")
                wave.fromValue = 1; wave.toValue = 0.3; wave.duration = 0.65; wave.autoreverses = true; wave.repeatCount = .greatestFiniteMagnitude
                wave.beginTime = CACurrentMediaTime() + Double(i) * 0.16
                wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(wave, forKey: "work")
            }
        }
    }
    private func configure() {
        guard layer != nil else { return }
        configured = true
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var ink = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.cgColor }
        let success = (dark ? NSColor(calibratedRed: 0.55, green: 0.81, blue: 0.69, alpha: 1) : NSColor(calibratedRed: 0.16, green: 0.41, blue: 0.31, alpha: 1)).cgColor
        let attention = (dark ? NSColor(calibratedRed: 0.93, green: 0.75, blue: 0.47, alpha: 1) : NSColor(calibratedRed: 0.52, green: 0.31, blue: 0, alpha: 1)).cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.frame = CGRect(x: 0, y: 0, width: 20, height: 22)
            bar.lineWidth = active > 0 ? 2.2 : 1.7
            let height: CGFloat = [8, 16, 10][i] // idle keeps the full static waveform, without count or motion
            let x = CGFloat(3 + i * 6), y = (bounds.height - height) / 2
            let path = CGMutablePath(); path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x, y: y + height))
            bar.path = path; bar.strokeColor = ink
            bar.isHidden = active == 0 && mode != .idle
            if active == 0 { bar.removeAllAnimations() }
        }
        count.frame = CGRect(x: 22, y: 2, width: bounds.width - 22, height: 19)
        count.string = NSAttributedString(string: displayedCount, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor(cgColor: ink) ?? .labelColor])
        count.isHidden = active == 0
        mark.isHidden = active > 0
        attentionBadge.path = CGPath(ellipseIn: CGRect(x: 18, y: 16.5, width: 3.5, height: 3.5), transform: nil)
        attentionBadge.fillColor = attention; attentionBadge.isHidden = self.attention == 0 || active == 0
        let path = CGMutablePath()
        switch mode {
        case .completed:
            path.move(to: CGPoint(x: 3, y: 10)); path.addLine(to: CGPoint(x: 9, y: 4)); path.addLine(to: CGPoint(x: 17, y: 15.5))
        case .attention:
            path.move(to: CGPoint(x: 11, y: 17)); path.addLine(to: CGPoint(x: 11, y: 8)); path.move(to: CGPoint(x: 11, y: 4)); path.addLine(to: CGPoint(x: 11, y: 4.2))
        default: break
        }
        mark.path = path; mark.strokeColor = mode == .completed ? success : mode == .attention ? attention : ink; mark.strokeEnd = 1
        badge.path = CGPath(ellipseIn: CGRect(x: bounds.width - 4, y: 18, width: 3.5, height: 3.5), transform: nil)
        badge.fillColor = success; badge.strokeColor = ink; badge.lineWidth = 0.7; badge.isHidden = unread == 0
        pulse.path = CGPath(roundedRect: CGRect(x: 1, y: 1, width: 20, height: 20), cornerWidth: 6, cornerHeight: 6, transform: nil)
        pulse.strokeColor = success; pulse.opacity = 0
        CATransaction.commit()
    }
}

extension ActivityIconView {
    /// Still image of one icon state, rendered the same way as the exported icons.
    static func snapshot(_ state: ActivityUpdate, dark: Bool, scale: CGFloat = 2) -> NSImage {
        let width = width(for: state.active)
        let image = NSImage(size: NSSize(width: width, height: 22))
        let icon = ActivityIconView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        icon.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); icon.apply(state, animate: false)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(22 * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        context.cgContext.scaleBy(x: scale, y: scale)
        icon.layer?.render(in: context.cgContext)
        bitmap.size = image.size; image.addRepresentation(bitmap)
        return image
    }
}

/// Static copy of the menu bar icon for the help page; never animates.
struct MenuIconSample: View {
    let state: ActivityUpdate
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(nsImage: ActivityIconView.snapshot(state, dark: scheme == .dark))
            .frame(width: ActivityIconView.width(for: state.active), height: 22)
    }
}
