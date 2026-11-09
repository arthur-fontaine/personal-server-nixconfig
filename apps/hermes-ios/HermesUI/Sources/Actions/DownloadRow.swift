import SwiftUI

/// Something big to download once, as one list row (brief item 8a, the App Store's pattern): its
/// symbol, what it is and one line of detail (size, progress, a wait or the error), and one
/// trailing control for the state — Download (or Retry), a progress ring that stops the download
/// when tapped, or Delete (the system red on the neutral fill: destructive, never prominent, HIG
/// Buttons).
public struct DownloadRow: View {
    public enum State: Equatable, Sendable {
        case absent
        case downloading(fraction: Double)
        /// Paused until a condition returns (Wi-Fi): the ring holds where it stopped.
        case waiting(fraction: Double)
        case ready
        case failed
    }

    let title: Text
    let detail: Text
    let systemImage: String
    let state: State
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    @Environment(\.accentFill) private var fill
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ title: Text, detail: Text, systemImage: String, state: State,
                onDownload: @escaping () -> Void, onCancel: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.state = state
        self.onDownload = onDownload
        self.onCancel = onCancel
        self.onDelete = onDelete
    }

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // The control under the text, as list rows stack at accessibility sizes (3.4).
                VStack(alignment: .leading, spacing: Spacing.xs.points) { label; control }
            } else {
                HStack(spacing: Spacing.s.points) { label; Spacer(minLength: Spacing.xs.points); control }
            }
        }
        .frame(minHeight: Metric.hitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download.row")
    }

    private var label: some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.xxs.points) {
                title.textRole(.body).tone(.primary)
                detail.textRole(.footnote).tone(state == .failed ? .destructive : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var control: some View {
        switch state {
        case .absent, .failed:
            // The row's one primary action: the pet's fill, its label by contrast (15.1).
            Button(action: onDownload) {
                Text(state == .failed ? "Retry" : "Download").textRole(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(OnAccentStyle())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accentFillTint()
            .accessibilityIdentifier("download.start")
        case .downloading(let fraction):
            ring(fraction, paused: false)
        case .waiting(let fraction):
            ring(fraction, paused: true)
        case .ready:
            Button(role: .destructive, action: onDelete) {
                Text("Delete").textRole(.subheadline).fontWeight(.semibold).tone(.destructive)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("download.delete")
        }
    }

    /// The App Store's ring: progress around a stop square; tap to stop.
    private func ring(_ fraction: Double, paused: Bool) -> some View {
        Button(action: onCancel) {
            ZStack {
                Gauge(value: fraction) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(fill)
                    .scaleEffect(Metric.downloadRingScale)
                Image(systemName: "stop.fill").textRole(.caption).tone(.primary)
            }
            .frame(width: Metric.hitTarget, height: Metric.hitTarget)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Stop Download"))
        .accessibilityValue(paused ? Text("Paused") : Text(fraction, format: .percent.precision(.fractionLength(0))))
        .accessibilityIdentifier("download.stop")
    }
}
