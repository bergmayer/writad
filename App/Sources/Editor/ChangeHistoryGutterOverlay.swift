import UIKit
import EditorEngine

/// VS Code-style change bars on the inside edge of the line-number
/// gutter — green = added line, yellow = modified, red wedge =
/// deletion. Cheap parallel walk over baseline + current `[String]`;
/// could move to `CollectionDifference` if needed for huge files.
final class ChangeHistoryGutterOverlay: UIView {

    weak var host: EditorEngine.TextView?

    var baseline: [String] = [] {
        didSet { if baseline != oldValue { setNeedsLayout() } }
    }
    var current: [String] = [] {
        didSet { if current != oldValue { setNeedsLayout() } }
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
        // Sit at `x == gutterWidth`, in the `textContainerInset.left`
        // margin. Inside the gutter is unreachable: the engine calls
        // `bringSubviewToFront(gutterContainerView)` in its own
        // layoutSubviews and would cover any sibling we parked there.
        frame = CGRect(x: host.gutterWidth, y: 0, width: Self.stripWidth, height: cs.height)
        rebuild()
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        guard let host else { return }
        guard !baseline.isEmpty || !current.isEmpty else { return }

        // For each current line, classify against the matching
        // baseline index: same text = no bar, different = modified,
        // past baseline range = added.
        let maxIdx = current.count
        var i = 0
        let bCount = baseline.count
        while i < maxIdx {
            let baselineLine: String? = i < bCount ? baseline[i] : nil
            let kind: BarKind?
            if let baselineLine {
                kind = baselineLine == current[i] ? nil : .modified
            } else {
                kind = .added
            }
            if let kind {
                addBar(forLine: i, kind: kind, host: host)
            }
            i += 1
        }
        // Anchor the deletion wedge to the last existing row — there
        // is no row at the deleted lines themselves.
        if bCount > current.count {
            let anchorLine = max(0, current.count - 1)
            addBar(forLine: anchorLine, kind: .deleted, host: host)
        }
    }

    private enum BarKind {
        case added, modified, deleted
        var color: UIColor {
            switch self {
            case .added:    return UIColor.systemGreen.withAlphaComponent(0.7)
            case .modified: return UIColor.systemYellow.withAlphaComponent(0.75)
            case .deleted:  return UIColor.systemRed.withAlphaComponent(0.7)
            }
        }
    }

    private func addBar(forLine line: Int, kind: BarKind, host: EditorEngine.TextView) {
        // Linear scan to find the line start. The engine's
        // contentSize-driven layout already throttles us so the cost
        // stays bounded.
        let nsText = host.text as NSString
        var scan = 0
        var current = 0
        var lineStart = 0
        while scan < nsText.length {
            let lr = nsText.lineRange(for: NSRange(location: scan, length: 0))
            if current == line {
                lineStart = lr.location
                break
            }
            scan = lr.location + lr.length
            current += 1
        }
        let rect = host.caretRect(atCharacterIndex: lineStart)
        guard rect.height > 0, rect.height.isFinite, rect.minY.isFinite else { return }
        let bar = UIView(frame: CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height))
        bar.backgroundColor = kind.color
        bar.layer.cornerRadius = bounds.width / 2
        addSubview(bar)
    }
}
