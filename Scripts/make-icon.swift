// Renders the a-watcher app icon: a quota ring around the working wave.
// Usage: swift Scripts/make-icon.swift OUTPUT_1024.png, then sips each iconset size and run iconutil -c icns into Resources/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon-1024.png")
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// macOS icon grid: 824pt body centered in 1024 with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
cg.addPath(shape); cg.setFillColor(color(0x151A2E)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0x283158), color(0x10142A)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
let glow = CGGradient(colorsSpace: space, colors: [color(0x4F7CFF, 0.30), color(0x4F7CFF, 0)] as CFArray, locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
cg.restoreGState()

// Quota ring: faint track plus a bright arc of remaining quota.
let center = CGPoint(x: 512, y: 512), radius: CGFloat = 268, line: CGFloat = 46
cg.setLineWidth(line); cg.setLineCap(.round)
cg.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
cg.setStrokeColor(color(0xFFFFFF, 0.10)); cg.strokePath()
cg.saveGState()
cg.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.45, clockwise: true)
cg.replacePathWithStrokedPath(); cg.clip()
let arc = CGGradient(colorsSpace: space, colors: [color(0x7FE3FF), color(0x4F7CFF)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(arc, start: CGPoint(x: 300, y: 800), end: CGPoint(x: 760, y: 260), options: [])
cg.restoreGState()

// Working wave: three rounded bars, matching the menu bar animation.
let bars: [(x: CGFloat, height: CGFloat)] = [(422, 170), (512, 270), (602, 200)]
for bar in bars {
    let rect = CGRect(x: bar.x - 28, y: center.y - bar.height / 2, width: 56, height: bar.height)
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
}
cg.setFillColor(color(0xF4F7FF)); cg.fillPath()

// Unread dot, the completion cue from the menu bar.
cg.addEllipse(in: CGRect(x: 700, y: 700, width: 92, height: 92))
cg.setFillColor(color(0xFF8A4C)); cg.fillPath()

guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: output)
