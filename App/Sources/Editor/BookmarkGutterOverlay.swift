import UIKit
import EditorEngine

/// Lives as a subview of the engine's scroll view so its badges
/// scroll with the content. One numbered badge per bookmark slot
/// (0–9). Repaints in `layoutSubviews` and whenever `bookmarks` is
/// reassigned.
final class BookmarkGutterOverlay: UIView {

    weak var host: EditorEngine.TextView?

    var bookmarks: [Int: Int] = [:] {
        didSet { if bookmarks != oldValue { setNeedsLayout() } }
    }

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
        // Cover the full content area so children in content
        // coordinates scroll with the engine.
        let cs = host.contentSize
        let width = max(host.gutterWidth, 16)
        frame = CGRect(x: 0, y: 0, width: width, height: cs.height)
        rebuildBadges()
    }

    private func rebuildBadges() {
        guard let host else { return }
        // At most 10 badges — cheap to recreate, no risk of leaking
        // views when slots reshuffle.
        subviews.forEach { $0.removeFromSuperview() }

        let textLength = (host.text as NSString).length
        let order = bookmarks.keys.sorted()
        for slot in order {
            guard let location = bookmarks[slot] else { continue }
            // Stale bookmark past EOF — possible after an external
            // edit shrank the file.
            let clamped = max(0, min(location, textLength))
            let rect = host.caretRect(atCharacterIndex: clamped)
            guard rect.height > 0, rect.height.isFinite, rect.minY.isFinite else { continue }
            let badge = makeBadge(slot: slot)
            let size = CGSize(width: 16, height: 16)
            // Right-aligned in the gutter so it sits between line
            // numbers and text — visible without pushing the numbers.
            let x = max(0, bounds.width - size.width - 2)
            let y = rect.minY + max(0, (rect.height - size.height) / 2)
            badge.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            addSubview(badge)
        }
    }

    private func makeBadge(slot: Int) -> UIView {
        let label = UILabel()
        label.text = "\(slot)"
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = .tintColor
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        return label
    }
}
