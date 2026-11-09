import AppKit

/// Borderless panel anchored under the status item. It keeps the transient
/// popover behavior (outside click, app switch and Esc close it) without the
/// popover's arrow. No timers; only event monitors while visible.
@MainActor final class MenuPanel: NSPanel {
    var onClose: (() -> Void)?
    private weak var anchor: NSView?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var closing = false

    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320), styleMask: [.borderless], backing: .buffered, defer: true)
        isFloatingPanel = true; level = .statusBar; hidesOnDeactivate = false
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        isReleasedWhenClosed = false; animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentViewController = content
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var isShown: Bool { isVisible && !closing }

    func show(below anchor: NSView, size: NSSize) {
        self.anchor = anchor
        place(size)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
    }
    /// Keeps the top edge just under the menu bar and the panel on screen.
    func place(_ size: NSSize) {
        guard let anchor, let window = anchor.window else { setContentSize(size); return }
        let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? button
        let x = min(max(button.midX - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
        let top = min(button.minY, visible.maxY) - 4
        setFrame(NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height), display: true)
        invalidateShadow()
    }
    override func close() {
        guard !closing else { return }
        closing = true
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        mouseMonitor = nil; resignObserver = nil
        super.close()
        onClose?(); onClose = nil
    }
}
