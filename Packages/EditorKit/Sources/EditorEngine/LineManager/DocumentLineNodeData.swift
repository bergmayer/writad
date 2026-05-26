import CoreGraphics
import Foundation

final class DocumentLineNodeData {
    var delimiterLength = 0 {
        didSet {
            assert(delimiterLength >= 0 && delimiterLength <= 2)
        }
    }
    var totalLength = 0
    var length: Int {
        totalLength - delimiterLength
    }
    /// Storage height — the engine's natural laid-out height for this line.
    /// `lineHeight` (below) returns 0 when the line is part of a folded
    /// range; `naturalLineHeight` keeps the original so we can restore on
    /// unfold without retypesetting.
    var naturalLineHeight: CGFloat
    var lineHeight: CGFloat {
        get { isHidden ? 0 : naturalLineHeight }
        set { naturalLineHeight = newValue }
    }
    /// True when the line is currently folded out of view. The line still
    /// exists in the document text (so undo / find / encoding / save all
    /// see the original content); only its on-screen presence is gated.
    var isHidden: Bool = false
    var totalLineHeight: CGFloat = 0
    var nodeTotalByteCount = ByteCount(0)
    var startByte: ByteCount {
        node!.tree.startByte(of: node!)
    }
    var byteCount = ByteCount(0)
    var byteRange: ByteRange {
        ByteRange(location: startByte, length: byteCount - ByteCount(delimiterLength))
    }
    var totalByteRange: ByteRange {
        ByteRange(location: startByte, length: byteCount)
    }

    weak var node: DocumentLineNode?

    init(lineHeight: CGFloat) {
        self.naturalLineHeight = lineHeight
    }
}

private extension DocumentLineTree {
    func startByte(of node: Node) -> ByteCount {
        offset(of: node, valueKeyPath: \.data.byteCount, totalValueKeyPath: \.data.nodeTotalByteCount, minimumValue: ByteCount(0))
    }
}

extension DocumentLineNodeData: CustomDebugStringConvertible {
    var debugDescription: String {
        "[DocumentLineNodeData length=\(length) delimiterLength=\(delimiterLength) totalLength=\(totalLength)]"
    }
}
