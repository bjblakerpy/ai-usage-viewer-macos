// SettingsView.swift
// AI Usage Viewer

import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var prefs: Preferences
    let store: UsageStore

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var feedError: String?
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $prefs.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LoginItem.set(on); loginError = nil } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section {
                Toggle("Warn when I'm on pace to hit a limit within the hour", isOn: $prefs.notifyProjection)
                Toggle("Alert at usage thresholds", isOn: $prefs.notifyThresholds)
                if prefs.notifyThresholds {
                    Stepper("First alert at \(prefs.thresholdLow)%", value: $prefs.thresholdLow, in: 50...(prefs.thresholdHigh - 1), step: 5)
                    Stepper("Second alert at \(prefs.thresholdHigh)%", value: $prefs.thresholdHigh, in: (prefs.thresholdLow + 1)...99, step: 1)
                }
                Toggle("Notify when a limit resets after heavy use", isOn: $prefs.notifyResets)
                    .onChange(of: prefs.notifyResets) { _, on in
                        if !on { store.notifier.cancelScheduledResets() }
                    }
                if notificationsDenied {
                    HStack {
                        Text("Notifications are turned off for this app.").foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                    .font(.caption)
                }
            } header: {
                Text("Notifications")
            }

            Section {
                feedStatus
                Text("Claude Code in a terminal hands your usage to its status line on every update. With live updates on, a small script saves it for this app, so the numbers move as you work without using Anthropic's usage-check limit. The desktop app's Code tab doesn't run status lines, so while you work there the app checks every 15 minutes instead. Any status line you already have keeps working, and removing this restores it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let feedError { Text(feedError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Live updates from Claude Code")
            }

            Section {
                Toggle("Track Gemini quota from Antigravity", isOn: $prefs.trackAntigravity)
                    .onChange(of: prefs.trackAntigravity) { _, on in
                        if on { Task { await store.refreshAntigravity() } }
                    }
                if prefs.trackAntigravity {
                    if store.antigravityRunning {
                        Label("Connected to Antigravity", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Antigravity isn't running", systemImage: "circle").foregroundStyle(.secondary)
                    }
                }
                Text("Gemini quota is read from the Antigravity app on this Mac while it's running; when it's closed you'll see the last reading. Nothing extra is signed in to or sent anywhere. The Gemini web app and Gemini API billing aren't covered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Gemini")
            }

            Section {
                Toggle("Track OpenAI plan limits from Codex", isOn: $prefs.trackCodex)
                    .onChange(of: prefs.trackCodex) { _, on in
                        if on { Task { await store.refreshCodex() } }
                    }
                if prefs.trackCodex {
                    if store.codex != nil {
                        Label("Reading Codex's session logs", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if store.codexInstalled {
                        Label("Codex found; waiting for your first session", systemImage: "circle").foregroundStyle(.secondary)
                    } else {
                        Label("Codex isn't installed on this Mac", systemImage: "circle").foregroundStyle(.secondary)
                    }
                }
                Text("ChatGPT plan limits for Codex (the CLI, IDE extension and app) are read from the session logs Codex keeps in ~/.codex, so they update as you use Codex on this Mac. Nothing is signed in to or sent anywhere. The section appears once Codex is installed. ChatGPT chat limits and OpenAI API billing aren't covered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("OpenAI")
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                Link("Source on GitHub", destination: Links.repo)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            store.refreshFeedState()
            launchAtLogin = LoginItem.isEnabled
            await store.notifier.refreshAuthorization()
            notificationsDenied = store.notifier.authorization == .denied
        }
    }

    @ViewBuilder private var feedStatus: some View {
        HStack {
            switch store.feedState {
            case .installed:
                Label(store.isFeedLive ? "On, receiving updates" : "On, waiting for Claude Code",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Turn off") { run { try store.uninstallFeed() } }
            case .replaced:
                Label("Your status line was changed, so live updates stopped", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Turn back on") { run { try store.installFeed() } }
            case .notInstalled:
                Label("Off", systemImage: "circle").foregroundStyle(.secondary)
                Spacer()
                Button("Turn on") { run { try store.installFeed() } }
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); feedError = nil } catch { feedError = error.localizedDescription }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
