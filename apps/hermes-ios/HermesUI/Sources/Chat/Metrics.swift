import Charts
import SwiftUI

/// Values over time for a `Sparkline`: data, not a styling number (design-rules 9.2).
public struct ChartSeries: Sendable, Equatable {
    let values: [Double]
    public init<S: Sequence>(_ values: S) where S.Element: BinaryFloatingPoint { self.values = values.map(Double.init) }
}

/// A small chart under a list row's value (Settings › Battery's style): the last 24 hours, in
/// the accent — one colour for data, as for every other accent use (4.2).
public struct Sparkline: View {
    public enum Kind: Sendable { case line, bars }
    let values: [Double]
    let kind: Kind
    let label: Text

    public init(_ series: ChartSeries, kind: Kind = .line, label: Text) {
        values = series.values
        self.kind = kind
        self.label = label
    }

    public var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            switch kind {
            case .line:
                AreaMark(x: .value("Hour", i), y: .value("Value", v))
                    .foregroundStyle(.tint.opacity(Fade.chartArea))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Hour", i), y: .value("Value", v))
                    .foregroundStyle(.tint)
                    .interpolationMethod(.catmullRom)
            case .bars:
                BarMark(x: .value("Hour", i), y: .value("Value", v)).foregroundStyle(.tint)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: Metric.chartTicks)) }
        .frame(height: Metric.chartHeight)
        .accessibilityLabel(label)
    }
}

/// How full something is (storage): the system's bar in the accent, red past 90 %.
public struct UsageBar: View {
    let value: Double
    let label: Text

    public init(_ progress: Progress, label: Text) {
        value = progress.fractionCompleted
        self.label = label
    }

    public var body: some View {
        ProgressView(value: value)
            .tint(value > Metric.criticalUsage ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            .accessibilityLabel(label)
    }
}
