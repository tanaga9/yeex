import AppKit

@MainActor
final class WindowNotifications: NSStackView {
    private var pending: [(title: String, detail: String, expiresAt: ContinuousClock.Instant)] = []
    private let clock = ContinuousClock()
    private let visibleLimit = 3
    private let fadeOutDuration: TimeInterval = 0.22

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        spacing = 8
    }

    required init?(coder: NSCoder) { fatalError("WindowNotifications is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func post(_ title: String, detail: String) {
        pending.append((title, detail, clock.now + .seconds(3)))
        showPending()
    }

    func clear() {
        pending.removeAll()
        for banner in arrangedSubviews { banner.removeFromSuperview() }
    }

    private func showPending() {
        while arrangedSubviews.count < visibleLimit, !pending.isEmpty {
            let notice = pending.removeFirst()
            let now = clock.now
            guard notice.expiresAt > now else { continue }
            let fadeStart = notice.expiresAt - .seconds(fadeOutDuration)
            let animate = now < fadeStart && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let banner = makeBanner(title: notice.title, detail: notice.detail)
            banner.alphaValue = animate ? 0 : 1
            addArrangedSubview(banner)
            if animate { fade(banner, to: 1, duration: 0.16) }
            NSAccessibility.post(element: banner, notification: .announcementRequested, userInfo: [
                .announcement: "\(notice.title). \(notice.detail)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])

            Task { [weak self, weak banner, clock] in
                try? await clock.sleep(until: animate ? fadeStart : notice.expiresAt)
                guard let self, let banner, banner.superview === self else { return }
                if animate, clock.now < notice.expiresAt {
                    fade(banner, to: 0, duration: fadeOutDuration)
                    try? await clock.sleep(until: notice.expiresAt)
                    guard banner.superview === self else { return }
                }
                banner.removeFromSuperview()
                showPending()
            }
        }
    }

    private func fade(_ banner: NSView, to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            banner.animator().alphaValue = alpha
        }
    }

    private func makeBanner(title: String, detail: String) -> NSView {
        let banner = NSVisualEffectView()
        banner.material = .popover
        banner.blendingMode = .withinWindow
        banner.state = .active
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 14
        banner.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let caption = NSTextField(wrappingLabelWithString: detail)
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        let text = NSStackView(views: [heading, caption])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [icon, text])
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            caption.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            row.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: banner.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -11)
        ])
        return banner
    }
}
