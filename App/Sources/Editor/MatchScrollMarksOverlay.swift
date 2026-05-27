import UIKit
import EditorEngine

/// Thin trailing-edge strip; one tick per live-match hit's y
/// position. Scrolls with content via subview parking.
final class MatchScrollMarksOverlay: UIView {

    weak var host: EditorEngine.TextView?

    var matchRanges: [NSRange] = [] {
        didSet { if matchRanges != oldValue { setNeedsLayout() } }
    }

    private static let stripWidth: CGFloat = 4

    init(host: EditorEngine.TextView) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host else { return }
        let cs = host.contentSize
        let x = max(0, cs.width - Self.stripWidth)
        frame = CGRect(x: x, y: 0, width: Self.stripWidth, height: cs.height)
        rebuildTicks()
    }

    private func rebuildTicks() {
        guard let host else { return }
        subviews.forEach { $0.removeFromSuperview() }
        let textLength = (host.text as NSString).length
        for range in matchRanges {
            let clamped = max(0, min(range.location, textLength))
            let rect = host.caretRect(atCharacterIndex: clamped)
            guard rect.height > 0, rect.minY.isFinite else { continue }
            let tick = UIView(frame: CGRect(
                x: 0,
                y: rect.minY + rect.height / 2 - 1,
                width: bounds.width,
                height: 2
            ))
            tick.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.7)
            tick.layer.cornerRadius = 1
            addSubview(tick)
        }
    }
}
