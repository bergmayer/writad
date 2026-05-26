import UIKit

/// Container view that returns `nil` from `hitTest` unless one of its
/// subviews actually claims the point. Used by the gutter so that empty
/// gutter space (line-number background, blank rows) passes touches and
/// pointer clicks through to the text view's caret/selection behaviour.
final class HitTestPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return (hit === self) ? nil : hit
    }
}
