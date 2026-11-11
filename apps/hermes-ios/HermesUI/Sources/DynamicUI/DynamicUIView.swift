import Charts
import HermesCore
import OSLog
import SwiftUI

/// A dynamic UI Hermes sent with a message (docs/app-protocol.md §8), drawn natively in a
/// content-layer card, as the question card is. `perform` gets what leaves the UI (a reply, a
/// link); local state (`setState`, tabs, choices) stays here. VoiceOver hears `summary` (the
/// message's text) for the whole, then each component's own label.
public struct DynamicUIView: View {
    let spec: UISpec
    let summary: Text
    let perform: @MainActor (DynamicUIAction) async -> Void
    @State private var model: DynamicUIModel

    public init(spec: UISpec, summary: Text, perform: @escaping @MainActor (DynamicUIAction) async -> Void) {
        self.spec = spec
        self.summary = summary
        self.perform = perform
        _model = State(initialValue: DynamicUIModel(state: spec.state))
    }

    public var body: some View {
        let runner = UIRunner(model: model, perform: perform)
        Group {
            if let root = DynamicUI.resolve(spec, state: model.state) {
                if case .card = root.kind {
                    NodeView(node: root, runner: runner, depth: 0)
                } else {
                    CardSurface(.grouped, inset: Block.card) { NodeView(node: root, runner: runner, depth: 1) }
                }
            }
        }
        .onChange(of: spec) { model.state = spec.state }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
        .accessibilityIdentifier("chat.dynamicUI")
    }
}

@MainActor @Observable
final class DynamicUIModel {
    var state: JSONValue
    /// The element whose reply or link is on its way: its button shows busy.
    var busy: String?
    init(state: JSONValue) { self.state = state }
}

/// Runs what an element's event asks: local state here, the rest through `perform`.
@MainActor
struct UIRunner {
    static let log = Logger(subsystem: "hermes.ui", category: "dynamic-ui")
    let model: DynamicUIModel
    let perform: @MainActor (DynamicUIAction) async -> Void

    func run(_ event: String, on node: UINode, choice: UIOption? = nil) {
        for action in DynamicUI.actions(event, of: node, state: model.state, choice: choice) {
            switch action {
            case .setState(let path, let value):
                model.state = JSONPointer.set(model.state, path, value)
            case .unknown(let what):
                Self.log.notice("dynamic UI: \(what, privacy: .public) on \(node.key, privacy: .public) does nothing")
            case .reply, .open:
                model.busy = node.id
                Task {
                    await perform(action)
                    if model.busy == node.id { model.busy = nil }
                }
            }
        }
    }

    /// A choice (`ButtonGroup`, `Select`, `Tabs`): its value first, then what it does.
    func choose(_ option: UIOption, on node: UINode) {
        if let path = node.valuePath { model.state = JSONPointer.set(model.state, path, .string(option.value)) }
        run("change", on: node, choice: option)
    }
}

/// One element and, recursively, its children.
struct NodeView: View {
    let node: UINode
    let runner: UIRunner
    /// 0: the UI's own card; deeper cards are nested surfaces.
    let depth: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accentFill) private var fill
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch node.kind {
        case .card(let title, let description):
            let content = VGroup(spacing: .m) {
                if title != nil || description != nil {
                    VGroup(spacing: .xxs) {
                        if let title { Text(verbatim: title).textRole(.headline).accessibilityAddTraits(.isHeader) }
                        if let description { Text(verbatim: description).textRole(.subheadline).tone(.secondary) }
                    }
                }
                children
            }
            if depth == 0 {
                CardSurface(.grouped, inset: Block.card) { content }
            } else {
                NestedSurface { content }
            }
        case .stack(let axis, let gap, let align, let justify):
            stack(axis: axis, gap: gap, align: align, justify: justify)
        case .grid(let columns, let gap):
            grid(columns: columns, gap: gap)
        case .separator:
            Divider()
        case .heading(let text):
            Text(verbatim: text).textRole(.headline).accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .text(let text, let variant):
            textView(text, variant)
        case .badge(let text, let variant):
            Text(verbatim: text).textRole(.caption)
                .tone(variant == .destructive ? .destructive : variant == .default ? .primary : .secondary)
                .inset(.horizontal, .xs)
                .inset(.vertical, .xxs)
                .surface(variant == .outline ? .elevated : .fill, in: Capsule())
        case .icon(let name, let symbol, let size, let color):
            icon(name: name, symbol: symbol, size: size, color: color)
        case .image(let url, let alt):
            image(url: url, alt: alt)
        case .metric(let m):
            metric(m)
        case .progress(let fraction, let label):
            progress(fraction: fraction, label: label)
        case .alert(let title, let message, let type):
            alert(title: title, message: message, type: type)
        case .table(let columns, let rows, let caption):
            DynamicTable(columns: columns, rows: rows, caption: caption)
        case .barGraph(let title, let data):
            graph(title: title, data: data, bars: true)
        case .lineGraph(let title, let data):
            graph(title: title, data: data, bars: false)
        case .button:
            buttons([node])
        case .buttonGroup(let options, let selected):
            choices(options, selected: selected, label: nil)
        case .select(let label, let options, let value):
            select(label: label, options: options, value: value)
        case .tabs(let options, let selected):
            VGroup(spacing: .m) {
                choices(options, selected: selected, label: nil)
                children
            }
        case .unknown:
            EmptyView()
        }
    }

    private var children: some View {
        ForEach(node.children) { NodeView(node: $0, runner: runner, depth: depth + 1) }
    }

    // MARK: Layout

    @ViewBuilder private func stack(axis: DynamicUIAxis, gap: UIGap, align: UIAlign, justify: UIJustify) -> some View {
        let buttonsOnly = !node.children.isEmpty && node.children.allSatisfy { if case .button = $0.kind { true } else { false } }
        if buttonsOnly {
            buttons(node.children)
        } else if axis == .vertical {
            VStack(alignment: horizontal(align), spacing: points(gap)) {
                ForEach(node.children) { child in
                    NodeView(node: child, runner: runner, depth: depth + 1)
                        .frame(maxWidth: align == .stretch ? .infinity : nil, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment(align))
        } else {
            let row = HStack(alignment: vertical(align), spacing: points(gap)) {
                if justify == .end || justify == .center || justify == .around { Spacer(minLength: 0) }
                ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                    if i > 0, justify == .between || justify == .around { Spacer(minLength: 0) }
                    NodeView(node: child, runner: runner, depth: depth + 1)
                }
                if justify == .center || justify == .around || justify == .start { Spacer(minLength: 0) }
            }
            let column = VStack(alignment: .leading, spacing: points(gap)) { children }
                .frame(maxWidth: .infinity, alignment: .leading)
            // A row that doesn't fit, or any row at accessibility sizes, stacks: nothing truncates (3.4).
            if typeSize.isAccessibilitySize {
                column
            } else {
                ViewThatFits(in: .horizontal) { row; column }
            }
        }
    }

    @ViewBuilder private func grid(columns: Int, gap: UIGap) -> some View {
        let count = typeSize.isAccessibilitySize ? 1 : sizeClass == .compact ? min(columns, 3) : columns
        let rows = stride(from: 0, to: node.children.count, by: count).map { Array(node.children[$0..<min($0 + count, node.children.count)]) }
        Grid(alignment: .topLeading, horizontalSpacing: points(gap), verticalSpacing: points(gap)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { child in
                        NodeView(node: child, runner: runner, depth: depth + 1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func points(_ gap: UIGap) -> CGFloat {
        switch gap {
        case .none: 0
        case .small: Spacing.xs.points
        case .medium: Spacing.s.points
        case .large: Spacing.m.points
        case .extraLarge: Spacing.xl.points
        }
    }

    private func horizontal(_ a: UIAlign) -> HorizontalAlignment {
        switch a {
        case .center: .center
        case .end: .trailing
        default: .leading
        }
    }

    private func vertical(_ a: UIAlign) -> VerticalAlignment {
        switch a {
        case .start: .top
        case .end: .bottom
        default: .center
        }
    }

    private func frameAlignment(_ a: UIAlign) -> Alignment {
        switch a {
        case .center: .center
        case .end: .trailing
        default: .leading
        }
    }

    // MARK: Content

    @ViewBuilder private func textView(_ text: String, _ variant: UITextVariant) -> some View {
        let markdown = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        Group {
            switch variant {
            case .body, .lead: Text(markdown).textRole(.body)
            case .caption: Text(markdown).textRole(.footnote).tone(.secondary)
            case .muted: Text(markdown).textRole(.subheadline).tone(.secondary)
            case .code: Text(verbatim: text).textRole(.code)
            }
        }
        .accentLinks()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func icon(name: String, symbol: String, size: UISize, color: UIColorRole) -> some View {
        let role: TextRole = switch size {
        case .small: .footnote
        case .medium: .body
        case .large: .title
        }
        let image = Image(systemName: symbol).textRole(role)
        Group {
            switch color {
            // The sun in its own colours, as Weather draws it; the rest in the text's.
            case .default:
                if LucideSymbols.multicolor.contains(symbol) {
                    image.symbolRenderingMode(.multicolor)
                } else {
                    image.symbolRenderingMode(.hierarchical).tone(.primary)
                }
            case .muted: image.symbolRenderingMode(.hierarchical).tone(.secondary)
            case .primary: image.symbolRenderingMode(.hierarchical).tone(.accent)
            case .success: image.symbolRenderingMode(.hierarchical).tone(.success)
            case .warning: image.symbolRenderingMode(.hierarchical).tone(.warning)
            case .danger: image.symbolRenderingMode(.hierarchical).tone(.destructive)
            }
        }
        .accessibilityLabel(Text(verbatim: LucideSymbols.spoken(name)))
    }

    @ViewBuilder private func image(url: URL?, alt: String) -> some View {
        let shape = NestedSurface<EmptyView>.shape(radius: innerRadius)
        let placeholder = ZStack {
            Rectangle().fill(Surface.fill.style)
            Image(systemName: "photo").textRole(.title).tone(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metric.imagePlaceholder)
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: Metric.imageMaxHeight)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: alt))
        .accessibilityAddTraits(.isImage)
    }

    @Environment(\.containerCornerRadius) private var containerRadius
    @Environment(\.containerInset) private var containerInset
    /// Concentric with the card it sits in (5.1).
    private var innerRadius: CGFloat { max(containerRadius - containerInset, Radius.blockMinimum) }

    private func metric(_ m: UIMetric) -> some View {
        VGroup(spacing: .xxs) {
            Text(verbatim: m.label).textRole(.subheadline).tone(.secondary)
            // A card's figures in .headline: never a bigger size for importance (3.2).
            Text(verbatim: m.value).textRole(.headline)
            if let change = m.change {
                HGroup(alignment: .firstTextBaseline, spacing: .xxs) {
                    // The arrow points the way the figure moved and takes the change's colour (a cost
                    // going up is red); only the arrow, so the words stay legible (4.3).
                    Image(systemName: Self.arrow(change, m.changeType))
                        .tone(m.changeType == .positive ? .success : m.changeType == .negative ? .destructive : .secondary)
                    Text(verbatim: change).tone(.secondary)
                }
                .textRole(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: m.label))
        .accessibilityValue(Text(verbatim: [m.value, m.change].compactMap { $0 }.joined(separator: ", ")))
    }

    static func arrow(_ change: String, _ type: UIChange) -> String {
        switch change.trimmingCharacters(in: .whitespaces).first {
        case "+": "arrow.up.right"
        case "-", "\u{2212}": "arrow.down.right"
        default: type == .positive ? "arrow.up.right" : type == .negative ? "arrow.down.right" : "arrow.right"
        }
    }

    private func progress(fraction: Double, label: String?) -> some View {
        VGroup(spacing: .xs) {
            HGroup(alignment: .firstTextBaseline, spacing: .s) {
                if let label { Text(verbatim: label).textRole(.subheadline) }
                Spacer(minLength: 0)
                Text(fraction, format: .percent.precision(.fractionLength(0))).textRole(.subheadline).tone(.secondary).monospacedDigit()
            }
            ProgressView(value: fraction).progressViewStyle(.linear).tint(fill)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { Text(verbatim: $0) } ?? Text("Progress"))
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }

    private func alert(title: String, message: String?, type: UIAlertType) -> some View {
        let (symbol, tone): (String, Tone) = switch type {
        case .info: ("info.circle.fill", .secondary)
        case .success: ("checkmark.circle.fill", .success)
        case .warning: ("exclamationmark.triangle.fill", .warning)
        case .error: ("xmark.octagon.fill", .destructive)
        }
        let kind: Text = switch type {
        case .info: Text("Note")
        case .success: Text("Done")
        case .warning: Text("Warning")
        case .error: Text("Error")
        }
        return HGroup(alignment: .firstTextBaseline, spacing: .s) {
            Image(systemName: symbol).textRole(.body).tone(tone)
            VGroup(spacing: .xxs) {
                Text(verbatim: title).textRole(.headline)
                if let message { Text(verbatim: message).textRole(.subheadline).tone(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inset(.all, .s)
        .surface(.elevated, in: NestedSurface<EmptyView>.shape(radius: innerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind + Text(verbatim: ": " + title))
        .accessibilityValue(Text(verbatim: message ?? ""))
    }

    private func graph(title: String?, data: [UIDataPoint], bars: Bool) -> some View {
        VGroup(spacing: .xs) {
            if let title { Text(verbatim: title).textRole(.subheadline).tone(.secondary) }
            Chart(data) { p in
                if bars {
                    BarMark(x: .value("Label", p.label), y: .value("Value", p.value))
                        .foregroundStyle(AccentFillStyle())
                        .accessibilityLabel(Text(verbatim: p.label))
                        .accessibilityValue(Text(p.value, format: .number))
                } else {
                    LineMark(x: .value("Label", p.label), y: .value("Value", p.value))
                        .foregroundStyle(AccentFillStyle())
                        // Monotone: the curve never overshoots the data (Catmull-Rom drew a peak above it).
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(Text(verbatim: p.label))
                        .accessibilityValue(Text(p.value, format: .number))
                    PointMark(x: .value("Label", p.label), y: .value("Value", p.value))
                        .foregroundStyle(AccentFillStyle())
                        .accessibilityHidden(true)
                }
            }
            .chartYScale(domain: .automatic(includesZero: bars))
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: Metric.graphTicks)) }
            .frame(height: Metric.graphHeight)
            // Axis labels stop growing at the largest non-accessibility size, as Weather's graphs
            // do: five days still fit; VoiceOver reads every point (and plays the audio graph).
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityLabel(title.map { Text(verbatim: $0) } ?? Text("Chart"))
        }
    }

    // MARK: Controls

    /// One or more buttons as one `ActionRow`: the same height, capsules side by side, stacked
    /// when they don't fit (5.3). The first primary leads; any other primary becomes secondary
    /// (HIG Buttons: one prominent button), and a danger button is never the primary (4.4).
    @ViewBuilder private func buttons(_ nodes: [UINode]) -> some View {
        let primaryID = nodes.first { if case .button(_, .primary, _) = $0.kind { true } else { false } }?.id
        let actions = nodes.compactMap { n -> Action? in
            guard case .button(let label, let variant, _) = n.kind else { return nil }
            let emphasis: Emphasis = n.id == primaryID ? .primary : variant == .danger ? .destructive : .secondary
            return Action(id: n.id, verbatim: label, emphasis: emphasis, isBusy: runner.model.busy == n.id) { runner.run("press", on: n) }
        }
        let disabled = nodes.allSatisfy { if case .button(_, _, true) = $0.kind { true } else { false } }
        ActionRow(primary: actions.first { $0.id == primaryID }, others: actions.filter { $0.id != primaryID })
            .disabled(disabled)
    }

    /// A button group's or tabs' choices: segments, or a menu when they are many or the text is
    /// large (segments would truncate, 3.4).
    @ViewBuilder private func choices(_ options: [UIOption], selected: String?, label: String?) -> some View {
        let binding = Binding<String>(
            get: { selected ?? "" },
            set: { value in if let o = options.first(where: { $0.value == value }) { runner.choose(o, on: node) } })
        if options.count <= Metric.maxSegments, !typeSize.isAccessibilitySize {
            Picker(selection: binding) {
                ForEach(options) { Text(verbatim: $0.label).tag($0.value) }
            } label: {
                Text(verbatim: label ?? "")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            menuPicker(options, binding: binding, label: label ?? "")
        }
    }

    private func select(label: String, options: [UIOption], value: String?) -> some View {
        let binding = Binding<String>(
            get: { value ?? "" },
            set: { v in if let o = options.first(where: { $0.value == v }) { runner.choose(o, on: node) } })
        return ViewThatFits(in: .horizontal) {
            HGroup(alignment: .firstTextBaseline, spacing: .s) {
                Text(verbatim: label).textRole(.body)
                Spacer(minLength: 0)
                menuPicker(options, binding: binding, label: label)
            }
            VGroup(spacing: .xxs) {
                Text(verbatim: label).textRole(.body)
                menuPicker(options, binding: binding, label: label)
            }
        }
    }

    /// A menu of choices on the neutral bordered button (as `ActionRow`'s "…"), its label the
    /// choice in the text colour: accent text is for links only (15.2).
    private func menuPicker(_ options: [UIOption], binding: Binding<String>, label: String) -> some View {
        let current = options.first { $0.value == binding.wrappedValue }
        return Menu {
            Picker(selection: binding) {
                ForEach(options) { Text(verbatim: $0.label).tag($0.value) }
            } label: {
                Text(verbatim: label)
            }
        } label: {
            HGroup(spacing: .xs) {
                if let current { Text(verbatim: current.label) } else { Text("Choose") }
                Image(systemName: "chevron.up.chevron.down").textRole(.footnote).tone(.secondary)
            }
            .foregroundStyle(Color(uiColor: .label))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .tint(.gray)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(current.map { Text(verbatim: $0.label) } ?? Text("Choose"))
    }
}

/// A card inside the UI's card: the next fill tier, its corner concentric with its container.
struct NestedSurface<Content: View>: View {
    @Environment(\.containerCornerRadius) private var containerRadius
    @Environment(\.containerInset) private var containerInset
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    static func shape(radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        let radius = max(containerRadius - containerInset, Radius.blockMinimum)
        content
            .environment(\.containerCornerRadius, radius)
            .environment(\.containerInset, Spacing.m.points)
            .inset(.all, .m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.elevated, in: Self.shape(radius: radius))
    }
}

/// `Table`: a grid when each row fits on one line, else one block per row ("Column: value"), so
/// nothing truncates (3.4) and nothing scrolls sideways.
struct DynamicTable: View {
    let columns: [String]
    let rows: [[String]]
    let caption: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VGroup(spacing: .xs) {
            if typeSize.isAccessibilitySize || columns.count > Metric.maxSegments {
                stacked
            } else {
                ViewThatFits(in: .horizontal) { grid; stacked }
            }
            if let caption { Text(verbatim: caption).textRole(.footnote).tone(.secondary) }
        }
    }

    private func cell(_ row: [String], _ i: Int) -> String { i < row.count ? row[i] : "" }

    private func spoken(_ row: [String]) -> Text {
        let parts = columns.indices.map { i in columns[i].isEmpty ? cell(row, i) : "\(columns[i]): \(cell(row, i))" }
        return Text(verbatim: (parts.isEmpty ? row : parts).joined(separator: ", "))
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.m.points, verticalSpacing: Spacing.xs.points) {
            if !columns.isEmpty {
                GridRow {
                    ForEach(columns.indices, id: \.self) { i in
                        Text(verbatim: columns[i]).textRole(.footnote).tone(.secondary).fixedSize()
                    }
                }
                .accessibilityHidden(true)
            }
            ForEach(rows.indices, id: \.self) { r in
                Divider()
                GridRow {
                    ForEach(0..<max(columns.count, rows[r].count), id: \.self) { i in
                        Text(verbatim: cell(rows[r], i)).textRole(.subheadline).fixedSize()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(rows[r]))
            }
        }
    }

    private var stacked: some View {
        VGroup(spacing: .s) {
            ForEach(rows.indices, id: \.self) { r in
                if r > 0 { Divider() }
                VGroup(spacing: .xxs) {
                    Text(verbatim: cell(rows[r], 0)).textRole(.headline)
                    ForEach(1..<max(max(columns.count, rows[r].count), 1), id: \.self) { i in
                        let name = i < columns.count ? columns[i] : ""
                        Text(verbatim: name.isEmpty ? cell(rows[r], i) : "\(name): \(cell(rows[r], i))").textRole(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(rows[r]))
            }
        }
    }
}
