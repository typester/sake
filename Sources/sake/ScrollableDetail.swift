import SwiftUI

extension View {
    /// A detail pane that scrolls rather than pushing itself out of its own window.
    ///
    /// **A `Text` with `.fixedSize(horizontal: false, vertical: true)` in the pane makes the
    /// pane demand a height the window does not have to offer.** The demand reaches the
    /// `NavigationSplitView`, which is then laid out taller than the window and centred in
    /// it, so the content leaves the visible area upwards and the window draws empty —
    /// while the accessibility tree still reports every string. Measured against the
    /// library window on 2026-09-21: the pane stopped tracking the window's height as soon
    /// as a title with arguments was selected, and tracked it again with the modifier gone.
    ///
    /// Scrolling keeps the modifier, which is there to let a long value wrap instead of
    /// being truncated, and bounds what the demand can do. `SetupWindow` already does this.
    func scrollableDetail() -> some View {
        ScrollView {
            self.frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
