import UIKit

/// Presenting from a menu item (brief item 6): on Arthur's iPhone, "+ › Commands" only closed the
/// menu on a tap: the sheet was asked for while the menu was still on its way out, and UIKit
/// presents one thing at a time. So a menu item asks for its sheet here, which waits until no
/// presentation is in transition and no context menu is left on screen (at most a second).
@MainActor
enum Presentation {
    static func afterMenu(_ present: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            // The menu starts leaving after the item's action returns.
            await Task.yield()
            let deadline = ContinuousClock.now + .seconds(1)
            while busy(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            present()
        }
    }

    /// A presentation or dismissal in flight, or a menu's container still in a window.
    static func busy() -> Bool {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !window.isHidden {
                var vc = window.rootViewController
                while let v = vc {
                    if v.isBeingPresented || v.isBeingDismissed || v.transitionCoordinator != nil { return true }
                    vc = v.presentedViewController
                }
                // UIKit's menus (UIContextMenuInteraction) live in a container view of their own
                // while shown and animating out.
                if window.subviews.contains(where: { String(describing: type(of: $0)).contains("ContextMenu") }) { return true }
            }
        }
        return false
    }
}
