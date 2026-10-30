import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let prefs: Preferences
    private let openSettings: () -> Void

    init(prefs: Preferences, openSettings: @escaping () -> Void) {
        self.prefs = prefs
        self.openSettings = openSettings
        super.init()
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "MissionControlEnhance")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Permissions.isAccessibilityTrusted {
            menu.addItem(action(String(localized: "⚠️ Accessibility Permission Required…"), #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        let enabled = action(String(localized: "Enabled"), #selector(toggleEnabled))
        enabled.state = prefs.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(action(String(localized: "Settings…"), #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Quit"), #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { prefs.enabled.toggle() }
    @objc private func showSettings() { openSettings() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
