import AppKit

@main enum WallpaperHost {
    static func main() {
        let app = NSApplication.shared
        let delegate = HostDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class HostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "壁纸"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = name
        window.center()
        let button = NSButton(title: "打开墙纸设置", target: self, action: #selector(openSettings))
        button.frame = NSRect(x: 80, y: 40, width: 160, height: 32)
        window.contentView?.addSubview(button)
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu()
        submenu.addItem(withTitle: "退出\(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; NSApp.mainMenu = menu
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }
}
