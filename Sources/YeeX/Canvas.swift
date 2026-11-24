import AppKit
import YeeXCore

@MainActor
final class Canvas: NSView {
    weak var controller: Viewer?
    private(set) var image: CGImage?
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var scrolling = SIMD2<Double>(repeating: 0)
    private var lastNavigation = ProcessInfo.processInfo.systemUptime
    private var decayTimer: Timer?

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("Canvas is created in code") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var naturalSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    private var fittedScale: CGFloat {
        guard image != nil, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / naturalSize.width, bounds.height / naturalSize.height)
    }

    private var displayedSize: CGSize {
        CGSize(width: naturalSize.width * fittedScale * zoom, height: naturalSize.height * fittedScale * zoom)
    }

    private var imageRect: CGRect {
        let size = displayedSize
        return CGRect(x: bounds.midX - size.width / 2 + pan.x, y: bounds.midY - size.height / 2 + pan.y,
                      width: size.width, height: size.height)
    }

    func show(_ image: CGImage?, reset: Bool) {
        self.image = image
        if reset { fit() }
        needsDisplay = true
    }

    func fit() {
        zoom = 1
        pan = .zero
        needsDisplay = true
    }

    func actualSize() {
        guard image != nil else { return }
        scale(by: 1 / (fittedScale * zoom * (window?.backingScaleFactor ?? 1)))
    }

    func scale(by factor: CGFloat, around anchor: CGPoint? = nil) {
        guard image != nil else { return }
        let before = imageRect
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        zoom = min(128, max(0.05, zoom * factor))
        let after = displayedSize
        pan.x = anchor.x - bounds.midX - ((anchor.x - before.midX) / before.width) * after.width
        pan.y = anchor.y - bounds.midY - ((anchor.y - before.midY) / before.height) * after.height
        clampPan()
        needsDisplay = true
    }

    private func clampPan() {
        let size = displayedSize
        let x = max(0, (size.width - bounds.width) / 2)
        let y = max(0, (size.height - bounds.height) / 2)
        pan.x = min(x, max(-x, pan.x))
        pan.y = min(y, max(-y, pan.y))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampPan()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.105, alpha: 1).setFill()
        dirtyRect.fill()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            context.interpolationQuality = .high
            context.draw(image, in: imageRect)
        } else {
            let hint = controller?.emptyMessage ?? "Open an image or folder"
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(white: 0.72, alpha: 1), .font: NSFont.systemFont(ofSize: 15)
            ]
            let size = (hint as NSString).size(withAttributes: attributes)
            (hint as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                    withAttributes: attributes)
        }
        drawGauge(vertical: true, value: scrolling.y)
        drawGauge(vertical: false, value: scrolling.x)
    }

    private func drawGauge(vertical: Bool, value: Double) {
        guard value != 0 else { return }
        let length = min(90, abs(value) / 100 * 90)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        let rect = vertical
            ? CGRect(x: 3, y: bounds.midY + (value > 0 ? 0 : -length), width: 4, height: length)
            : CGRect(x: bounds.midX + (value > 0 ? -length : 0), y: bounds.maxY - 7, width: length, height: 4)
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        if controller.handleTransferKey(event) { return }
        switch event.keyCode {
        case 126: controller.navigate(vertical: true, forward: true)
        case 125: controller.navigate(vertical: true, forward: false)
        case 123: controller.navigate(vertical: false, forward: true)
        case 124: controller.navigate(vertical: false, forward: false)
        default:
            switch event.charactersIgnoringModifiers {
            case "=", "+": scale(by: 1.25)
            case "-": scale(by: 0.8)
            default: super.keyDown(with: event)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        let dx = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 40)
        let dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 40)
        guard dx != 0 || dy != 0 else { return }
        let vertical = abs(dy) >= abs(dx)
        let size = displayedSize
        if vertical ? size.height > bounds.height + 0.5 : size.width > bounds.width + 0.5 {
            if vertical { pan.y += dy } else { pan.x += dx }
            clampPan()
            needsDisplay = true
            return
        }

        let free = controller.freeScroll
        let axis = vertical ? 1 : 0
        let amount = vertical ? dy : dx
        let sensitivity = vertical ? 2.5 : (free ? 0.5 : 0.8)
        let limit = free ? 1000.0 : (vertical ? 120.0 : 100.0)
        let threshold = vertical || free ? 100.0 : 80.0
        if amount * scrolling[axis] < 0 { scrolling[axis] = 0 }
        scrolling[axis] = max(-limit, min(limit, scrolling[axis] + amount * sensitivity))
        let now = ProcessInfo.processInfo.systemUptime
        if abs(scrolling[axis]) >= threshold, free || now - lastNavigation > 0.2 {
            controller.navigate(vertical: vertical, forward: scrolling[axis] > 0)
            scrolling[axis] /= free ? 1.1 : (vertical ? 100 : 2)
            lastNavigation = now
        }
        if decayTimer == nil {
            let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(decay), userInfo: nil, repeats: true)
            decayTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        needsDisplay = true
    }

    @objc private func decay() {
        scrolling.x *= controller?.freeScroll == true ? 0.9 : 0.5
        scrolling.y *= 0.7
        for axis in 0..<2 where abs(scrolling[axis]) < 1 { scrolling[axis] = 0 }
        if scrolling == .zero { stopScrollDecay() }
        needsDisplay = true
    }

    func stopScrollDecay() {
        decayTimer?.invalidate()
        decayTimer = nil
    }

    override func magnify(with event: NSEvent) {
        scale(by: max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { controller?.fitWindow(); return }
        let size = displayedSize
        if size.width <= bounds.width + 0.5, size.height <= bounds.height + 0.5 {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        pan.x += event.deltaX
        pan.y -= event.deltaY
        clampPan()
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(Viewer.reveal), keyEquivalent: "").target = controller
        menu.addItem(withTitle: "Info", action: #selector(Viewer.toggleInfo), keyEquivalent: "").target = controller
        return menu
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = dropURLs(sender)
        guard let controller, let first = urls.first else { return false }
        controller.open(first)
        for url in urls.dropFirst() { (NSApp.delegate as? Application)?.newViewer(opening: url) }
        return true
    }

    private func dropURLs(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
