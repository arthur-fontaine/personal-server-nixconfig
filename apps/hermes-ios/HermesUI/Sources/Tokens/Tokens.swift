import SwiftUI
import WidgetKit

// The only file with layout numbers (design-rules 2.3, 9.2). Everything public is a type, never a
// number: screens say `.m` or `.turn`, components turn it into points here. DesignCheck fails the
// build on a layout literal anywhere else.

/// The spacing scale, a 4-pt grid (design-rules 2.3).
public enum Spacing: CaseIterable, Sendable {
    case xxs, xs, s, m, l, xl, xxl

    var points: CGFloat {
        switch self {
        case .xxs: 4
        case .xs: 8
        case .s: 12
        case .m: 16
        case .l: 20
        case .xl: 24
        case .xxl: 32
        }
    }
}

/// Vertical rhythm of a conversation (design-rules 2.4, 12.3): one gap per relation, never
/// chosen per screen.
public enum Rhythm: Sendable {
    /// Between two speakers' turns.
    case turn
    /// Between two of the owner's bubbles in one turn.
    case bubbles
    /// Between the blocks of Hermes' reply (paragraphs, code, the card).
    case blocks

    var spacing: Spacing {
        switch self {
        case .turn: .xl
        case .bubbles: .xs
        case .blocks: .m
        }
    }
}

/// Sizes that aren't spacing. Internal: components pick them, screens can't.
enum Metric {
    /// HIG Accessibility: minimum hit target.
    static let hitTarget: CGFloat = 44
    /// The composer's gap above the keyboard: the one it has above the home indicator (the
    /// indicator's top is 13 pt above the screen's edge in the 34-pt safe area: 34 − 13 = 21,
    /// on the grid 20), so it doesn't sit on the keys (brief item 2).
    static let keyboardGap: CGFloat = Spacing.l.points
    /// `DownloadRow`'s ring: the system's circular capacity gauge (drawn for widgets, ≈ 58 pt)
    /// brought to a 32-pt ring inside the 44-pt hit target, as the App Store's.
    static let downloadRingScale: CGFloat = 32.0 / 58.0
    /// `.controlSize(.large)` bordered button height on iOS 26 at the default text size (measured
    /// on the simulator: 52). Only the starting value: `ApprovalCard` measures the real height.
    static let largeControl: CGFloat = 52
    /// The composer's field and "+" button: the hit target, a little taller than Messages' 40
    /// (reference/metrics.md), so every control on the bar is ≥ 44 pt.
    static let composerControl: CGFloat = hitTarget
    /// The send button inside the field: concentric with it (22 − 4 = 18 = 36 / 2).
    static let sendButton: CGFloat = composerControl - 2 * Spacing.xxs.points
    /// Readable measure on wide screens: ≈ 75 characters of `.body` (HIG Layout, design-rules 2.2).
    static let readableWidth: CGFloat = 672
    /// The owner's bubble leaves at least this on its leading side: 370 − 72 = 298 pt, ≈ 80 % of
    /// an iPhone column (design-rules 12.4).
    static let bubbleLeadingRoom: CGFloat = 72
    /// One rendered line of `.body` at the default size (measured: 20.33 pt; the 22 of "17/22" is
    /// the leading between lines). Used where a view must be as tall as a line of text.
    static let bodyLine: CGFloat = 20
    /// The owner's one-line bubble (design-rules 12.1: 46–48): its minimum height, the text centred
    /// in it; its corner is half of it, so one line is a capsule.
    static let oneLineBubble: CGFloat = 48
    /// The approval card's height cap at accessibility sizes; beyond it the card scrolls, as
    /// system alerts do, so the conversation keeps room.
    static let cardMaxHeightAX: CGFloat = 360
    /// The padding `.bordered` puts around its label at `.controlSize(.large)` (measured on the
    /// iOS 26.2 simulator: a 20.33-pt square label gives a 60.33 × 50.33 button). A label of
    /// (row − 2 × horizontal) × (row − 2 × vertical) makes the button a square as tall as the row,
    /// so its `.circle` border is a full circle; GeometryTests checks it is round and of the row's
    /// height.
    static let largeButtonHorizontalPadding: CGFloat = 20
    static let largeButtonVerticalPadding: CGFloat = 15

    /// The label that makes a `.large` bordered button a square `rowHeight` tall.
    static func squareLargeButtonLabel(rowHeight: CGFloat) -> CGSize {
        CGSize(width: max(rowHeight - 2 * largeButtonHorizontalPadding, 0),
               height: max(rowHeight - 2 * largeButtonVerticalPadding, 0))
    }
    /// The fade over a code block's trailing edge when its text runs past it (13.1).
    static let codeFade: CGFloat = Spacing.xl.points
    /// A square's ratio, and the unit cell of a sprite.
    static let square: CGFloat = 1
    /// One pixel, counting inclusive pixel bounds.
    static let pixel: CGFloat = 1
    /// A sparkline under a list row (a third of a row's width tall on iPhone, as Battery's).
    static let chartHeight: CGFloat = 64
    static let chartTicks = 3
    /// Past this, usage is shown in red.
    static let criticalUsage = 0.9
    /// A first-run step's column on wide screens (one field, one button).
    static let onboardingWidth: CGFloat = 440
    /// A first-run step's text field: a large control's height.
    static let fieldHeight: CGFloat = 52
    /// The call's live caption: about six lines of `.body`.
    static let captionHeight: CGFloat = 180
    /// A call control (the Phone app's are about this size).
    static let callButton: CGFloat = 72
    /// A call control's column: the button and the gap the Phone app leaves between two (96 pt).
    static let callColumn: CGFloat = callButton + Spacing.xl.points
    /// A pre-rendered still for the widgets and the Live Activity: the medium widget's pet at @3x.
    static let stillPixels: CGFloat = 288
    /// The Live Activity's still: its 48-pt pet at @2x (pixel art, scaled without smoothing), small
    /// enough for ActivityKit to draw.
    static let activityStillPixels: CGFloat = 96
    /// Typing indicator dot.
    static let typingDot: CGFloat = 6
    /// A quote's leading rule (Mail's quote bar).
    static let quoteRule: CGFloat = 3
    /// A reply's leading bar: as thick as a quote's rule (16.1).
    static let replyBar: CGFloat = quoteRule
    /// How far a message follows the finger before a swipe replies (Messages: about 60 pt).
    static let replySwipe: CGFloat = 64
    /// A reply context's narrowest, over a short bubble: room for "Hermes" and a few words.
    static let replyMinWidth: CGFloat = 160
    /// File card's leading symbol box.
    static let fileSymbol: CGFloat = 40
    static let fileCardMaxWidth: CGFloat = 360
    /// A sidebar row's icon column, measured on the iPad sidebar's own rows (label ink at 77.5 pt,
    /// icon centred at 53.75): from the row's 12-pt inset, 30 wide then 8 puts the label exactly on
    /// the list's and the icon within ¾ pt of its centre.
    static let sidebarIconColumn: CGFloat = 30
    /// A sidebar row's height (the iPad sidebar's own rows measure 52 pt).
    static let sidebarRow: CGFloat = 52
    /// A grouped row's icon column (the system's, for SF Symbols at body size).
    static let rowIcon: CGFloat = 28
    /// A system bar item's height (measured: Apple's trailing items and our pet's glass circle
    /// are 36 pt): a custom view in the bar is padded sideways only, so it must be this tall for
    /// its glass to be a circle.
    static let barItem: CGFloat = 36
    /// Sidebar column width on iPad.
    static let sidebarMin: CGFloat = 280
    static let sidebarIdeal: CGFloat = 320
    static let sidebarMax: CGFloat = 360
}

/// Corner radii. All derived: a radius is an inset plus the radius of what's inside, never a
/// free number (design-rules 5.1).
enum Radius {
    /// A card holding a row of `.large` capsules, `inset` from its edge: concentric.
    static func card(inset: Spacing, innerControlHeight: CGFloat) -> CGFloat {
        inset.points + innerControlHeight / 2
    }

    /// The owner's bubble: a capsule at one line (half the one-line height), the same corner as it
    /// grows (Messages, reference/metrics.md).
    static let bubble: CGFloat = Metric.oneLineBubble / 2

    /// A free-standing block in the conversation (code): the corner a concentric block falls back
    /// to when no container gives it one — its own padding, so the text sits in the corner's
    /// straight part.
    static let blockMinimum: CGFloat = Block.padding.points
}

extension Radius {
    /// A first-run step's field: half its height, as round as the large buttons beside it.
    static let field: CGFloat = Metric.fieldHeight / 2
    /// The composer's field: a capsule at one line, the same corner as it grows.
    static let composerField: CGFloat = Metric.composerControl / 2
}

/// The owner's bubble (design-rules 12.1, reference/metrics.md: ChatGPT and Claude ≈ 16 × 14):
/// 16 × 12, a 46-pt capsule at one line.
enum Bubble {
    static let horizontal: Spacing = .m
    static let vertical: Spacing = .s
}

/// Inner padding of chat surfaces (design-rules 12.2).
enum Block {
    /// Code blocks.
    static let padding: Spacing = .m
    /// The approval card.
    static let card: Spacing = .l
}

/// Pet sprite sizes (the sprite is 192×208, so the frame keeps that ratio).
public enum PetSize: Hashable, Sendable {
    /// Inside a toolbar button: the system draws its 44-pt glass circle around it.
    case toolbar
    /// A list row's leading image.
    case row
    /// The top of the pet sheet.
    case hero
    /// Full screen (call, launch).
    case stage
    /// The Dynamic Island's compact leading side.
    case island
    /// A Live Activity on the lock screen, the expanded Dynamic Island.
    case activity
    /// A medium Home Screen widget.
    case widget

    var width: CGFloat {
        switch self {
        case .island: 24
        case .toolbar: 28
        case .row: 40
        case .activity: 48
        case .widget: 96
        case .hero: 128
        case .stage: 200
        }
    }

    static let aspect: CGFloat = 208.0 / 192.0
    /// Width over height of a sprite cell, for `aspectRatio` (uniform scaling, design-rules 10.2).
    static let spriteRatio: CGFloat = 192.0 / 208.0
}

/// Icon-only buttons' sizes (design-rules 10.1): a square, so the circle is a circle.
public enum IconSize: Sendable {
    /// The hit target: the composer's "+".
    case regular
    /// A `.large` control's height.
    case large

    var points: CGFloat {
        switch self {
        case .regular: Metric.hitTarget
        case .large: Metric.largeControl
        }
    }
}

/// The heart a caress leaves on the bar's pet (design-rules 11.3).
enum HeartBadge {
    /// A third of the pet's toolbar size: visible, not covering its face.
    static let pointSize: CGFloat = PetSize.toolbar.width / 3
    /// How long it stays.
    static let seconds = 1.0
}

/// How long the heart a caress leaves stays, for the app's timing.
public enum CaressTiming {
    public static var heart: Duration { .seconds(HeartBadge.seconds) }
}

/// The review gallery's widget and activity sizes on a 6.3-inch iPhone (HIG Widgets,
/// "Specifications"; the Dynamic Island's compact and expanded shapes).
enum WidgetCanvas {
    static let wide: CGFloat = 364
    static let corner: CGFloat = 24
    static let islandCorner: CGFloat = 44
    static let islandCompact = CGSize(width: 250, height: 37)

    static func size(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: wide, height: 170)
        case .accessoryCircular: CGSize(width: 76, height: 76)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 257, height: 26)
        default: CGSize(width: wide, height: 382)
        }
    }
}
