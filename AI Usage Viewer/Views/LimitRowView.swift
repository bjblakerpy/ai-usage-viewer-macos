// LimitRowView.swift
// AI Usage Viewer

import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .normal:   .green
        case .warning:  .orange
        case .critical: .red
        }
    }
}

struct LimitRowView: View {
    let limit:      UsageLimit
    let projection: Projection?
    let samples:    [UsageSample]
    let now:        Date
    let fmt:        TimeFormatting

    private var severity: Severity { projection?.severity ?? .normal }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.subheadline.weight(.medium))
                Spacer()
                Text(TimeFormatting.percent(limit.percent))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(severity.color)
            }

            UsageBar(percent: limit.percent, expected: projection?.expectedPercent, color: severity.color)

            if samples.count >= 2, let start = limit.windowStart, let end = limit.resetsAt {
                Sparkline(samples: samples, current: limit.percent, start: start, end: end, now: now,
                          color: severity.color)
                    .frame(height: 26)
            }

            HStack {
                if let projection {
                    Text(Describe.projection(projection, now: now, fmt: fmt))
                        .foregroundStyle(severity > .normal ? severity.color : .secondary)
                }
                Spacer()
                Text(Describe.reset(limit, now: now, fmt: fmt)).foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

// Usage bar with a tick at where usage "should" be if spread evenly over
// the window: left of the tick is under pace, right is over.
struct UsageBar: View {
    let percent:  Double
    let expected: Double?
    let color:    Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: max(6, w * min(1, percent / 100)))
                    .animation(.easeInOut(duration: 0.4), value: percent)
                if let expected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 12)
                        .offset(x: min(w - 2, max(0, w * expected / 100 - 1)))
                        .help("Even pace: \(TimeFormatting.percent(expected)) of the window has passed")
                }
            }
        }
        .frame(height: 12)
        .padding(.vertical, -3)   // the tick overhangs the 6pt bar
        .accessibilityHidden(true)
    }
}

// Usage across the current window, with a dashed line for even pace.
struct Sparkline: View {
    let samples: [UsageSample]
    let current: Double
    let start:   Date
    let end:     Date
    let now:     Date
    let color:   Color

    var body: some View {
        Canvas { ctx, size in
            let span = end.timeIntervalSince(start)
            guard span > 0 else { return }
            func point(_ date: Date, _ pct: Double) -> CGPoint {
                CGPoint(x: size.width * min(1, max(0, date.timeIntervalSince(start) / span)),
                        y: size.height * (1 - min(100, max(0, pct)) / 100))
            }

            var pace = Path()
            pace.move(to: point(start, 0))
            pace.addLine(to: point(end, 100))
            ctx.stroke(pace, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            var pts = samples.map { point($0.date, $0.percent) }
            pts.append(point(now, current))
            guard let first = pts.first, let last = pts.last else { return }
            var line = Path()
            line.addLines(pts)
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.15)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

struct BreakdownView: View {
    let rows: [BreakdownRow]
    private static let palette: [Color] = [.purple, .blue, .teal, .pink, .gray]

    private func color(_ i: Int) -> Color { Self.palette[i % Self.palette.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This week by product").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let total = max(1, rows.map(\.percent).reduce(0, +))
                HStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        Rectangle().fill(color(i))
                            .frame(width: max(2, (geo.size.width - CGFloat(rows.count - 1)) * row.percent / total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    HStack(spacing: 4) {
                        Circle().fill(color(i)).frame(width: 6, height: 6)
                        Text("\(row.name) \(TimeFormatting.percent(row.percent))")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
