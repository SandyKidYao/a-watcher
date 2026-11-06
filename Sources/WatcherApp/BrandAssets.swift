import AppKit
import SwiftUI
import ImageIO
import WatcherCore

@MainActor enum BrandAssets {
    private static var images: [String: NSImage] = [:]
    static func image(_ provider: AgentProvider, dark: Bool = false) -> NSImage {
        let name = provider == .codex ? (dark ? "codex-dark" : "codex") : "claude"
        if let cached = images[name] { return cached }
        let url = Bundle.main.resourceURL?.appendingPathComponent("Brand/\(name).png")
        if let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            let image = NSImage(cgImage: thumbnail, size: NSSize(width: 32, height: 32)); images[name] = image; return image
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: provider.name)!
    }
}
struct AgentIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var scheme
    var body: some View { Image(nsImage: BrandAssets.image(provider, dark: scheme == .dark)).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size, height: size).accessibilityLabel(provider.name) }
}
