import AppKit
import PaneModel
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, account: AccountSession, updates: UpdateStatus, profiles: ProfilesStore, app: AppActions, actions: SettingsActions) {
        let root = SettingsRoot(settings: settings, account: account, updates: updates, profiles: profiles, app: app, actions: actions)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = tr("Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PaneSettingsWindow")
        super.init(window: window)
        window.center()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
