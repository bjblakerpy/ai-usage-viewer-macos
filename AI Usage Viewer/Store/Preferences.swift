// Preferences.swift
// AI Usage Viewer

import Foundation
import Observation

@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var menuBarMode: MenuBarMode {
        didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }
    var notifyProjection: Bool {
        didSet { defaults.set(notifyProjection, forKey: "notifyProjection") }
    }
    var notifyThresholds: Bool {
        didSet { defaults.set(notifyThresholds, forKey: "notifyThresholds") }
    }
    var thresholdLow: Int {
        didSet { defaults.set(thresholdLow, forKey: "thresholdLow") }
    }
    var thresholdHigh: Int {
        didSet { defaults.set(thresholdHigh, forKey: "thresholdHigh") }
    }
    var notifyResets: Bool {
        didSet { defaults.set(notifyResets, forKey: "notifyResets") }
    }
    var trackAntigravity: Bool {
        didSet { defaults.set(trackAntigravity, forKey: "trackAntigravity") }
    }
    var trackCodex: Bool {
        didSet { defaults.set(trackCodex, forKey: "trackCodex") }
    }
    // Set once we've turned on launch-at-login for the first time, so a
    // user who later turns it off isn't overridden.
    var didSetUpLoginItem: Bool {
        didSet { defaults.set(didSetUpLoginItem, forKey: "didSetUpLoginItem") }
    }

    init() {
        defaults.register(defaults: [
            "menuBarMode": MenuBarMode.auto.rawValue,
            "notifyProjection": true,
            "notifyThresholds": true,
            "thresholdLow": 80,
            "thresholdHigh": 95,
            "notifyResets": true,
            "trackAntigravity": true,
            "trackCodex": true,
        ])
        menuBarMode       = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .auto
        notifyProjection  = defaults.bool(forKey: "notifyProjection")
        notifyThresholds  = defaults.bool(forKey: "notifyThresholds")
        thresholdLow      = defaults.integer(forKey: "thresholdLow")
        thresholdHigh     = defaults.integer(forKey: "thresholdHigh")
        notifyResets      = defaults.bool(forKey: "notifyResets")
        trackAntigravity  = defaults.bool(forKey: "trackAntigravity")
        trackCodex        = defaults.bool(forKey: "trackCodex")
        didSetUpLoginItem = defaults.bool(forKey: "didSetUpLoginItem")
    }

    var alertSettings: AlertSettings {
        AlertSettings(projection: notifyProjection, thresholds: notifyThresholds,
                      thresholdValues: [thresholdLow, thresholdHigh], resets: notifyResets)
    }
}
