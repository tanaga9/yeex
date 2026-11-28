import AppKit
import YeeXCore

@MainActor
final class CoverFlowStrip: NSView {
    static let neighborsPerSide = 3
    private static let scrollStep: CGFloat = 46

    let orientation: NSUserInterfaceLayoutOrientation
    var selectImage: ((String) -> Void)?
    var step: ((Bool) -> Void)?
    private var records: [Int: ImageRecord] = [:]
    private var visibleRecords: [Int: ImageRecord] = [:]
    private var centerThumbnail: CGImage?
    private var tiles: [String: CoverTile] = [:]
    private var loading: Task<Void, Never>?
    private let scrollNavigation = ScrollNavigation(isFree: { true })
    private var scrollTravel: CGFloat = 0
    private var lastScrollTimestamp: TimeInterval?

    init(orientation: NSUserInterfaceLayoutOrientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        clipsToBounds = true
        setContentHuggingPriority(.required, for: orientation == .vertical ? .horizontal : .vertical)
        setContentCompressionResistancePriority(.required, for: orientation == .vertical ? .horizontal : .vertical)
    }

    required init?(coder: NSCoder) { fatalError("Cover Flow strips are created in code") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            scrollNavigation.stopDecay()
            scrollTravel = 0
            lastScrollTimestamp = nil
        }
    }

    override var intrinsicContentSize: NSSize {
        orientation == .vertical
            ? NSSize(width: 86, height: NSView.noIntrinsicMetric)
            : NSSize(width: NSView.noIntrinsicMetric, height: 86)
    }

    private let centerSize = NSSize(width: 76, height: 70)
    private let minimumGap: CGFloat = 1
    private var vertical: Bool { orientation == .vertical }
    private var sideSize: NSSize { vertical ? NSSize(width: 64, height: 48) : NSSize(width: 50, height: 54) }
    private var sideSpan: CGFloat { length(sideSize) }
    private var roomPerSide: CGFloat { max(0, (length(bounds.size) - length(centerSize)) / 2) }

    private var visibleNeighbors: Int {
        min(Self.neighborsPerSide, Int(roomPerSide / (sideSpan + minimumGap)))
    }

    private func length(_ size: NSSize) -> CGFloat { vertical ? size.height : size.width }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.125, alpha: 1).setFill()
        dirtyRect.intersection(bounds).fill()
        NSColor(white: 1, alpha: 0.09).setFill()
        let edge = orientation == .vertical
            ? NSRect(x: bounds.minX, y: 0, width: 1, height: bounds.height)
            : NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
        edge.fill()
    }

    func show(_ newRecords: [Int: ImageRecord], centerThumbnail: CGImage? = nil) {
        let centerChanged = self.centerThumbnail !== centerThumbnail
        guard records != newRecords || centerChanged else { return }
        records = newRecords
        self.centerThumbnail = centerThumbnail
        refreshTiles()
        if centerChanged, let center = records[0] {
            tiles[center.id]?.setThumbnail(centerThumbnail)
        }
    }

    private func refreshTiles() {
        let limit = visibleNeighbors
        let next = records.filter { abs($0.key) <= limit }
        guard next != visibleRecords else { return }
        let selectionChanged = visibleRecords[0]?.id != next[0]?.id
        visibleRecords = next
        let visible = Set(next.values.map(\.id))
        for id in tiles.keys.filter({ !visible.contains($0) }) {
            tiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (offset, record) in next {
            let tile: CoverTile
            if let existing = tiles[record.id] {
                tile = existing
            } else {
                tile = CoverTile(record: record, vertical: vertical,
                                 target: self, action: #selector(choose(_:)))
                tiles[record.id] = tile
                addSubview(tile)
            }
            tile.update(record, offset: offset)
            if offset == 0 { tile.setThumbnail(centerThumbnail) }
        }
        placeTiles(animated: selectionChanged && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        loading?.cancel()
        let pending = next.sorted { abs($0.key) < abs($1.key) }.compactMap { offset, record in
            offset != 0 && tiles[record.id]?.needsThumbnail == true ? record : nil
        }
        guard !pending.isEmpty else { loading = nil; return }
        loading = Task(priority: .utility) { [weak self] in
            for record in pending {
                guard !Task.isCancelled else { return }
                let image = await ImagePipeline.thumbnail(record)
                guard !Task.isCancelled else { return }
                if let tile = self?.tiles[record.id], tile.record == record {
                    tile.setThumbnail(image)
                }
            }
        }
    }

    override func layout() {
        super.layout()
        refreshTiles()
        placeTiles(animated: false)
    }

    private func placeTiles(animated: Bool) {
        let gap = min(12, max(minimumGap, roomPerSide / CGFloat(max(1, visibleNeighbors)) - sideSpan))
        let pitch = sideSpan + gap
        let centerInset = (length(centerSize) - sideSpan) / 2
        for (offset, record) in visibleRecords {
            guard let tile = tiles[record.id] else { continue }
            let size = offset == 0 ? centerSize : sideSize
            let distance = CGFloat(offset) * pitch + CGFloat(offset.signum()) * centerInset
            let x = bounds.midX + (vertical ? 0 : distance) - size.width / 2
            let y = bounds.midY - (vertical ? distance : 0) - size.height / 2
            let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            let previous = tile.frame
            tile.frame = frame
            if animated, !previous.isEmpty, previous != frame {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: previous.midX - frame.midX, y: previous.midY - frame.midY))
                slide.toValue = NSValue(point: .zero)
                slide.duration = 0.16
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                tile.layer?.add(slide, forKey: "coverSlide")
            }
        }
    }

    @objc private func choose(_ sender: CoverTile) {
        selectImage?(sender.record.id)
    }

    func scrollImages(with event: NSEvent) {
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled) {
            scrollNavigation.stopDecay()
            scrollTravel = 0
            lastScrollTimestamp = nil
            return
        }
        if event.phase.contains(.began) { scrollTravel = 0 }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let input = vertical || abs(dy) > abs(dx) ? dy : dx
        guard input != 0 else { return }

        // Unphased inputs have no gesture start, so a pause separates bursts.
        let timestamp = ProcessInfo.processInfo.systemUptime
        if event.phase.isEmpty, event.momentumPhase.isEmpty,
           let lastScrollTimestamp, timestamp - lastScrollTimestamp > 0.25 {
            scrollTravel = 0
        }
        lastScrollTimestamp = timestamp
        let delta = event.hasPreciseScrollingDeltas ? input : (input > 0 ? Self.scrollStep : -Self.scrollStep)
        if delta * scrollTravel < 0 { scrollTravel = 0 }
        scrollTravel += delta
        let travelReachedStep = abs(scrollTravel) >= Self.scrollStep
        guard let forward = scrollNavigation.accumulate(delta, vertical: vertical, inputPerStep: Self.scrollStep,
                                                         travelReachedStep: travelReachedStep) else { return }
        scrollTravel = travelReachedStep ? scrollTravel.truncatingRemainder(dividingBy: Self.scrollStep) : 0
        step?(forward)
    }
}

@MainActor
private final class CoverTile: NSButton {
    private static let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    private let artwork = CALayer()
    private let picture = CALayer()
    private let vertical: Bool
    private var offset = 0
    private(set) var record: ImageRecord
    private(set) var needsThumbnail = true

    init(record: ImageRecord, vertical: Bool, target: AnyObject, action: Selector) {
        self.record = record
        self.vertical = vertical
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        wantsLayer = true
        toolTip = record.name
        setAccessibilityLabel(record.name)
        artwork.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        artwork.cornerRadius = 5
        artwork.borderWidth = 1
        picture.contentsGravity = .resizeAspect
        artwork.addSublayer(picture)
        layer?.addSublayer(artwork)
        setThumbnail(nil)
        needsThumbnail = true
    }

    required init?(coder: NSCoder) { fatalError("Cover tiles are created in code") }

    func update(_ record: ImageRecord, offset: Int) {
        if self.record != record {
            self.record = record
            toolTip = record.name
            setAccessibilityLabel(record.name)
            setThumbnail(nil)
            needsThumbnail = true
        }
        self.offset = offset
        setAccessibilityValue(offset == 0 ? "Selected" : nil)
        needsLayout = true
    }

    func setThumbnail(_ image: CGImage?) {
        needsThumbnail = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image ?? Self.placeholder?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        picture.opacity = image == nil ? 0.33 : 1
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let selected = offset == 0
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 240
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.bounds = bounds.insetBy(dx: 2, dy: 2)
        artwork.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle = offset < 0 ? 0.53 : -0.53
        artwork.transform = selected ? CATransform3DIdentity : vertical
            ? CATransform3DRotate(perspective, angle, 1, 0, 0)
            : CATransform3DRotate(perspective, angle, 0, 1, 0)
        artwork.borderColor = (selected ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.14)).cgColor
        artwork.borderWidth = selected ? 2 : 1
        picture.frame = artwork.bounds.insetBy(dx: picture.opacity < 1 ? 15 : 4, dy: picture.opacity < 1 ? 16 : 4)
        CATransaction.commit()
    }
}
