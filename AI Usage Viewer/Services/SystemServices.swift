// SystemServices.swift
// AI Usage Viewer
//
// Small wrappers around macOS services: wake/lock/network events,
// notifications and launch-at-login.

import AppKit
import Network
import ServiceManagement
import UserNotifications

@MainActor
final class SystemMonitor {
    // Asleep or screen locked: no point spending API calls nobody will see.
    private(set) var isIdle = false
    var onActive: () -> Void = {}

    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isIdle = true }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isIdle = true }
        })
        tokens.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })

        pathMonitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "SystemMonitor.network"))
    }

    private func becameActive() {
        isIdle = false
        onActive()
    }

    private func networkChanged(up: Bool) {
        if !up { networkWasDown = true; return }
        if networkWasDown { networkWasDown = false; onActive() }
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    func start() {
        center.delegate = self
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func perform(_ actions: [AlertAction]) {
        for action in actions {
            let content = UNMutableNotificationContent()
            content.sound = .default
            let trigger: UNNotificationTrigger?
            switch action {
            case .deliver(_, let title, let body):
                content.title = title; content.body = body; trigger = nil
            case .schedule(_, let at, let title, let body):
                content.title = title; content.body = body
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
            case .markFired:
                continue
            }
            center.add(UNNotificationRequest(identifier: action.id, content: content, trigger: trigger))
        }
    }

    func cancelScheduledResets() {
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("reset|") }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // Menu-bar apps are always "in the foreground"; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        UserDefaults.standard.set(Bundle.main.bundlePath, forKey: pathKey)
    }

    // The login item points at the app where it was registered. After the
    // app is renamed or moved (as in Claude Usage Viewer → AI Usage
    // Viewer), register it again from where it now lives if it was on.
    // An entry whose app is gone reports `.notFound`; one you turned off
    // reports `.notRegistered` and is left alone.
    static func followAppIfMoved() {
        let defaults = UserDefaults.standard
        let here = Bundle.main.bundlePath
        guard defaults.string(forKey: pathKey) != here else { return }
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .notFound {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }
        defaults.set(here, forKey: pathKey)
    }

    private static let pathKey = "loginItemPath"
}
