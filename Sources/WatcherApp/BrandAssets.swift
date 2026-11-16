import AppKit
import SwiftUI
import ImageIO
import WatcherCore

@MainActor enum BrandAssets {
    private static var images: [String: NSImage] = [:]
    static func image(_ provider: AgentProvider, dark: Bool = false) -> NSImage {
        let name = dark ? provider.source.darkAsset ?? provider.rawValue : provider.rawValue
        if let cached = images[name] { return cached }
        let url = Bundle.main.resourceURL?.appendingPathComponent("Brand/\(name).png")
        if let url, FileManager.default.fileExists(atPath: url.path), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            let image = NSImage(cgImage: thumbnail, size: NSSize(width: 32, height: 32)); images[name] = image; return image
        }
        return NSImage(systemSymbolName: provider.source.symbol, accessibilityDescription: provider.name)!
    }
}
struct AgentIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var scheme
    var body: some View { Image(nsImage: BrandAssets.image(provider, dark: scheme == .dark)).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size, height: size).accessibilityLabel(provider.name) }
}
