// AIUsageViewerApp.swift
// AI Usage Viewer
//
// A menu-bar app that shows your AI plan usage (Claude, Gemini through
// Antigravity, OpenAI through Codex) at a glance and warns you before you
// run out. See README.md for how data flows in.

import AppKit
import SwiftUI

@main
struct AIUsageViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppPaths.migrateLegacySupportDir()
        CommandLineActions.runIfRequested()
    }

    // The UI lives in an NSStatusItem owned by AppDelegate; SwiftUI just
    // needs one scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusController: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would add a second menu-bar item.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }

        let prefs = Preferences()
        let store = UsageStore(prefs: prefs)
        self.store = store
        store.start()

        let controller = StatusItemController(store: store) { [weak self] in self?.showSettings() }
        controller.start()
        statusController = controller

        if !prefs.didSetUpLoginItem {
            try? LoginItem.set(true)
            prefs.didSetUpLoginItem = true
        }
        LoginItem.followAppIfMoved()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.saveNow()
    }

    private func showSettings() {
        guard let store else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(prefs: store.prefs, store: store)))
            window.title = "AI Usage Viewer Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// `AI Usage Viewer --install-statusline-feed` (or --uninstall-…) for
// setting up live updates from a script, e.g. `make install-feed`.
enum CommandLineActions {
    static func runIfRequested() {
        let args = CommandLine.arguments
        let installer = AppPaths.statusLineInstaller
        let action: (() throws -> Void)?
        let done: String
        if args.contains("--install-statusline-feed") {
            action = installer.install
            done = "Live updates on: Claude Code's status line now feeds \(installer.feedURL.path)"
        } else if args.contains("--uninstall-statusline-feed") {
            action = installer.uninstall
            done = "Live updates off; previous status line restored."
        } else {
            return
        }
        do {
            try action?()
            print(done)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
