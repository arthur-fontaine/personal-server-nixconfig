import SwiftUI

public extension View {
    /// The rows of a grouped list or form: icons monochrome in one fixed column (one leading edge
    /// for every title, design-rules 2.1; no accent glyph, 15.2), stacked above their text at
    /// accessibility sizes (3.4), and pickers' checkmarks and values monochrome.
    func groupedRows() -> some View { modifier(GroupedRows()) }

}

struct RowLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        if size.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xs.points) {
                configuration.icon.foregroundStyle(.primary)
                configuration.title.frame(maxWidth: .infinity, alignment: .leading)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s.points) {
                // The glyph is centred in its column whatever its own width (a wide one such as
                // `theatermasks` doesn't stick out to the left).
                configuration.icon
                    .foregroundStyle(.primary)
                    .frame(width: Metric.rowIcon)
                configuration.title
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
        }
    }
}

/// The list's tint is the label colour (checkmarks, chevrons, picker values: 15.2); its switches
/// keep the pet's fill, a fill being where the pet's colour belongs (15.1).
struct GroupedRows: ViewModifier {
    @Environment(\.accentFill) private var fill
    func body(content: Content) -> some View {
        content
            .labelStyle(RowLabelStyle())
            .toggleStyle(PetSwitch(fill: fill))
            .tint(.primary)
    }
}

struct PetSwitch: ToggleStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .tint(fill)
    }
}

/// One of a list's choices of one (the system's inline picker row): the title, an optional detail
/// under it, an optional icon in the row's column, and the system checkmark on the chosen one — in
/// the label colour at every text size (15.2; the system picker's turns to the accent at
/// accessibility sizes). VoiceOver reads it as a selected or unselected button.
public struct ChoiceRow: View {
    let title: Text
    let detail: Text?
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: Text, detail: Text? = nil, systemImage: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s.points) {
                if let systemImage {
                    Label { text } icon: { Image(systemName: systemImage).accessibilityHidden(true) }
                } else {
                    text.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                Image(systemName: "checkmark")
                    .textRole(.headline)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs.points) {
            title.textRole(.body)
            if let detail { detail.textRole(.footnote).tone(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
