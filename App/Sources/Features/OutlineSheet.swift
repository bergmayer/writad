import SwiftUI

/// ATX-heading outline for `OutlineSidebar`. Linear line scan,
/// rerun on every show — no caching needed under MB scale.
@MainActor
enum OutlineBuilder {

    struct Heading: Identifiable {
        let id = UUID()
        let level: Int        // 1–6
        let text: String      // heading body, sans `#` markers
        let lineStart: Int    // character offset of the heading line
    }

    static func build() -> [Heading] {
        guard let text = AppStateBus.shared.scenes.currentSession?.activeTab.document.text else {
            return []
        }
        let nsText = text as NSString
        var headings: [Heading] = []
        var scan = 0
        while scan < nsText.length {
            let line = nsText.lineRange(for: NSRange(location: scan, length: 0))
            var body = nsText.substring(with: line)
            if body.hasSuffix("\n") { body.removeLast() }
            if body.hasSuffix("\r") { body.removeLast() }
            if let h = headingMatch(body) {
                headings.append(Heading(level: h.level, text: h.text, lineStart: line.location))
            }
            scan = line.location + line.length
        }
        return headings
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard let first = rest.first, first == " " else { return nil }
        return (hashes, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }
}
