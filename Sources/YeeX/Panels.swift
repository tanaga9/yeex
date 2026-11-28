import AppKit
import YeeXCore

@MainActor
final class DetailPanel: NSView {
    private let title: String
    private let content = NSStackView()
    private let document = PanelDocument()
    private let scroll = NSScrollView()

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        document.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12)
        ])
        document.translatesAutoresizingMaskIntoConstraints = false
        reset()
    }

    required init?(coder: NSCoder) { fatalError("Detail panels are created in code") }

    func reset() {
        for view in content.arrangedSubviews { view.removeFromSuperview() }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        add(label)
        scroll.contentView.scroll(to: .zero)
    }

    func add(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    func message(_ text: String) {
        reset()
        add(NSTextField(wrappingLabelWithString: text))
    }

    func show(_ data: ImageMetadata) {
        reset()
        let generator = data.fields["generator"].map { " · \($0)" } ?? ""
        let header = NSTextField(wrappingLabelWithString: "Format: \(data.format)\(generator)")
        header.textColor = .secondaryLabelColor
        add(header)
        guard !data.raw.isEmpty else { add(NSTextField(labelWithString: "No metadata found.")); return }

        let parameters = data.raw["parameters"]
        section("Parameters", text: parameters)
        let comfy = data.fields["generator"] == "ComfyUI" || data.promptJSON != nil || data.workflowJSON != nil
        if comfy {
            section("Prompt", text: data.fields["prompt"] == parameters ? nil : data.fields["prompt"])
            section("Negative Prompt", text: data.fields["negative_prompt"])
            section("Prompt JSON", text: data.promptJSON, monospaced: true)
            section("Workflow JSON", text: data.workflowJSON, monospaced: true)
        }
        if comfy || parameters == nil {
            section("Raw Metadata", text: data.raw.keys.sorted().map { "\($0)\n\(data.raw[$0]!)" }.joined(separator: "\n\n"))
        }
    }

    private func section(_ name: String, text: String?, monospaced: Bool = false) {
        guard let text, !text.isEmpty else { return }
        let heading = NSStackView()
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.addArrangedSubview(label)
        heading.addArrangedSubview(ActionButton(title: "Copy", size: .mini) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        add(heading)

        let field = NSTextField(wrappingLabelWithString: String(text.prefix(200_000)))
        field.isSelectable = true
        field.font = monospaced ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add(field)
        if text.count > 200_000 { add(NSTextField(wrappingLabelWithString: "Copy includes the full text.")) }
    }
}

@MainActor
private final class PanelDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ActionButton: NSButton {
    private let perform: () -> Void

    init(title: String, size: NSControl.ControlSize = .small, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        self.title = title
        controlSize = size
        bezelStyle = .rounded
        target = self
        action = #selector(performAction)
    }

    required init?(coder: NSCoder) { fatalError("Action buttons are created in code") }
    @objc private func performAction() { perform() }
}

@MainActor
extension Viewer {
    private func key(for mode: TransferMode) -> String { "\(mode.rawValue)Destinations" }

    private func destinations(_ mode: TransferMode) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key(for: mode)) as? [String: String] ?? [:]
    }

    private func setDestination(_ path: String?, slot: Int, mode: TransferMode) {
        var list = destinations(mode)
        list[String(slot)] = path
        UserDefaults.standard.set(list, forKey: key(for: mode))
        destinationsDidChange()
    }

    func refreshDestinations(_ panel: DetailPanel, mode: TransferMode) {
        panel.reset()
        let paths = destinations(mode)
        for slot in 1...9 {
            let row = NSStackView()
            row.spacing = 4
            let path = paths[String(slot)]
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Set destination…"
            let label = NSTextField(labelWithString: "\(slot)")
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            row.addArrangedSubview(label)
            let run = ActionButton(title: name) { [weak self] in
                self?.performTransfer(slot, mode: mode, configureOnly: true)
            }
            run.toolTip = path
            run.lineBreakMode = .byTruncatingTail
            run.setContentHuggingPriority(.defaultLow, for: .horizontal)
            run.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(run)
            let menu = NSMenu()
            let change = NSMenuItem(title: "Choose Folder…", action: #selector(destinationMenu(_:)), keyEquivalent: "")
            change.representedObject = [mode.rawValue, String(slot), "choose"]
            change.target = self
            menu.addItem(change)
            if path != nil {
                let clear = NSMenuItem(title: "Clear Destination", action: #selector(destinationMenu(_:)), keyEquivalent: "")
                clear.representedObject = [mode.rawValue, String(slot), "clear"]
                clear.target = self
                menu.addItem(clear)
            }
            panel.add(row)
            run.menu = menu
        }
    }

    @objc private func destinationMenu(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String], data.count == 3,
              let mode = TransferMode(rawValue: data[0]), let slot = Int(data[1]) else { return }
        if data[2] == "clear" { setDestination(nil, slot: slot, mode: mode) }
        else { chooseDestination(slot, mode: mode) { _ in } }
    }

    func handleTransferKey(_ event: NSEvent) -> Bool {
        let keySlots: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        guard let slot = keySlots[event.keyCode] else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command { performTransfer(slot, mode: .copy) }
        else if modifiers == .shift { performTransfer(slot, mode: .move) }
        else { return false }
        return true
    }

    private func chooseDestination(_ slot: Int, mode: TransferMode, selected: @escaping (URL) -> Void) {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = false
        dialog.canChooseDirectories = true
        dialog.canCreateDirectories = true
        dialog.message = "Choose \(mode.rawValue) destination \(slot)"
        if let window {
            dialog.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let self, let url = dialog.url else { return }
                setDestination(url.path, slot: slot, mode: mode)
                selected(url)
            }
        }
    }

    private func performTransfer(_ slot: Int, mode: TransferMode, configureOnly: Bool = false) {
        guard !transferInProgress else { return }
        let record = displayedRecord
        if let path = destinations(mode)[String(slot)] {
            if let record { transfer(record, directory: URL(fileURLWithPath: path, isDirectory: true), mode: mode) }
        } else {
            chooseDestination(slot, mode: mode) { [weak self] directory in
                guard let self, let record, !configureOnly else { return }
                transfer(record, directory: directory, mode: mode)
            }
        }
    }

    private func transfer(_ record: ImageRecord, directory: URL, mode: TransferMode) {
        transferInProgress = true
        Task { [weak self] in
            guard let self else { return }
            defer { transferInProgress = false }
            do {
                let collision = try await Task.detached(priority: .utility) {
                    try ImageTransfer.resolveCollision(record: record, directory: directory, mode: mode)
                }.value
                let choice: CollisionChoice
                switch collision {
                case .none:
                    choice = .fail
                case .existing(let existing):
                    let target = directory.appendingPathComponent(record.url.lastPathComponent)
                    guard let selected = await collisionChoice(target: target, existing: existing) else {
                        message("Transfer canceled")
                        return
                    }
                    choice = selected
                case .identical(let sourceTrashed):
                    if sourceTrashed { didMove(record) }
                    let title = sourceTrashed ? "Original moved to Trash" : (mode == .copy ? "Copy skipped" : "Move skipped")
                    notify(title, detail: "An identical file already exists at the destination.")
                    return
                }
                let result = try await Task.detached(priority: .utility) {
                    try ImageTransfer.run(record: record, directory: directory, mode: mode, collision: choice)
                }.value
                if mode == .move { didMove(record) }
                message("\(mode == .move ? "Moved" : "Copied") to \(result.path)")
            } catch let error as TransferError {
                switch error {
                case .recoveryRequired(let retained, _), .partialMove(_, let retained, _),
                     .replacementRecoveryRequired(let retained, _):
                    Self.showTransferRecovery(error, retained: retained)
                default:
                    message(error.localizedDescription)
                }
            } catch {
                message(error.localizedDescription)
            }
        }
    }

    private static func showTransferRecovery(_ error: TransferError, retained: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Transfer needs attention"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Close")
        NSApp.requestUserAttention(.criticalRequest)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([retained])
        }
    }

    private func collisionChoice(target: URL, existing: ExistingDestination) async -> CollisionChoice? {
        let preview = await Task.detached(priority: .utility) {
            Self.destinationPreview(at: target, existing: existing)
        }.value
        guard let window, window.isVisible else { return nil }
        let alert = NSAlert()
        alert.messageText = "A file named “\(target.lastPathComponent)” already exists."
        alert.informativeText = target.deletingLastPathComponent().path
        if let preview {
            alert.accessoryView = Self.previewView(for: preview)
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep Both")
        if !existing.isDirectory { alert.addButton(withTitle: "Replace") }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertSecondButtonReturn: continuation.resume(returning: .keepBoth)
                case .alertThirdButtonReturn: continuation.resume(returning: .replace(existing))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func destinationPreview(at target: URL, existing: ExistingDestination) -> CGImage? {
        guard !existing.isDirectory, ImageTransfer.existingDestination(at: target) == existing,
              (try? FolderScanner.record(at: target, seed: UUID())) != nil else { return nil }

        let resolved = target.resolvingSymlinksInPath()
        let contents = ImageTransfer.existingDestination(at: resolved)
        var preview = ImageDecoder.thumbnail(target, maxPixelSize: 384)?.image
        if preview == nil, ["wbmp", "xbm", "xpm"].contains(target.pathExtension.lowercased()),
           let image = ImageDecoder.decode(target)?.image {
            preview = ImagePipeline.thumbnail(from: image)
        }

        guard ImageTransfer.existingDestination(at: target) == existing,
              ImageTransfer.existingDestination(at: resolved) == contents else { return nil }
        return preview
    }

    private static func previewView(for image: CGImage) -> NSView {
        let preview = NSImageView(frame: CGRect(x: 0, y: 0, width: 192, height: 192))
        preview.image = NSImage(cgImage: image, size: .zero)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignLeft

        let label = NSTextField(labelWithString: "Existing image")
        label.frame = CGRect(x: 0, y: preview.frame.maxY + 6, width: preview.frame.width, height: 17)

        let view = NSView(frame: CGRect(x: 0, y: 0, width: label.frame.width, height: label.frame.maxY))
        view.addSubview(label)
        view.addSubview(preview)
        return view
    }
}
