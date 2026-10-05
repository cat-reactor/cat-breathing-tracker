import SwiftUI
import SwiftData
import Charts

enum TrendRange: String, CaseIterable, Identifiable {
    case week = "7", month = "30", quarter = "90", all = "all"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .all: "All"
        }
    }
    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }
}

struct TrendsView: View {
    @Query(sort: \Reading.date) private var readings: [Reading]
    @AppStorage(Prefs.trendRange) private var range: TrendRange = .month
    @AppStorage(Prefs.alertLevel) private var alertLevel = Prefs.defaultAlertLevel

    @State private var hidden: Set<BreathState> = []
    @State private var selected: Reading?

    private struct DailyMean: Identifiable {
        let state: BreathState
        let date: Date
        let value: Double
        var id: String { "\(state.rawValue)-\(date.timeIntervalSince1970)" }
    }

    // MARK: Data for the selected range

    private var bounds: (from: Date, to: Date) {
        let now = Date()
        if let days = range.days {
            return (now.addingTimeInterval(-Double(days) * 86_400), now)
        }
        let first = readings.first.map { Calendar.current.startOfDay(for: $0.date) } ?? now.addingTimeInterval(-7 * 86_400)
        let last = max(now, readings.last?.date ?? now)
        return (min(first, last.addingTimeInterval(-2 * 86_400)), last)
    }

    private var items: [Reading] {
        let b = bounds
        return readings.filter { $0.date >= b.from && $0.date <= b.to }
    }

    private var visible: [Reading] { items.filter { !hidden.contains($0.state) } }

    private var dailyMeans: [DailyMean] {
        let cal = Calendar.current
        var out: [DailyMean] = []
        for state in BreathState.allCases where !hidden.contains(state) {
            let groups = Dictionary(grouping: items.filter { $0.state == state }) { cal.startOfDay(for: $0.date) }
            for (_, rs) in groups {
                let t = rs.map(\.date.timeIntervalSince1970).reduce(0, +) / Double(rs.count)
                let v = Double(rs.map(\.bpm).reduce(0, +)) / Double(rs.count)
                out.append(DailyMean(state: state, date: Date(timeIntervalSince1970: t), value: v))
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    private var yDomain: ClosedRange<Int> {
        let vals = items.map(\.bpm)
        let lo = min(15, (vals.min() ?? 15) - 2)
        let hi = max(40, alertLevel + 5, (vals.max() ?? 40) + 2)
        return max(0, lo / 5 * 5)...((hi + 4) / 5 * 5)
    }

    // MARK: Views

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        ForEach(BreathState.allCases) { s in
                            StatTile(state: s, values: items.filter { $0.state == s }.map(\.bpm))
                        }
                    }

                    chartCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trends")
            .onChange(of: range) { selected = nil }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend

            chart
                .frame(height: 260)
                .overlay {
                    if visible.isEmpty {
                        Text(items.isEmpty ? "No readings in this period" : "All states hidden")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

            if let r = selected {
                HStack(spacing: 10) {
                    StateDot(state: r.state, size: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.bpm)/min · \(r.state.label)").font(.headline)
                        Text("\(r.date.dayLabel) · \(r.date.timeLabel)\(r.note.isEmpty ? "" : " · \(r.note)")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") { selected = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("Dots are single readings; lines join each day’s average. Tap a dot for details.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(BreathState.allCases) { s in
                let on = !hidden.contains(s)
                Button {
                    if on { hidden.insert(s) } else { hidden.remove(s) }
                    if let sel = selected, hidden.contains(sel.state) { selected = nil }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .strokeBorder(s.color, lineWidth: 1.5)
                            .background(Circle().fill(on ? s.color : .clear))
                            .frame(width: 9, height: 9)
                        Text("\(s.label) (\(items.filter { $0.state == s }.count))")
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(on ? Color(.tertiarySystemFill) : .clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: on ? 0 : 1))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            HStack(spacing: 6) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 1))
                    p.addLine(to: CGPoint(x: 16, y: 1))
                }
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: 16, height: 2)
                Text("Alert \(alertLevel)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        let b = bounds
        let pad = (b.to.timeIntervalSince(b.from)) * 0.03
        return Chart {
            RuleMark(y: .value("Alert level", alertLevel))
                .foregroundStyle(Color(.secondaryLabel))
                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 4]))

            ForEach(dailyMeans) { m in
                LineMark(
                    x: .value("Date", m.date),
                    y: .value("Daily average", m.value),
                    series: .value("State", m.state.label)
                )
                .foregroundStyle(m.state.color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // Awake first so asleep dots sit on top.
            ForEach(visible.sorted { $0.state == .awake && $1.state == .asleep }) { r in
                PointMark(x: .value("Date", r.date), y: .value("Breaths per minute", r.bpm))
                    .foregroundStyle(r.state.color)
                    .symbolSize(44)
            }

            if let r = selected {
                PointMark(x: .value("Date", r.date), y: .value("Breaths per minute", r.bpm))
                    .symbol {
                        Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 16, height: 16)
                    }
            }
        }
        .chartXScale(domain: b.from.addingTimeInterval(-pad)...b.to.addingTimeInterval(pad))
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .stride(by: yDomain.upperBound - yDomain.lowerBound > 50 ? 10 : 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            // No vertical gridlines: the only dashed line on the chart is the alert level.
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        selected = nearest(to: location, proxy: proxy, geo: geo)
                    }
            }
        }
        .accessibilityLabel("Breaths per minute over time")
    }

    private func nearest(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Reading? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geo[plotFrame].origin
        var best: (Reading, CGFloat)?
        for r in visible {
            guard let x = proxy.position(forX: r.date), let y = proxy.position(forY: r.bpm) else { continue }
            let d = hypot(x + origin.x - location.x, y + origin.y - location.y)
            if d < (best?.1 ?? .infinity) { best = (r, d) }
        }
        guard let best, best.1 <= 32 else { return nil }
        return best.0
    }
}

private struct StatTile: View {
    let state: BreathState
    let values: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StateDot(state: state)
                Text(state.label)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if values.isEmpty {
                Text("–").font(.system(size: 30, weight: .semibold))
                Text("No readings").font(.caption).foregroundStyle(.secondary)
            } else {
                let avg = Double(values.reduce(0, +)) / Double(values.count)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(avg.rounded()))").font(.system(size: 30, weight: .semibold))
                    Text("avg").font(.footnote).foregroundStyle(.secondary)
                }
                Text("\(values.count) reading\(values.count == 1 ? "" : "s")\(values.count > 1 ? " · \(values.min()!)–\(values.max()!)" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
