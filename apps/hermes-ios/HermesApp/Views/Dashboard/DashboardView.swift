import Charts
import HermesCore
import SwiftUI

/// Models' usage over 24 h / 7 d / 30 d, and the server's CPU, RAM, disk and power, from the
/// `stats` slot. An adaptive grid: one column on iPhone, two or three on iPad.
struct DashboardView: View {
    @Environment(HermesStore.self) private var store
    @State private var window: UsageWindow = .day

    var body: some View {
        ScrollView {
            if let stats = store.stats {
                VStack(alignment: .leading, spacing: 20) {
                    section("Models") {
                        Picker("Window", selection: $window) {
                            ForEach(UsageWindow.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }
                    UsageSummary(models: stats.models, window: window)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(stats.models.sorted { (Self.roleOrder($0.role), -$0.figures(window).calls) < (Self.roleOrder($1.role), -$1.figures(window).calls) }) { m in
                            ModelCard(model: m, window: window)
                        }
                    }
                    if let machine = stats.machine {
                        section("Server") { EmptyView() }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            MetricCard(title: String(localized: "CPU"), symbol: "cpu", value: machine.cpuPercent.map { $0 / 100 },
                                       detail: machine.cpuPercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "–",
                                       history: machine.cpuHistory, color: .blue)
                            MetricCard(title: String(localized: "Memory"), symbol: "memorychip", value: machine.ramFraction,
                                       detail: bytesPair(machine.ramUsed, machine.ramTotal), history: machine.ramHistory, color: .purple)
                            MetricCard(title: String(localized: "Storage"), symbol: "internaldrive", value: machine.diskFraction,
                                       detail: bytesPair(machine.diskUsed, machine.diskTotal), history: [], color: .teal)
                            PowerCard(machine: machine)
                        }
                    }
                    if let at = stats.updatedAt {
                        Text("Updated \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("No stats yet", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Hermes posts them every minute."))
                    .padding(.top, 80)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dashboard")
        .refreshable { store.refreshStats() }
        .onAppear { store.refreshStats() }
    }

    /// The chain first (main, then fallbacks), then the helpers.
    static func roleOrder(_ r: ModelUsage.Role) -> Int {
        switch r {
        case .main: 0
        case .fallback: 1
        case .local: 2
        case .background: 3
        case .decision: 4
        case .other: 5
        }
    }

    private func section<T: View>(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title).font(.title2.weight(.semibold))
            Spacer()
            trailing()
        }
    }

    private func bytesPair(_ used: Int64?, _ total: Int64?) -> String {
        guard let used, let total else { return "–" }
        let u = ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
        return String(localized: "\(u) of \(t)", comment: "Memory or storage: used of total")
    }
}

extension DashboardView {
    /// Costs are in US dollars whatever the region, in the narrow form that fits a card: "$1.62", "1,62 $".
    static func dollars(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").presentation(.narrow).precision(.fractionLength(2)))
    }
}

struct UsageSummary: View {
    let models: [ModelUsage]
    let window: UsageWindow

    var body: some View {
        let totals = models.map { $0.figures(window) }
        let calls = totals.map(\.calls).reduce(0, +)
        let tokens = totals.map(\.totalTokens).reduce(0, +)
        let cost = totals.map(\.costUSD).reduce(0, +)
        let errors = totals.map(\.errors).reduce(0, +)
        HStack(spacing: 12) {
            stat("Calls", calls.formatted(.number.notation(.compactName)))
            stat("Tokens", tokens.formatted(.number.notation(.compactName)))
            stat("Cost", DashboardView.dollars(cost))
            stat("Errors", "\(errors)", alert: errors > 0)
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(alert ? .red : .primary)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

struct ModelCard: View {
    let model: ModelUsage
    let window: UsageWindow

    var body: some View {
        let f = model.figures(window)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.model).font(.headline).lineLimit(1)
                    Text(model.provider).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(roleLabel).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(roleColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(roleColor)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    figure("Calls", f.calls.formatted())
                    figure("In", f.tokensIn.formatted(.number.notation(.compactName)))
                    figure("Out", f.tokensOut.formatted(.number.notation(.compactName)))
                }
                GridRow {
                    figure("Cached", f.cacheRatio.formatted(.percent.precision(.fractionLength(0))))
                    figure("Cost", f.costUSD > 0 ? DashboardView.dollars(f.costUSD) : "—")
                    figure("Errors", "\(f.errors)", alert: f.errors > 0)
                }
            }
            if let last = model.lastUsed {
                Text("Last used \(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var roleLabel: String {
        switch model.role {
        case .main: String(localized: "Main", comment: "Model role")
        case .fallback: String(localized: "Fallback", comment: "Model role")
        case .background: String(localized: "Background", comment: "Model role")
        case .local: String(localized: "Local", comment: "Model role")
        case .decision: String(localized: "Decision", comment: "Model role")
        case .other: String(localized: "Other", comment: "Model role")
        }
    }

    private var roleColor: Color {
        switch model.role {
        case .main: .accentColor
        case .fallback: .orange
        case .background: .indigo
        case .local: .green
        default: .secondary
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(alert ? .red : .primary)
        }
    }
}

struct MetricCard: View {
    let title: String
    let symbol: String
    let value: Double?
    let detail: String
    let history: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                Text(detail).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            if !history.isEmpty {
                Chart(Array(history.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value(String(localized: "Hour"), i), y: .value(title, v))
                        .foregroundStyle(color.opacity(0.2).gradient)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value(String(localized: "Hour"), i), y: .value(title, v))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .frame(height: 80)
                .accessibilityLabel(String(localized: "\(title), last 24 hours"))
            } else if let value {
                Gauge(value: value) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(value > 0.9 ? .red : color)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }
}

struct PowerCard: View {
    let machine: MachineStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Power", systemImage: "bolt.fill").font(.headline)
                Spacer()
                if let w = machine.powerWatts { Text(Measurement(value: w, unit: UnitPower.watts).formatted(Self.unit(1))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
            }
            if !machine.powerHistory.isEmpty {
                Chart(Array(machine.powerHistory.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value(String(localized: "Hour"), i), y: .value(String(localized: "Power"), v)).foregroundStyle(.yellow.gradient)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .frame(height: 64)
            }
            HStack(spacing: 16) {
                if let kwh = machine.energyKWh24h { tag("24 h", Measurement(value: kwh, unit: UnitEnergy.kilowattHours).formatted(Self.unit(2))) }
                if let b = machine.batteryPercent {
                    tag(machine.charging == true ? "Charging" : "Battery", (b / 100).formatted(.percent.precision(.fractionLength(0))))
                }
                if let up = machine.uptime { tag("Up", Duration.seconds(up).formatted(.units(allowed: [.days, .hours], width: .narrow))) }
                if let t = machine.temperatureC {
                    // The server's Celsius as it is: no conversion to the region's unit for a machine's temperature.
                    tag("Temp", Measurement(value: t, unit: UnitTemperature.celsius)
                        .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))))
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private static func unit<U: Dimension>(_ digits: Int) -> Measurement<U>.FormatStyle {
        .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits)))
    }

    private func tag(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
    }
}
