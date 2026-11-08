import SwiftUI

/// A row of a system list that runs something (a command): its symbol, a title and one line of
/// detail, in the label colour — a list of actions isn't a list of links — red when it asks for
/// confirmation (HIG Buttons: destructive is the system red), with a trailing hint when it fills
/// the composer instead of running.
public struct ListActionRow: View {
    let title: Text
    let detail: Text?
    let systemImage: String
    let destructive: Bool
    let fillsComposer: Bool
    let action: () -> Void

    public init(_ title: Text, detail: Text?, systemImage: String, destructive: Bool = false,
                fillsComposer: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.destructive = destructive
        self.fillsComposer = fillsComposer
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.xxs.points) {
                        title.tone(destructive ? .destructive : .primary)
                        if let detail { detail.textRole(.footnote).tone(.secondary) }
                    }
                } icon: {
                    Image(systemName: systemImage).tone(destructive ? .destructive : .secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: Spacing.xs.points)
                if fillsComposer {
                    Image(systemName: "text.cursor").textRole(.footnote).tone(.tertiary).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
