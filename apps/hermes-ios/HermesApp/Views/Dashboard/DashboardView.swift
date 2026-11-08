import HermesCore
import HermesUI
import SwiftUI

/// Models' usage over 24 h / 7 d / 30 d and the server's CPU, memory, storage and power, from the
/// `stats` slot. A system inset-grouped list, as Settings › Battery (design-rules 6.3): the window
/// as a segmented control, the totals and each figure as value rows, charts under their rows.
struct DashboardView: View {
    @Environment(HermesStore.self) private var store
    @State private var window: UsageWindow = .day

    var body: some View {
        Group {
            if let stats = store.stats {
                List {
                    Section {
                        Picker("Window", selection: $window) {
                            ForEach(UsageWindow.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        totals(stats.models)
                    } header: {
                        Text("Models")
                    }
                    Section {
                        ForEach(stats.models.sorted { (Self.roleOrder($0.role), -$0.figures(window).calls) < (Self.roleOrder($1.role), -$1.figures(window).calls) }) { m in
                            NavigationLink { ModelDetail(model: m, window: window) } label: { modelRow(m) }
                        }
                    }
                    if let machine = stats.machine { server(machine) }
                    if let at = stats.updatedAt {
                        Section {} footer: { Text("Updated \(at.formatted(.relative(presentation: .named)))") }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView("No stats yet", systemImage: "gauge.with.dots.needle.0percent",
                                       description: Text("Hermes posts them every minute."))
            }
        }
        .readableGroupedList()
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { store.refreshStats() }
        .onAppear { store.refreshStats() }
    }

    @ViewBuilder private func totals(_ models: [ModelUsage]) -> some View {
        let f = models.map { $0.figures(window) }
        let errors = f.map(\.errors).reduce(0, +)
        LabeledContent("Calls", value: f.map(\.calls).reduce(0, +).formatted(.number.notation(.compactName)))
        LabeledContent("Tokens", value: f.map(\.totalTokens).reduce(0, +).formatted(.number.notation(.compactName)))
        LabeledContent("Cost", value: Self.dollars(f.map(\.costUSD).reduce(0, +)))
        LabeledContent("Errors") { Text("\(errors)").tone(errors > 0 ? .destructive : .secondary) }
    }

    private func modelRow(_ m: ModelUsage) -> some View {
        let f = m.figures(window)
        return LabeledContent {
            Text(f.costUSD > 0 ? Self.dollars(f.costUSD) : String(localized: "\(f.calls) calls"))
        } label: {
            VGroup(spacing: .xxs) {
                Text(m.model)
                Text(String(localized: "\(Self.roleLabel(m.role)), \(m.provider)")).textRole(.footnote).tone(.secondary)
            }
        }
    }

    @ViewBuilder private func server(_ machine: MachineStats) -> some View {
        Section {
            VGroup(spacing: .xs) {
                LabeledContent { Text(machine.cpuPercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "–") }
                    label: { Label("CPU", systemImage: "cpu") }
                if !machine.cpuHistory.isEmpty { Sparkline(ChartSeries(machine.cpuHistory), label: Text("CPU, last 24 hours")) }
            }
            VGroup(spacing: .xs) {
                LabeledContent { Text(Self.bytesPair(machine.ramUsed, machine.ramTotal)) } label: { Label("Memory", systemImage: "memorychip") }
                if !machine.ramHistory.isEmpty { Sparkline(ChartSeries(machine.ramHistory), label: Text("Memory, last 24 hours")) }
            }
            VGroup(spacing: .xs) {
                LabeledContent { Text(Self.bytesPair(machine.diskUsed, machine.diskTotal)) } label: { Label("Storage", systemImage: "internaldrive") }
                if let used = machine.diskUsed, let total = machine.diskTotal, total > 0 {
                    UsageBar(Progress(totalUnitCount: total, completed: used), label: Text("Storage used"))
                }
            }
            VGroup(spacing: .xs) {
                LabeledContent {
                    if let w = machine.powerWatts { Text(Measurement(value: w, unit: UnitPower.watts).formatted(Self.unit(1))) }
                } label: { Label("Power", systemImage: "bolt") }
                if !machine.powerHistory.isEmpty { Sparkline(ChartSeries(machine.powerHistory), kind: .bars, label: Text("Power, last 24 hours")) }
            }
        } header: {
            Text("Server")
        }
        Section {
            if let kwh = machine.energyKWh24h {
                LabeledContent("Energy, last 24 hours", value: Measurement(value: kwh, unit: UnitEnergy.kilowattHours).formatted(Self.unit(2)))
            }
            if let b = machine.batteryPercent {
                LabeledContent(machine.charging == true ? "Charging" : "Battery", value: (b / 100).formatted(.percent.precision(.fractionLength(0))))
            }
            if let up = machine.uptime {
                LabeledContent("Up for", value: Duration.seconds(up).formatted(.units(allowed: [.days, .hours], width: .wide)))
            }
            if let t = machine.temperatureC {
                // The server's Celsius as it is: no conversion to the region's unit for a machine.
                LabeledContent("Temperature", value: Measurement(value: t, unit: UnitTemperature.celsius)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))))
            }
        }
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

    static func roleLabel(_ r: ModelUsage.Role) -> String {
        switch r {
        case .main: String(localized: "Main", comment: "Model role")
        case .fallback: String(localized: "Fallback", comment: "Model role")
        case .background: String(localized: "Background", comment: "Model role")
        case .local: String(localized: "Local", comment: "Model role")
        case .decision: String(localized: "Decision", comment: "Model role")
        case .other: String(localized: "Other", comment: "Model role")
        }
    }

    static func bytesPair(_ used: Int64?, _ total: Int64?) -> String {
        guard let used, let total else { return "–" }
        let u = ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
        return String(localized: "\(u) of \(t)", comment: "Memory or storage: used of total")
    }

    static func unit<U: Dimension>(_ digits: Int) -> Measurement<U>.FormatStyle {
        .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits)))
    }

    /// Costs are in US dollars whatever the region, in the narrow form: "$1.62", "1,62 $".
    static func dollars(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").presentation(.narrow).precision(.fractionLength(2)))
    }
}

extension Progress {
    convenience init(totalUnitCount: Int64, completed: Int64) {
        self.init(totalUnitCount: totalUnitCount)
        completedUnitCount = completed
    }
}

/// One model's figures for the window.
struct ModelDetail: View {
    let model: ModelUsage
    let window: UsageWindow

    var body: some View {
        let f = model.figures(window)
        List {
            Section {
                LabeledContent("Provider", value: model.provider)
                LabeledContent("Role", value: DashboardView.roleLabel(model.role))
                if let last = model.lastUsed {
                    LabeledContent("Last used", value: last.formatted(.relative(presentation: .named)))
                }
            }
            Section {
                LabeledContent("Calls", value: f.calls.formatted())
                LabeledContent("Tokens in", value: f.tokensIn.formatted(.number.notation(.compactName)))
                LabeledContent("Tokens out", value: f.tokensOut.formatted(.number.notation(.compactName)))
                LabeledContent("From the cache", value: f.cacheRatio.formatted(.percent.precision(.fractionLength(0))))
                LabeledContent("Cost", value: f.costUSD > 0 ? DashboardView.dollars(f.costUSD) : "—")
                LabeledContent("Errors") { Text("\(f.errors)").tone(f.errors > 0 ? .destructive : .secondary) }
            } header: {
                Text(window.title)
            }
        }
        .listStyle(.insetGrouped)
        .readableGroupedList()
        .navigationTitle(model.model)
        .navigationBarTitleDisplayMode(.inline)
    }
}
