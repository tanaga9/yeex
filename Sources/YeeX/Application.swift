import AppKit

@MainActor
final class Application: NSObject, NSApplicationDelegate {
    private var viewers: [Viewer] = []
    private var pending: [URL] = []
    private var ready = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenus()
        ready = true
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
        let urls = pending + arguments
        pending.removeAll()
        if urls.isEmpty { newViewer() }
        else { for url in urls { newViewer(opening: url) } }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard ready else { pending.append(contentsOf: urls); return }
        for url in urls {
            if viewers.count == 1, let viewer = viewers.first, viewer.isEmpty { viewer.open(url) }
            else { newViewer(opening: url) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { newViewer() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for viewer in viewers { viewer.saveFrame() }
    }

    @discardableResult
    func newViewer(opening url: URL? = nil) -> Viewer {
        let viewer = Viewer()
        if let previous = viewers.last?.window?.frame {
            viewer.window?.cascadeTopLeft(from: CGPoint(x: previous.minX, y: previous.maxY))
        }
        viewers.append(viewer)
        viewer.showWindow(nil)
        if let url { viewer.open(url) }
        return viewer
    }

    func didClose(_ viewer: Viewer) { viewers.removeAll { $0 === viewer } }

    @objc private func newWindow() { newViewer() }
    @objc private func chooseFile() {
        let viewer = (NSApp.keyWindow?.windowController as? Viewer) ?? newViewer()
        viewer.chooseFile()
    }
    @objc private func chooseFolder() {
        let viewer = (NSApp.keyWindow?.windowController as? Viewer) ?? newViewer()
        viewer.chooseFolder()
    }

    private func configureMenus() {
        let bar = NSMenu()
        func group(_ name: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: name)
            item.submenu = menu
            bar.addItem(item)
            return menu
        }
        let app = group("YeeX")
        app.addItem(withTitle: "About YeeX", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide YeeX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit YeeX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = group("File")
        file.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Open File…", action: #selector(chooseFile), keyEquivalent: "o").target = self
        let folder = file.addItem(withTitle: "Open Folder…", action: #selector(chooseFolder), keyEquivalent: "o")
        folder.target = self
        folder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(.separator())
        file.addItem(withTitle: "Reload Current Folder", action: #selector(Viewer.reload), keyEquivalent: "r")
        file.addItem(withTitle: "Reveal in Finder", action: #selector(Viewer.reveal), keyEquivalent: "")
        file.addItem(withTitle: "Copy Destinations", action: #selector(Viewer.toggleCopy), keyEquivalent: "")
        file.addItem(withTitle: "Move Destinations", action: #selector(Viewer.toggleMove), keyEquivalent: "")
        file.addItem(withTitle: "Info", action: #selector(Viewer.toggleInfo), keyEquivalent: "i")

        let edit = group("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        let view = group("View")
        view.addItem(withTitle: "Fit Image", action: #selector(Viewer.fitImage), keyEquivalent: "0")
        view.addItem(withTitle: "Actual Size", action: #selector(Viewer.actualSize), keyEquivalent: "1").keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Fit Window to Image", action: #selector(Viewer.fitWindow), keyEquivalent: "")
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        let window = group("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = bar
    }
}
