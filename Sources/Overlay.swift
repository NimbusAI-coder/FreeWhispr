import AppKit

/// A small borderless pill near the bottom of the active screen showing that
/// FreeWhispr is listening. Purely local UI — it never reads anything about the
/// app underneath it.
@MainActor
final class Overlay {

    private var window: NSWindow?
    private var levelView: LevelView?

    func show(latched: Bool) {
        if window == nil { build() }
        levelView?.latched = latched
        levelView?.status = latched ? "Listening — tap fn to stop" : "Listening…"
        levelView?.needsDisplay = true
        reposition()
        window?.orderFrontRegardless()
    }

    func setLatched(_ latched: Bool) {
        levelView?.latched = latched
        levelView?.status = latched ? "Listening — tap fn to stop" : "Listening…"
        levelView?.needsDisplay = true
    }

    func setStatus(_ text: String) {
        levelView?.status = text
        levelView?.needsDisplay = true
    }

    func update(level: Float) {
        levelView?.level = level
        levelView?.needsDisplay = true
    }

    func hide() {
        window?.orderOut(nil)
        levelView?.level = 0
    }

    private func build() {
        let view = LevelView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        window = panel
        levelView = view
    }

    private func reposition() {
        guard let window else { return }
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let frame = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96
        ))
    }
}

/// Rounded pill with a live level bar.
private final class LevelView: NSView {
    var level: Float = 0
    var latched = false
    var status = "Listening…"

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let body = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14)

        ctx.saveGState()
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        ctx.restoreGState()

        // Status text
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(x: body.minX, y: body.minY + 8, width: body.width, height: 16)
        (status as NSString).draw(in: textRect, withAttributes: attributes)

        // Level bar
        let track = NSRect(
            x: body.minX + 20,
            y: body.maxY - 20,
            width: body.width - 40,
            height: 6
        )
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()

        let width = max(6, CGFloat(min(max(level, 0), 1)) * track.width)
        let filled = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
        (latched ? NSColor.systemOrange : NSColor.systemGreen).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
    }
}
