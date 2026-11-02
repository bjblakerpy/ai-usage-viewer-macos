// StatusItemController.swift
// AI Usage Viewer
//
// The menu-bar item. Uses NSStatusItem directly rather than SwiftUI's
// MenuBarExtra, which can't set monospaced digits, colour part of the
// title, dim a stale reading or offer a right-click menu.

import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(store: UsageStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        super.init()
    }

    func start() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading

        let root = PopoverView(store: store, openSettings: { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettings()
        })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false

        observe()
    }

    // Re-render whenever anything the presentation reads changes.
    private func observe() {
        withObservationTracking {
            update()
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func update() {
        guard let button = statusItem.button else { return }
        let p = store.menuBar()
        button.image = switch p.provider {
        case .antigravity: MenuBarRenderer.sparkle()
        case .codex:       MenuBarRenderer.prompt()
        case .claude:      MenuBarRenderer.icon(session: p.sessionFraction, weekly: p.weeklyFraction)
        }
        button.attributedTitle = MenuBarRenderer.title(p)
        button.appearsDisabled = p.isStale
        button.toolTip = p.tooltip
        button.setAccessibilityLabel("AI usage")
        button.setAccessibilityValue(p.tooltip)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            store.nudge()
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.isEnabled = store.canRefresh
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Open Claude Usage Page", action: #selector(openUsagePage), keyEquivalent: ""))
        if store.showsCodex {
            menu.addItem(NSMenuItem(title: "Open Codex Usage Page", action: #selector(openCodexUsagePage), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AI Usage Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { Task { await store.refresh() } }
    @objc private func openUsagePage() { NSWorkspace.shared.open(Links.usagePage) }
    @objc private func openCodexUsagePage() { NSWorkspace.shared.open(Links.codexUsagePage) }
    @objc private func showSettings() { openSettings() }
}

enum Links {
    static let usagePage = URL(string: "https://claude.ai/settings/usage")!
    static let codexUsagePage = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let repo = URL(string: "https://github.com/bjblakerpy/ai-usage-viewer-macos")!
}

@MainActor
enum MenuBarRenderer {
    // Two stacked bars, session over weekly, drawn as a template image so
    // macOS tints it to match the menu bar like any system icon.
    static func icon(session: Double?, weekly: Double?) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let barHeight: CGFloat = 4, gap: CGFloat = 3
            let top = (rect.height + gap) / 2
            for (i, fraction) in [session, weekly].enumerated() {
                let y = i == 0 ? top : top - gap - barHeight
                let track = NSRect(x: 0, y: y, width: rect.width, height: barHeight)
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                guard let fraction, fraction > 0 else { continue }
                let fill = NSRect(x: 0, y: y, width: max(barHeight, rect.width * fraction), height: barHeight)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // Four-point sparkle, shown when the most urgent limit is a Gemini one.
    static func sparkle() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = rect.width / 2, pinch = r * 0.12
            // Tips at N, E, S, W; each edge bows in toward a point just off
            // centre between the two tips it joins.
            let dirs: [(CGFloat, CGFloat)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.x, y: c.y + r))
            for i in 0..<4 {
                let a = dirs[i], b = dirs[(i + 1) % 4]
                let control = NSPoint(x: c.x + pinch * (a.0 + b.0), y: c.y + pinch * (a.1 + b.1))
                path.curve(to: NSPoint(x: c.x + b.0 * r, y: c.y + b.1 * r),
                           controlPoint1: control, controlPoint2: control)
            }
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // A ">_" prompt, shown when the most urgent limit is a Codex one.
    static func prompt() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 1.5, y: 11.5))
            chevron.line(to: NSPoint(x: 6, y: 7))
            chevron.line(to: NSPoint(x: 1.5, y: 2.5))
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.black.setStroke()
            chevron.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 7.5, y: 1.5, width: 6, height: 2), xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func title(_ p: MenuBarPresentation) -> NSAttributedString {
        let accent: NSColor? = switch p.severity {
        case .normal:   nil
        case .warning:  .systemOrange
        case .critical: .systemRed
        }
        let s = NSMutableAttributedString()
        var main: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]
        if let accent { main[.foregroundColor] = accent }
        s.append(NSAttributedString(string: " " + p.text, attributes: main))
        if let caption = p.caption {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: accent ?? NSColor.secondaryLabelColor,
            ]
            s.append(NSAttributedString(string: " " + caption, attributes: attrs))
        }
        return s
    }
}
