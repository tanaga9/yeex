import AppKit
import os
import YeeXCore

private let imagePipeline = ImagePipeline()
private let metadataQueue = DispatchQueue(label: "YeeX metadata", qos: .utility)

@MainActor
final class Viewer: NSWindowController, NSWindowDelegate {
    private let canvas = Canvas()
    private let horizontalCoverFlow = CoverFlowStrip(orientation: .horizontal)
    private let verticalCoverFlow = CoverFlowStrip(orientation: .vertical)
    private let root = NSStackView()
    private let body = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let countStatus = NSTextField(labelWithString: "")
    private let rateStatus = NSTextField(labelWithString: "")
    private let info = DetailPanel(title: "Info")
    private let copy = DetailPanel(title: "Copy Destinations")
    private let move = DetailPanel(title: "Move Destinations")

    private var catalog = Catalog()
    private var folder: URL?
    private let seed = UUID()
    private var vertical: BrowseOrder = .mtime
    private var horizontal: BrowseOrder = .random
    private var loop = false
    private(set) var freeScroll = false
    private var polling = false
    private var folderWork = FolderWork()
    private var imageWork = ImageWork()
    private let pendingMetadata = OSAllocatedUnfairLock<MetadataRequest?>(initialState: nil)
    private var metadataID: UUID?
    private var metadataWorker: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var scanned = Set<String>()
    private var refreshAfterScan: String?
    private var failedDecodes: [String: ImageRecord] = [:]
    private var movedDuringScan = Set<String>()
    private var current: ImageRecord?
    private var coverFlowThumbnail: CGImage?
    private var intended: String?
    private var displayTimes: [TimeInterval] = []
    private var statusReset: Task<Void, Never>?
    private var isClosed = false
    var isEmpty: Bool { folder == nil && opening == nil }
    var emptyMessage = "Open an image or folder"
    var transferInProgress = false
    var displayedRecord: ImageRecord? { current }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "YeeX"
        window.titleVisibility = .visible
        window.minSize = CGSize(width: 560, height: 360)
        window.tabbingMode = .disallowed
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameUsingName("YeeX Viewer")
        window.styleMask.remove(.fullSizeContentView)
        buildInterface(window)
    }

    required init?(coder: NSCoder) { fatalError("Viewer is created in code") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(canvas)
    }

    private func buildInterface(_ window: NSWindow) {
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        body.orientation = .horizontal
        body.alignment = .height
        body.spacing = 0
        let canvasColumn = NSStackView(views: [canvas, horizontalCoverFlow])
        canvasColumn.orientation = .vertical
        canvasColumn.alignment = .width
        canvasColumn.spacing = 0
        canvasColumn.detachesHiddenViews = true
        canvasColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        canvasColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let imageArea = NSStackView(views: [verticalCoverFlow, canvasColumn])
        imageArea.orientation = .horizontal
        imageArea.alignment = .height
        imageArea.spacing = 0
        imageArea.detachesHiddenViews = true
        imageArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageArea.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for strip in [horizontalCoverFlow, verticalCoverFlow] {
            let vertical = strip.orientation == .vertical
            strip.selectImage = { [weak self] id in self?.selectCoverFlowImage(id) }
            strip.step = { [weak self] forward in self?.navigate(vertical: vertical, forward: forward) }
        }
        body.addArrangedSubview(imageArea)
        canvas.controller = self
        canvas.setContentHuggingPriority(.defaultLow, for: .horizontal)
        canvas.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for panel in [info, copy, move] {
            body.addArrangedSubview(panel)
            panel.isHidden = true
            panel.widthAnchor.constraint(equalToConstant: panel === info ? 295 : 230).isActive = true
        }

        let toolbar = NSToolbar(identifier: "YeeX Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.allowsDisplayModeCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        migrateWatchToolbarItem(in: toolbar)

        let footer = NSStackView()
        footer.spacing = 14
        footer.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        for label in [status, rateStatus, countStatus] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            footer.addArrangedSubview(label)
        }
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [rateStatus, countStatus] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        root.addArrangedSubview(body)
        root.addArrangedSubview(NSBox.separator())
        root.addArrangedSubview(footer)
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = root
        window.initialFirstResponder = canvas
        updateStatus()
    }

    @objc func cycleVertical() {
        vertical = vertical.toggled(excluding: horizontal)
        refreshToolbarItem("vertical")
        refreshCoverFlow(verticalCoverFlow)
        prefetch()
    }

    @objc func cycleHorizontal() {
        horizontal = horizontal.toggled(excluding: vertical)
        refreshToolbarItem("horizontal")
        refreshCoverFlow(horizontalCoverFlow)
        prefetch()
    }

    @objc func toggleLoop() {
        loop.toggle()
        refreshToolbarItem("loop")
        refreshCoverFlow()
        prefetch()
    }

    @objc func toggleFreeScroll() {
        freeScroll.toggle()
        refreshToolbarItem("free")
    }

    @objc func togglePolling() {
        polling.toggle()
        refreshToolbarItem("poll")
        updatePolling()
    }

    @objc func toggleHorizontalCoverFlow() { toggleCoverFlow(horizontalCoverFlow) }
    @objc func toggleVerticalCoverFlow() { toggleCoverFlow(verticalCoverFlow) }

    private func toggleCoverFlow(_ strip: CoverFlowStrip) {
        strip.isHidden.toggle()
        if strip.isHidden { strip.show([:]) }
        else { refreshCoverFlow(strip) }
        window?.makeFirstResponder(canvas)
    }

    private func refreshCoverFlow() {
        refreshCoverFlow(horizontalCoverFlow)
        refreshCoverFlow(verticalCoverFlow)
    }

    private func refreshCoverFlow(_ strip: CoverFlowStrip) {
        guard !strip.isHidden else { return }
        guard let current else { strip.show([:]); return }
        if coverFlowThumbnail == nil, let image = canvas.image {
            coverFlowThumbnail = ImagePipeline.thumbnail(from: image)
        }
        let order = strip.orientation == .vertical ? vertical : horizontal
        var records = [0: current]
        var seen = Set([current.id])
        var previous = current.id
        var next = current.id
        for distance in 1...CoverFlowStrip.neighborsPerSide {
            if let id = catalog.neighbor(previous, order: order, forward: true, loop: loop),
               let record = catalog[id], seen.insert(id).inserted {
                records[-distance] = record
                previous = id
            }
            if let id = catalog.neighbor(next, order: order, forward: false, loop: loop),
               let record = catalog[id], seen.insert(id).inserted {
                records[distance] = record
                next = id
            }
        }
        strip.show(records, centerThumbnail: coverFlowThumbnail)
    }

    private func selectCoverFlowImage(_ id: String) {
        window?.makeFirstResponder(canvas)
        guard id != intended, let record = catalog[id] else { return }
        request(record, order: nil, forward: true)
    }

    @objc func fitImage() { canvas.fit() }
    @objc func actualSize() { canvas.actualSize() }
    @objc func reveal() {
        if let current { NSWorkspace.shared.activateFileViewerSelecting([current.url]) }
    }

    @objc func fitWindow() {
        guard let window, let screen = window.screen, let image = canvas.image else { return }
        let old = window.frame
        let work = screen.visibleFrame
        let extraW = max(0, old.width - canvas.bounds.width)
        let extraH = max(0, old.height - canvas.bounds.height)
        let scale = min((work.width - extraW) / CGFloat(image.width), (work.height - extraH) / CGFloat(image.height))
        guard scale > 0 else { return }
        let width = min(work.width, max(window.minSize.width, CGFloat(image.width) * scale + extraW))
        let height = min(work.height, max(window.minSize.height, CGFloat(image.height) * scale + extraH))
        let x = max(work.minX, min(old.midX - width / 2, work.maxX - width))
        let y = max(work.minY, min(old.maxY, work.maxY) - height)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        canvas.fit()
    }

    private func toggle(_ panel: DetailPanel) {
        let show = panel.isHidden
        for other in [info, copy, move] { other.isHidden = other !== panel || !show }
        refreshMetadata()
        if !copy.isHidden { refreshDestinations(copy, mode: .copy) }
        if !move.isHidden { refreshDestinations(move, mode: .move) }
        canvas.fit()
        window?.makeFirstResponder(canvas)
    }

    @objc func toggleInfo() { toggle(info) }
    @objc func toggleCopy() { toggle(copy) }
    @objc func toggleMove() { toggle(move) }

    func destinationsDidChange() {
        if !copy.isHidden { refreshDestinations(copy, mode: .copy) }
        if !move.isHidden { refreshDestinations(move, mode: .move) }
    }

    private func refreshMetadata() {
        pendingMetadata.withLock { $0 = nil }
        metadataID = nil
        guard !info.isHidden else { return }
        guard let record = current else { info.message("No image selected."); return }
        guard ImageMetadata.supports(record.url) else {
            info.message("Image metadata is unavailable for this image.")
            return
        }
        info.message("Reading metadata…")
        let request = MetadataRequest(url: record.url)
        metadataID = request.id
        pendingMetadata.withLock { $0 = request }
        guard metadataWorker == nil else { return }

        let pending = pendingMetadata
        metadataWorker = Task { [weak self] in
            while !Task.isCancelled {
                let completed: (UUID, Result<ImageMetadata, any Error>)? = await withCheckedContinuation { continuation in
                    metadataQueue.async {
                        let request = pending.withLock {
                            let request = $0
                            $0 = nil
                            return request
                        }
                        continuation.resume(returning: request.map { request in
                            (request.id, Result { try ImageMetadata.read(request.url) })
                        })
                    }
                }
                guard !Task.isCancelled, let self else { return }
                if let (id, result) = completed, id == metadataID {
                    switch result {
                    case .success(let metadata): info.show(metadata)
                    case .failure(let error): info.message(error.localizedDescription)
                    }
                }
                if pending.withLock({ $0 == nil }) {
                    metadataWorker = nil
                    return
                }
            }
        }
    }

    func chooseFile() { choose(directory: false) }
    func chooseFolder() { choose(directory: true) }
    private func choose(directory: Bool) {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = !directory
        dialog.canChooseDirectories = directory
        dialog.allowsMultipleSelection = false
        dialog.treatsFilePackagesAsDirectories = false
        dialog.directoryURL = folder
        if let window {
            dialog.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = dialog.url { self?.open(url) }
            }
        }
    }

    func open(_ url: URL) {
        guard !isClosed else { return }
        cancel(&opening)
        let seed = self.seed
        opening = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { OpenTarget.resolve(url, seed: seed) }
            let target = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self else { return }
            defer { if !Task.isCancelled { opening = nil } }
            switch target {
            case .folder(let url):
                if folder == url { beginScan() }
                else { switchFolder(url) }
            case .image(let record, let parent):
                let decoded = await imagePipeline.image(record)
                guard !Task.isCancelled else { return }
                if let decoded {
                    if folder != parent { switchFolder(parent, initial: (record, decoded)) }
                    else {
                        presentExplicit(record, decoded: decoded)
                        if folderWork.scan == nil { beginScan(refreshCurrent: false) }
                    }
                } else { message("Unable to open \(record.name).") }
            case .failure(let text):
                message(text)
            }
        }
    }

    private func presentExplicit(_ record: ImageRecord, decoded: DecodedImage) {
        cancel(&loadTask)
        failedDecodes.removeValue(forKey: record.id)
        movedDuringScan.remove(record.id)
        catalog.upsert(record)
        display(record, decoded, continueForward: nil)
    }

    private func switchFolder(_ url: URL,
                              initial: (ImageRecord, DecodedImage)? = nil) {
        folderWork.end()
        cancel(&loadTask)
        intended = nil
        clearImage()
        folder = url
        catalog = Catalog()
        if let (record, decoded) = initial { presentExplicit(record, decoded: decoded) }
        beginScan(refreshCurrent: false)
    }

    @objc func reload() {
        guard !isClosed, folder != nil else { return }
        folderWork.reloadPending = true
        if folderWork.scan == nil { beginScan() }
    }

    private func beginScan(refreshCurrent: Bool = true) {
        guard !isClosed, let folder else { return }
        let invalidateCache = folderWork.reloadPending
        folderWork.reloadPending = false
        refreshAfterScan = refreshCurrent ? current?.id : nil
        let generation = folderWork.startScan()
        let seed = self.seed
        scanned.removeAll(keepingCapacity: true)
        failedDecodes.removeAll(keepingCapacity: true)
        movedDuringScan.removeAll(keepingCapacity: true)
        emptyMessage = "Scanning folder…"
        canvas.needsDisplay = true
        message("Scanning \(folder.lastPathComponent)…", persistent: true)
        updateStatus()

        let needsWatch = folderWork.watch == nil
        folderWork.scan = Task.detached(priority: .utility) { [weak self] in
            if needsWatch {
                let fd = Darwin.open(folder.path, O_EVTONLY | O_CLOEXEC)
                if fd >= 0 {
                    if let self { await self.attachWatch(fd, generation: generation) }
                    else { Darwin.close(fd) }
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await FolderScanner.scan(folder, seed: seed) { [weak self] records in
                    await self?.publish(records, generation: generation)
                }
                try Task.checkCancellation()
                if invalidateCache { await imagePipeline.invalidateImages(in: folder) }
                await self?.finishScan(result, error: nil, generation: generation, cacheInvalidated: invalidateCache)
            } catch is CancellationError {
            } catch {
                await self?.finishScan(nil, error: error.localizedDescription, generation: generation)
            }
        }
    }

    private func attachWatch(_ fd: Int32, generation: UUID) {
        guard folderWork.generation == generation, folderWork.watch == nil else { Darwin.close(fd); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            MainActor.assumeIsolated { self?.folderChanged(source.data) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        folderWork.watch = source
        source.resume()
        updateStatus()
    }

    private func publish(_ records: [ImageRecord], generation: UUID) {
        guard generation == folderWork.generation else { return }
        for record in records {
            scanned.insert(record.id)
            if !movedDuringScan.contains(record.id), failedDecodes[record.id] != record {
                catalog.upsert(record)
            }
        }
        if current == nil, loadTask == nil { loadFirst() }
        updateStatus()
    }

    private func finishScan(_ result: ScanResult?, error: String?, generation: UUID,
                            cacheInvalidated: Bool = false) {
        guard generation == folderWork.generation else { return }
        folderWork.scan = nil
        let scanAgain = folderWork.observation.finish(result) || folderWork.reloadPending
        if result != nil {
            for id in Array(catalog.ids) where !scanned.contains(id) { catalog.remove(id) }
            if let current, catalog[current.id] == nil {
                if let intended, catalog[intended] != nil { clearImage() }
                else {
                    cancel(&loadTask)
                    intended = nil
                    clearImage()
                }
            }
            if cacheInvalidated {
                horizontalCoverFlow.show([:])
                verticalCoverFlow.show([:])
                let updated = [intended, current?.id].compactMap { $0.flatMap { catalog[$0] } }.first
                cancel(&loadTask)
                if let updated {
                    request(updated, order: nil, forward: true)
                } else {
                    intended = nil
                }
            } else if loadTask == nil, let current, let updated = catalog[current.id],
                      updated != current || (!scanAgain && current.id == refreshAfterScan) {
                request(updated, order: nil, forward: true, refresh: true)
            }
        }
        scanned.removeAll(keepingCapacity: true)
        refreshAfterScan = nil
        if scanAgain {
            beginScan()
            return
        }
        if loadTask == nil { prefetch() }
        if current == nil, loadTask == nil { loadFirst() }
        emptyMessage = error == nil ? "No readable images in this folder" : "Unable to scan this folder"
        canvas.needsDisplay = true
        if folderWork.observation.requiresReload {
            let reason = error.map { "Unable to finish folder scan: \($0)." } ?? "Unable to finish folder scan."
            message("\(reason) Use Reload Current Folder.", persistent: true)
        } else {
            message(error.map { "Unable to finish folder scan: \($0)" } ?? "Scan complete")
        }
        updatePolling()
    }

    private func folderChanged(_ events: DispatchSource.FileSystemEvent) {
        if !events.intersection([.delete, .rename, .revoke]).isEmpty {
            folderWork.stopWatching()
        }
        if folderWork.observation.changed() { beginScan() }
        else { updateStatus() }
    }

    private func updatePolling() {
        cancel(&folderWork.poll)
        if polling, let folder, !folderWork.observation.scanning, !folderWork.observation.requiresReload {
            let generation = folderWork.generation
            folderWork.poll = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    if let names = try? FolderScanner.candidateNames(in: folder),
                       await self?.comparePoll(names, generation: generation) != true { break }
                }
            }
        }
        updateStatus()
    }

    private func comparePoll(_ names: Set<String>, generation: UUID) -> Bool {
        guard folderWork.generation == generation, polling, !Task.isCancelled else { return false }
        switch folderWork.observation.poll(names) {
        case .keepPolling: return true
        case .scan: beginScan()
        case .requireReload:
            folderWork.poll = nil
            message("Use Reload Current Folder.", persistent: true)
            updateStatus()
        case .idle:
            folderWork.poll = nil
            message("Polling stopped")
            updateStatus()
        }
        return false
    }

    func navigate(vertical: Bool, forward: Bool) {
        let order = vertical ? self.vertical : horizontal
        guard let anchor = intended ?? current?.id,
              let id = catalog.neighbor(anchor, order: order, forward: forward, loop: loop),
              id != anchor, let record = catalog[id] else { return }
        request(record, order: order, forward: forward)
    }

    private func loadFirst() {
        if let id = catalog.first(.mtime), let record = catalog[id] {
            request(record, order: nil, forward: true)
        }
    }

    private func request(_ record: ImageRecord, order: BrowseOrder?, forward: Bool, refresh: Bool = false,
                         fallback: String? = nil) {
        cancel(&loadTask)
        cancel(&imageWork.prefetch)
        intended = record.id
        loadTask = Task { [weak self] in
            guard let self else { return }
            var candidate: ImageRecord? = record
            var forward = forward
            var fallback = fallback
            while let next = candidate {
                let image = await imagePipeline.image(next, refresh: refresh && next.id == record.id)
                guard !Task.isCancelled else { return }
                let latest = catalog[next.id]
                if let latest, latest != next {
                    candidate = latest
                    continue
                }
                if let image, latest != nil {
                    loadTask = nil
                    display(next, image, continueForward: order.map { ($0, forward) })
                    return
                }
                let currentID = current?.id
                let neighbor = order.flatMap { catalog.neighbor(next.id, order: $0, forward: forward, loop: loop) }
                if latest != nil { failedDecodes[next.id] = next }
                catalog.remove(next.id)
                if next.id == currentID { clearImage() }
                candidate = (order == nil && current == nil ? catalog.first(.mtime) : neighbor)
                    .flatMap { $0 == currentID ? nil : catalog[$0] }
                if candidate == nil, let other = fallback {
                    fallback = nil
                    forward.toggle()
                    candidate = catalog[other]
                }
                intended = candidate?.id
                updateStatus()
                if candidate != nil { await Task.yield() }
            }
            guard !Task.isCancelled else { return }
            intended = current?.id
            loadTask = nil
        }
    }

    private func display(_ record: ImageRecord, _ decoded: DecodedImage, continueForward: (BrowseOrder, Bool)?) {
        imageWork.end()
        current = record
        intended = record.id
        window?.title = "YeeX — \(record.url.lastPathComponent)"
        window?.representedURL = record.url
        canvas.show(decoded.image, reset: true)
        canvas.setAccessibilityLabel(record.url.lastPathComponent)
        coverFlowThumbnail = nil
        refreshCoverFlow()
        let now = ProcessInfo.processInfo.systemUptime
        displayTimes.removeAll { now - $0 > 1 }
        displayTimes.append(now)
        rateStatus.stringValue = "\(displayTimes.count) ips"
        startAnimation(record, decoded: decoded)
        refreshMetadata()
        prefetch(prioritizing: continueForward)
    }

    private func startAnimation(_ record: ImageRecord, decoded: DecodedImage) {
        guard decoded.frameCount > 1 else { return }
        imageWork.animation = Task { [weak self] in
            let playback = AnimationPlayback(url: record.url)
            var position = 0
            var completed = 0
            var delay = decoded.frameDelay
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                position += 1
                if position == decoded.frameCount {
                    position = 0
                    completed += 1
                    let limit = decoded.loopCount ?? 1
                    if limit > 0, completed >= limit { break }
                }
                guard let frame = await imagePipeline.image(record, frame: position, playback: playback), !Task.isCancelled,
                      let self, current?.id == record.id else { break }
                canvas.show(frame.image, reset: false)
                delay = frame.frameDelay
            }
        }
    }

    private func prefetch(prioritizing direction: (BrowseOrder, Bool)? = nil) {
        cancel(&imageWork.prefetch)
        guard let current else { return }
        var directions = [(vertical, true), (vertical, false), (horizontal, true), (horizontal, false)]
        if let direction { directions.insert(direction, at: 0) }
        var seen = Set([current.id])
        let candidates = directions.compactMap { order, forward -> ImageRecord? in
            guard let id = catalog.neighbor(current.id, order: order, forward: forward, loop: loop),
                  seen.insert(id).inserted else { return nil }
            return catalog[id]
        }
        imageWork.prefetch = Task(priority: .utility) {
            for record in candidates {
                guard !Task.isCancelled else { break }
                _ = await imagePipeline.image(record, prefetch: true)
            }
        }
    }

    private func clearImage() {
        imageWork.end()
        current = nil
        coverFlowThumbnail = nil
        window?.title = "YeeX"
        window?.representedURL = nil
        canvas.show(nil, reset: true)
        canvas.setAccessibilityLabel("Image viewer")
        refreshCoverFlow()
        refreshMetadata()
    }

    func didMove(_ record: ImageRecord) {
        guard !isClosed else { return }
        let down = catalog.neighbor(record.id, order: vertical, forward: false, loop: loop)
        let up = catalog.neighbor(record.id, order: vertical, forward: true, loop: loop)
        if folderWork.observation.scanning { movedDuringScan.insert(record.id) }
        catalog.remove(record.id)
        if current?.id == record.id {
            cancel(&loadTask)
            intended = nil
            clearImage()
            let target = down.flatMap { catalog[$0] } ?? up.flatMap { catalog[$0] }
            if let target {
                request(target, order: vertical, forward: target.id != down, fallback: target.id == down ? up : nil)
            }
        }
        updateStatus()
    }

    func message(_ text: String, persistent: Bool = false) {
        guard !isClosed else { return }
        cancel(&statusReset)
        status.stringValue = text
        if !persistent {
            statusReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                statusReset = nil
                status.stringValue = folderWork.observation.requiresReload ? "Use Reload Current Folder." : ""
            }
        }
    }

    private func updateStatus() {
        countStatus.stringValue = "Count: \(catalog.count)"
        refreshToolbarItem(Self.watchToolbarIdentifier.rawValue)
        refreshCoverFlow()
    }

    func saveFrame() { window?.saveFrame(usingName: "YeeX Viewer") }
    func windowDidResize(_ notification: Notification) { canvas.fit() }
    func windowWillClose(_ notification: Notification) {
        saveFrame()
        isClosed = true
        cancel(&opening)
        cancel(&loadTask)
        cancel(&statusReset)
        pendingMetadata.withLock { $0 = nil }
        cancel(&metadataWorker)
        imageWork.end()
        folderWork.end()
        horizontalCoverFlow.show([:])
        verticalCoverFlow.show([:])
        canvas.stopScrollDecay()
        (NSApp.delegate as? Application)?.didClose(self)
    }
}

private func cancel(_ task: inout Task<Void, Never>?) {
    task?.cancel()
    task = nil
}

private enum OpenTarget {
    case folder(URL)
    case image(ImageRecord, parent: URL)
    case failure(String)

    static func resolve(_ url: URL, seed: UUID) -> Self {
        let file = url.standardizedFileURL
        let resolved = file.resolvingSymlinksInPath()
        let directory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if directory && !ImageFormats.isPixelmator(file) { return .folder(resolved) }
        let name = file.lastPathComponent
        guard ImageFormats.accepts(file) else { return .failure("Unsupported file: \(name)") }
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let record = try? FolderScanner.record(at: parent.appendingPathComponent(name), seed: seed) else {
            return .failure("Unable to open \(name).")
        }
        return .image(record, parent: parent)
    }
}

private struct FolderWork {
    var scan: Task<Void, Never>?
    var poll: Task<Void, Never>?
    var watch: DispatchSourceFileSystemObject?
    var observation = FolderObservation()
    var reloadPending = false
    private(set) var generation = UUID()

    mutating func startScan() -> UUID {
        cancel(&scan)
        cancel(&poll)
        generation = UUID()
        observation.begin()
        return generation
    }

    mutating func end() {
        cancel(&scan)
        cancel(&poll)
        stopWatching()
        self = FolderWork()
    }

    mutating func stopWatching() {
        watch?.cancel()
        watch = nil
    }
}

private struct ImageWork {
    var animation: Task<Void, Never>?
    var prefetch: Task<Void, Never>?

    mutating func end() {
        cancel(&animation)
        cancel(&prefetch)
    }
}

private struct MetadataRequest: Sendable {
    let url: URL
    let id = UUID()
}

extension Viewer: NSToolbarDelegate {
    private static let watchToolbarIdentifier = NSToolbarItem.Identifier("watch")
    private static let watchToolbarMigrationKey = "YeeXWatchToolbarItemIntroduced"
    private static let watchToolbarPriority = NSToolbarItem.VisibilityPriority(
        rawValue: NSToolbarItem.VisibilityPriority.high.rawValue + 1
    )
    private static let toolbarItems = ["open", "reload", "copy", "move", "info", "fit", "vertical", "horizontal",
                                       "loop", "free", watchToolbarIdentifier.rawValue, "poll"]

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItems.map { NSToolbarItem.Identifier($0) }
    }

    private func migrateWatchToolbarItem(in toolbar: NSToolbar) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.watchToolbarMigrationKey) else { return }
        if !toolbar.itemIdentifiers.contains(Self.watchToolbarIdentifier),
           let index = toolbar.itemIdentifiers.firstIndex(of: NSToolbarItem.Identifier("poll")) {
            toolbar.insertItem(withItemIdentifier: Self.watchToolbarIdentifier, at: index)
        }
        defaults.set(true, forKey: Self.watchToolbarMigrationKey)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == Self.watchToolbarIdentifier {
            let indicator = NSTextField(labelWithString: "W● P● !")
            indicator.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            indicator.widthAnchor.constraint(equalToConstant: ceil(indicator.intrinsicContentSize.width)).isActive = true
            item.view = indicator
            item.paletteLabel = "Watch Status"
            item.isBordered = false
            item.autovalidates = false
            item.visibilityPriority = Self.watchToolbarPriority
            if flag {
                updateToolbarItem(item)
            } else {
                indicator.stringValue = "W○ P○"
                item.menuFormRepresentation = NSMenuItem(title: indicator.stringValue, action: nil, keyEquivalent: "")
            }
            return item
        }
        let command: (label: String, symbol: String, action: Selector, help: String?)
        switch id.rawValue {
        case "open": command = ("Open Folder", "folder", #selector(openFolderToolbar), nil)
        case "reload": command = ("Reload", "arrow.clockwise", #selector(reload), "Reload Current Folder")
        case "copy": command = ("Copy", "document.on.document", #selector(toggleCopy), "Show or Hide Copy Destinations")
        case "move": command = ("Move", "folder.badge.plus", #selector(toggleMove), "Show or Hide Move Destinations")
        case "info": command = ("Info", "info.circle", #selector(toggleInfo), nil)
        case "fit": command = ("Fit", "arrow.up.left.and.arrow.down.right", #selector(fitImage), "Fit Image to Window")
        case "vertical": command = ("V Sort", "arrow.up.and.down", #selector(cycleVertical), "Change Vertical Sort Order")
        case "horizontal": command = ("H Sort", "arrow.left.and.right", #selector(cycleHorizontal), "Change Horizontal Sort Order")
        case "loop": command = ("Loop", "repeat.circle", #selector(toggleLoop), nil)
        case "free": command = ("Free Scroll", "hand.draw", #selector(toggleFreeScroll), nil)
        case "poll": command = ("Poll", "eye", #selector(togglePolling), nil)
        default: return nil
        }
        item.label = command.label
        item.paletteLabel = command.label
        switch id.rawValue {
        case "vertical", "horizontal":
            item.possibleLabels = Set(BrowseOrder.allCases.map { sortToolbarLabel(item, order: $0) })
        case "loop", "free", "poll":
            item.possibleLabels = ["\(command.label): On", "\(command.label): Off"]
        default:
            break
        }
        let help = command.help ?? command.label
        item.toolTip = help
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: help)
        item.target = self
        item.action = command.action
        if id.rawValue == "poll" { item.visibilityPriority = Self.watchToolbarPriority }
        if flag {
            updateToolbarItem(item)
        }
        return item
    }

    private func refreshToolbarItem(_ identifier: String) {
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == identifier }) {
            updateToolbarItem(item)
        }
    }

    private func updateToolbarItem(_ item: NSToolbarItem) {
        switch item.itemIdentifier.rawValue {
        case Self.watchToolbarIdentifier.rawValue:
            let watching = folderWork.watch != nil
            let pollingNow = folderWork.poll != nil
            let needsReload = folderWork.observation.requiresReload && !folderWork.observation.scanning
            let watch = watching ? "Running" : "Stopped"
            let poll = pollingNow ? "Running" : (polling ? "Stopped" : "Off")
            let reload = needsReload ? "\nReload required. Use Reload Current Folder (⌘R)." : ""
            let details = "Watch: \(watch)\nPoll: \(poll)\(reload)"
            guard item.toolTip != details, let indicator = item.view as? NSTextField else { return }
            let watchMark = watching ? "●" : "○"
            let pollMark = pollingNow ? "●" : "○"
            indicator.stringValue = "W\(watchMark) P\(pollMark)\(needsReload ? " !" : "")"
            item.toolTip = details
            indicator.setAccessibilityLabel(details)
            item.menuFormRepresentation = NSMenuItem(title: indicator.stringValue, action: nil, keyEquivalent: "")
        case "vertical", "horizontal":
            let isVertical = item.itemIdentifier.rawValue == "vertical"
            let order = isVertical ? vertical : horizontal
            let direction = isVertical ? "Vertical" : "Horizontal"
            item.label = sortToolbarLabel(item, order: order)
            item.toolTip = "\(direction) Sort: \(order.sortName) — click to change order"
            item.visibilityPriority = .high
        case "loop":
            updateToolbarToggle(item, isOn: loop, symbol: loop ? "repeat.circle.fill" : "repeat.circle")
        case "free":
            updateToolbarToggle(item, isOn: freeScroll, symbol: freeScroll ? "hand.draw.fill" : "hand.draw")
        case "poll":
            updateToolbarToggle(item, isOn: polling, symbol: polling ? "eye.fill" : "eye")
        default:
            break
        }
    }

    private func sortToolbarLabel(_ item: NSToolbarItem, order: BrowseOrder) -> String {
        let axis = item.itemIdentifier.rawValue == "vertical" ? "V" : "H"
        return "\(axis): \(order.toolbarName)"
    }

    private func updateToolbarToggle(_ item: NSToolbarItem, isOn: Bool, symbol: String) {
        let label = item.paletteLabel
        item.label = "\(label): \(isOn ? "On" : "Off")"
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        let menuItem = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
        menuItem.target = self
        menuItem.state = isOn ? .on : .off
        item.menuFormRepresentation = menuItem
    }

    @objc private func openFolderToolbar() { chooseFolder() }
}

extension Viewer: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cycleVertical):
            menuItem.title = "Vertical Sort: \(vertical.sortName)"
        case #selector(cycleHorizontal):
            menuItem.title = "Horizontal Sort: \(horizontal.sortName)"
        case #selector(toggleLoop):
            menuItem.state = loop ? .on : .off
        case #selector(toggleFreeScroll):
            menuItem.state = freeScroll ? .on : .off
        case #selector(togglePolling):
            menuItem.state = polling ? .on : .off
        case #selector(toggleHorizontalCoverFlow):
            menuItem.state = horizontalCoverFlow.isHidden ? .off : .on
        case #selector(toggleVerticalCoverFlow):
            menuItem.state = verticalCoverFlow.isHidden ? .off : .on
        default:
            break
        }
        return !isClosed
    }
}

private extension BrowseOrder {
    var sortName: String { self == .mtime ? "Date Modified" : toolbarName }

    var toolbarName: String {
        switch self {
        case .mtime: "Date"
        case .random: "Random"
        case .fname: "Name"
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
