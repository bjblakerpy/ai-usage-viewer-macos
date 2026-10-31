// PopoverView.swift
// Claude Usage Viewer

import AppKit
import SwiftUI

struct PopoverView: View {
    let store: UsageStore
    let openSettings: () -> Void

    private var fmt: TimeFormatting { TimeFormatting() }

    var body: some View {
        let now = store.now
        let limits = store.claudeLimits
        let projections = store.projections

        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Claude", plan: store.planName) {
                if store.isFeedLive {
                    LiveBadge().help("Updating live from Claude Code's status line")
                } else if let updated = store.lastUpdated {
                    Text("Updated \(TimeFormatting.duration(now.timeIntervalSince(updated))) ago")
                        .foregroundStyle(store.isStale ? Color.orange : Color.secondary)
                }
            }

            if limits.isEmpty {
                Text(store.visibleError?.message(now: now) ?? "Loading usage…")
                    .font(.callout)
                    .foregroundStyle(store.visibleError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(limits) { limit in
                    LimitRowView(limit: limit, projection: projections[limit.kind],
                                 samples: store.history.samples(for: limit), now: now, fmt: fmt)
                }
            }

            if let snapshot = store.apiSnapshot {
                if !snapshot.weeklyBreakdown.isEmpty {
                    BreakdownView(rows: snapshot.weeklyBreakdown)
                }
                if let extra = snapshot.extraUsage {
                    ExtraUsageRow(extra: extra)
                }
            }

            if !limits.isEmpty, let err = store.visibleError {
                Label(err.message(now: now), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.prefs.trackAntigravity {
                Divider()
                geminiSection(now: now, projections: projections)
            }

            Divider()
            footer(now: now)
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private func geminiSection(now: Date, projections: [String: Projection]) -> some View {
        let limits = store.geminiLimits
        SectionHeader(title: "Gemini · Antigravity", plan: store.antigravity?.planName) {
            if store.antigravityRunning && !store.isGeminiStale {
                LiveBadge().help("Reading quota from the running Antigravity app")
            } else if let seen = store.antigravity?.fetchedAt {
                Text("Last seen \(TimeFormatting.duration(now.timeIntervalSince(seen))) ago")
                    .foregroundStyle(store.isGeminiStale ? Color.orange : Color.secondary)
                    .help(store.antigravityRunning ? "Antigravity is running but not answering"
                                                   : "Antigravity is closed; quota only changes while you use it")
            }
        }

        if limits.isEmpty {
            Text(store.antigravityRunning ? "Reading Gemini quota…" : "Open Antigravity to see your Gemini quota.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(limits) { limit in
                LimitRowView(limit: limit, projection: projections[limit.kind],
                             samples: store.history.samples(for: limit), now: now, fmt: fmt)
            }
        }

        if store.antigravityRunning, let err = store.antigravityError {
            Label(err.message(now: now), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 14) {
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isLoading {
                    Text("Refreshing…")
                } else if let until = store.cooldownUntil {
                    Text("Refresh in \(TimeFormatting.duration(until.timeIntervalSince(now)))")
                } else {
                    Text("Refresh")
                }
            }
            .keyboardShortcut("r")
            .disabled(!store.canRefresh)
            .help(store.cooldownUntil != nil ? "Anthropic asked us to wait before checking again" : "Check usage now")

            Button("Usage page") { NSWorkspace.shared.open(Links.usagePage) }

            Spacer()

            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",")
                .help("Settings")
                .accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit")
                .accessibilityLabel("Quit")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

struct SectionHeader<Status: View>: View {
    let title: String
    let plan:  String?
    @ViewBuilder let status: () -> Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if let plan {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            status().font(.caption)
        }
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text("Live")
        }
        .foregroundStyle(.secondary)
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        HStack {
            Text("Extra usage this month").foregroundStyle(.secondary)
            Spacer()
            if let limit = extra.limit {
                Text("\(extra.used.formatted) of \(limit.formatted)").monospacedDigit()
            } else {
                Text(extra.used.formatted).monospacedDigit()
            }
        }
        .font(.caption)
    }
}
