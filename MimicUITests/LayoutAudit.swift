import CoreGraphics
import Foundation

// MARK: - The tree a rule reads

/// One element of a window's accessibility tree, reduced to what the layout rules read.
///
/// Built from an `XCUIElementSnapshot` by `LayoutAuditUITests`, or written as a literal in the
/// rules' own fixtures. Frames are in screen points, the space XCUITest reports them in.
struct LayoutNode: Codable, Equatable, Sendable {
    var role: String
    var identifier: String
    var label: String
    var frame: CGRect
    var children: [LayoutNode]

    init(_ role: String, _ identifier: String = "", label: String = "", frame: CGRect, children: [LayoutNode] = []) {
        self.role = role
        self.identifier = identifier
        self.label = label
        self.frame = frame
        self.children = children
    }
}

/// An element with the context the rules need: which pane holds it, which scrolling container
/// moves it, and its ancestors, so a control inside another is never read as overlapping it.
struct LayoutElement: Equatable, Sendable {
    var node: LayoutNode
    /// Index path from the root, so ancestry is a prefix test.
    var path: [Int]
    /// The identifier of the nearest enclosing pane (`LayoutAudit.paneIdentifiers`), if any.
    var pane: String?
    /// The path of the nearest enclosing scrolling container, if any. Elements in a scroll view
    /// move under fixed chrome on purpose, so they are only compared with their own neighbours.
    var scrollContainer: [Int]?

    var frame: CGRect { node.frame }

    func isAncestor(of other: LayoutElement) -> Bool {
        path.count < other.path.count && Array(other.path.prefix(path.count)) == path
    }
}

// MARK: - Findings

struct LayoutFinding: Codable, Equatable, Sendable {
    enum Severity: String, Codable, Sendable {
        /// Fails the audit: geometry that is wrong whatever the design says.
        case error
        /// Reported in the contact sheet, never a failure, until its threshold is calibrated.
        case warning
    }

    var rule: String
    var severity: Severity
    var message: String
    /// Where to draw the marker, in screen points.
    var rect: CGRect
}

// MARK: - Rules

/// Geometry rules over one window's accessibility tree, and one over its screenshot.
///
/// Each rule states a property a careful tester checks by eye: nothing cut off by the window or
/// its pane, no two controls on top of each other, edges that line up, and no stretch of nothing
/// where content should be. The rules are deliberately about geometry, not the design: a moved
/// control that still lines up is the gallery snapshots' business, not this file's.
enum LayoutAudit {
    /// The workspace's panels, by the identifiers `WorkspaceShellLayout` and `WorkspaceView` give them.
    static let paneIdentifiers: Set<String> = ["sidebar", "centerPane", "inspector", "drawer"]

    /// Roles whose content scrolls under the chrome around it.
    static let scrollingRoles: Set<String> = ["scrollView", "table", "outline", "collectionView", "textView", "webView"]

    /// Roles a person reads or operates. Containers are left out: a group's frame is the union of
    /// its children, so it says nothing the children do not.
    static let leafRoles: Set<String> = [
        "button", "staticText", "textField", "secureTextField", "searchField", "popUpButton", "menuButton",
        "checkBox", "radioButton", "slider", "segmentedControl", "comboBox", "image", "link", "stepper",
        "disclosureTriangle", "toggle", "incrementArrow", "decrementArrow", "colorWell", "progressIndicator",
    ]

    /// Roles a person clicks or types into, for the overlap rule.
    static let controlRoles: Set<String> = [
        "button", "textField", "secureTextField", "searchField", "popUpButton", "menuButton", "checkBox",
        "radioButton", "slider", "segmentedControl", "comboBox", "link", "stepper", "disclosureTriangle",
        "toggle", "colorWell",
    ]

    /// Every element of `root` in depth-first order, with its pane and scroll container.
    static func flatten(_ root: LayoutNode) -> [LayoutElement] {
        var result: [LayoutElement] = []
        func visit(_ node: LayoutNode, path: [Int], pane: String?, scroll: [Int]?) {
            result.append(LayoutElement(node: node, path: path, pane: pane, scrollContainer: scroll))
            let childPane = paneIdentifiers.contains(node.identifier) ? node.identifier : pane
            let childScroll = scrollingRoles.contains(node.role) ? path : scroll
            for (index, child) in node.children.enumerated() {
                visit(child, path: path + [index], pane: childPane, scroll: childScroll)
            }
        }
        visit(root, path: [], pane: nil, scroll: nil)
        return result
    }

    /// Runs every tree rule over `root`, a window, whose own frame bounds everything in it.
    static func check(_ root: LayoutNode) -> [LayoutFinding] {
        let elements = flatten(root)
        return clipping(elements, window: root.frame)
            + overlaps(elements)
            + alignmentNearMisses(elements)
            + rowCentreNearMisses(elements)
    }

    static func isVisibleLeaf(_ element: LayoutElement) -> Bool {
        leafRoles.contains(element.node.role) && element.frame.width >= 1 && element.frame.height >= 1
    }

    /// Something cut off: partly outside the window, or partly outside the pane that holds it.
    ///
    /// Only the *partly* outside count. An element entirely outside its pane is one SwiftUI keeps in
    /// the tree while it is off screen, and an element inside a scroll view is clipped by the scroll
    /// view on purpose, so neither says anything about the layout.
    static func clipping(_ elements: [LayoutElement], window: CGRect, tolerance: CGFloat = 1) -> [LayoutFinding] {
        let panes = Dictionary(
            elements.filter { paneIdentifiers.contains($0.node.identifier) }.map { ($0.node.identifier, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        var findings: [LayoutFinding] = []
        for element in elements where isVisibleLeaf(element) && element.scrollContainer == nil {
            let frame = element.frame
            if isPartlyOutside(frame, of: window, tolerance: tolerance) {
                findings.append(LayoutFinding(
                    rule: "clipped-by-window", severity: .error,
                    message: "\(describe(element)) runs past the window edge (\(describe(frame)) in \(describe(window)))",
                    rect: frame
                ))
            } else if let pane = element.pane, let paneFrame = panes[pane],
                      isPartlyOutside(frame, of: paneFrame, tolerance: tolerance) {
                findings.append(LayoutFinding(
                    rule: "clipped-by-pane", severity: .error,
                    message: "\(describe(element)) runs past the \(pane) edge (\(describe(frame)) in \(describe(paneFrame)))",
                    rect: frame
                ))
            }
        }
        return findings
    }

    static func isPartlyOutside(_ frame: CGRect, of bounds: CGRect, tolerance: CGFloat) -> Bool {
        let inner = bounds.insetBy(dx: -tolerance, dy: -tolerance)
        return frame.intersects(bounds) && !inner.contains(frame)
    }

    /// Two controls, or a control and a text, drawn over each other.
    ///
    /// Compared only within one scrolling container (or none): a row scrolling under a pinned
    /// header overlaps it by design. A control inside another, or one whose frame contains the
    /// other's, is a composite such as a field and its clear button, not a collision.
    static func overlaps(_ elements: [LayoutElement], minimumOverlap: CGFloat = 2) -> [LayoutFinding] {
        let candidates = elements.filter {
            isVisibleLeaf($0) && (controlRoles.contains($0.node.role) || $0.node.role == "staticText")
        }
        var findings: [LayoutFinding] = []
        for (index, a) in candidates.enumerated() {
            for b in candidates[(index + 1)...] {
                guard a.scrollContainer == b.scrollContainer,
                      controlRoles.contains(a.node.role) || controlRoles.contains(b.node.role)
                        || (a.node.role == "staticText" && b.node.role == "staticText"),
                      !a.isAncestor(of: b), !b.isAncestor(of: a),
                      !a.frame.insetBy(dx: -0.5, dy: -0.5).contains(b.frame),
                      !b.frame.insetBy(dx: -0.5, dy: -0.5).contains(a.frame)
                else { continue }
                let shared = a.frame.intersection(b.frame)
                guard !shared.isNull, shared.width >= minimumOverlap, shared.height >= minimumOverlap else { continue }
                findings.append(LayoutFinding(
                    rule: "overlap", severity: .error,
                    message: "\(describe(a)) and \(describe(b)) overlap by \(describe(shared.size))",
                    rect: shared
                ))
            }
        }
        return findings
    }

    /// A leading edge one to three points off an edge two or more of its neighbours share.
    ///
    /// The signature of a misaligned column: things meant to line up that a padding or an icon
    /// slot pushed slightly out. Exact matches and clearly different columns are both fine; only
    /// the near miss reads as a mistake. Compared within one pane and one scroll container.
    static func alignmentNearMisses(_ elements: [LayoutElement]) -> [LayoutFinding] {
        let leaves = elements.filter(isVisibleLeaf)
        let groups = Dictionary(grouping: leaves) { GroupKey(pane: $0.pane, scroll: $0.scrollContainer) }
        var findings: [LayoutFinding] = []
        for (_, members) in groups where members.count >= 3 {
            let edges = members.map { ($0.frame.minX * 2).rounded() / 2 }
            let counts = Dictionary(edges.map { ($0, 1) }, uniquingKeysWith: +)
            let columns = counts.filter { $0.value >= 2 }.map(\.key)
            for (element, edge) in zip(members, edges) where (counts[edge] ?? 0) == 1 {
                guard let column = columns.min(by: { abs($0 - edge) < abs($1 - edge) }),
                      abs(column - edge) >= 1, abs(column - edge) <= 3
                else { continue }
                findings.append(LayoutFinding(
                    rule: "alignment-near-miss", severity: .warning,
                    message: "\(describe(element)) starts at x=\(format(edge)), \(format(abs(column - edge)))pt off the column at x=\(format(column)) that \(counts[column] ?? 0) neighbours share",
                    rect: element.frame
                ))
            }
        }
        return findings
    }

    /// Two elements side by side on one row whose vertical centres differ by one to three points.
    static func rowCentreNearMisses(_ elements: [LayoutElement]) -> [LayoutFinding] {
        let leaves = elements.filter { isVisibleLeaf($0) && $0.frame.height <= 40 }
        var findings: [LayoutFinding] = []
        for (index, a) in leaves.enumerated() {
            for b in leaves[(index + 1)...] {
                guard a.pane == b.pane, a.scrollContainer == b.scrollContainer,
                      !a.isAncestor(of: b), !b.isAncestor(of: a)
                else { continue }
                let verticalShare = min(a.frame.maxY, b.frame.maxY) - max(a.frame.minY, b.frame.minY)
                let gap = max(a.frame.minX, b.frame.minX) - min(a.frame.maxX, b.frame.maxX)
                guard verticalShare >= 0.6 * min(a.frame.height, b.frame.height), gap >= 0, gap <= 24 else { continue }
                let offset = abs(a.frame.midY - b.frame.midY)
                guard offset >= 1.5, offset <= 3 else { continue }
                findings.append(LayoutFinding(
                    rule: "row-centre-near-miss", severity: .warning,
                    message: "\(describe(a)) and \(describe(b)) share a row but their centres are \(format(offset))pt apart",
                    rect: a.frame.union(b.frame)
                ))
            }
        }
        return findings
    }

    /// The leading inset of each pane's content, for the contact sheet's padding table, and a
    /// warning when one is off the 2pt grid every spacing token sits on.
    static func paneInsets(_ elements: [LayoutElement]) -> (insets: [String: CGFloat], findings: [LayoutFinding]) {
        var insets: [String: CGFloat] = [:]
        var findings: [LayoutFinding] = []
        let panes = elements.filter { paneIdentifiers.contains($0.node.identifier) }
        for pane in panes {
            let contents = elements.filter {
                $0.pane == pane.node.identifier && isVisibleLeaf($0) && $0.frame.minX > pane.frame.minX + 0.5
            }
            guard let first = contents.min(by: { $0.frame.minX < $1.frame.minX }) else { continue }
            let inset = ((first.frame.minX - pane.frame.minX) * 2).rounded() / 2
            insets[pane.node.identifier] = inset
            if inset.truncatingRemainder(dividingBy: 2) != 0 {
                findings.append(LayoutFinding(
                    rule: "off-grid-inset", severity: .warning,
                    message: "The \(pane.node.identifier) content starts \(format(inset))pt in, off the 2pt spacing grid (\(describe(first)))",
                    rect: first.frame
                ))
            }
        }
        return (insets, findings)
    }

    struct GroupKey: Hashable {
        var pane: String?
        var scroll: [Int]?
    }

    static func describe(_ element: LayoutElement) -> String {
        let name = element.node.identifier.isEmpty ? element.node.label : element.node.identifier
        let shown = name.count > 48 ? String(name.prefix(47)) + "…" : name
        return shown.isEmpty ? element.node.role : "\(element.node.role) '\(shown)'"
    }

    static func describe(_ rect: CGRect) -> String {
        "\(format(rect.minX)),\(format(rect.minY)) \(format(rect.width))×\(format(rect.height))"
    }

    static func describe(_ size: CGSize) -> String { "\(format(size.width))×\(format(size.height))pt" }

    static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}

// MARK: - Empty space

/// The tallest stretch of a pane that is nothing but its background, read off a screenshot.
///
/// Rows, not rectangles: a blank band across a pane is what reads as "unwanted empty space"
/// (an editor that stops halfway down, a list that leaves a gap above its footer), and a row scan
/// is cheap enough to run on every frame of the sweep.
struct BlankSpaceScan: Sendable {
    /// RGBA8, row-major, `width * 4` bytes per row, top row first.
    let pixels: [UInt8]
    let width: Int
    let height: Int

    /// A channel difference at or below this counts as the background.
    static let tolerance = 6

    init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(pixels: pixels, width: width, height: height)
    }

    private func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = (y * width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    /// The most common colour on a sparse grid over `rect`, which in a pane is its background.
    func background(in rect: PixelRect) -> (Int, Int, Int)? {
        var counts: [Int: Int] = [:]
        let stepX = max(1, rect.width / 24)
        let stepY = max(1, rect.height / 24)
        for y in stride(from: rect.minY, to: rect.maxY, by: stepY) {
            for x in stride(from: rect.minX, to: rect.maxX, by: stepX) {
                let (r, g, b) = pixel(x, y)
                counts[(r << 16) | (g << 8) | b, default: 0] += 1
            }
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return ((key >> 16) & 0xFF, (key >> 8) & 0xFF, key & 0xFF)
    }

    /// The tallest run of rows inside `rect` in which every pixel matches the background, as
    /// `(first row, row count)` in pixels. Two pixels in from each side, so a pane's own border or
    /// a scroll bar track does not interrupt a run.
    func tallestBlankRun(in rect: PixelRect) -> (start: Int, length: Int) {
        let clamped = rect.clamped(width: width, height: height)
        guard clamped.width > 4, clamped.height > 0, let background = background(in: clamped) else { return (0, 0) }
        var best = (start: 0, length: 0)
        var runStart = clamped.minY
        var runLength = 0
        for y in clamped.minY..<clamped.maxY {
            var blank = true
            for x in (clamped.minX + 2)..<(clamped.maxX - 2) {
                let (r, g, b) = pixel(x, y)
                if abs(r - background.0) > Self.tolerance || abs(g - background.1) > Self.tolerance
                    || abs(b - background.2) > Self.tolerance {
                    blank = false
                    break
                }
            }
            if blank {
                if runLength == 0 { runStart = y }
                runLength += 1
                if runLength > best.length { best = (runStart, runLength) }
            } else {
                runLength = 0
            }
        }
        return best
    }
}

/// A rectangle in image pixels, top-left origin.
struct PixelRect: Equatable, Sendable {
    var minX: Int
    var minY: Int
    var width: Int
    var height: Int

    var maxX: Int { minX + width }
    var maxY: Int { minY + height }

    func clamped(width imageWidth: Int, height imageHeight: Int) -> PixelRect {
        let x0 = max(0, min(minX, imageWidth))
        let y0 = max(0, min(minY, imageHeight))
        let x1 = max(x0, min(maxX, imageWidth))
        let y1 = max(y0, min(maxY, imageHeight))
        return PixelRect(minX: x0, minY: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension LayoutAudit {
    /// Warns when a pane holds a blank band at least `minimumPoints` tall and `minimumFraction` of
    /// the pane. A pane showing an empty state is skipped: centred empty states are mostly space by
    /// design.
    static func blankSpace(
        _ elements: [LayoutElement],
        window: CGRect,
        scan: BlankSpaceScan,
        minimumPoints: CGFloat = 120,
        minimumFraction: CGFloat = 0.4
    ) -> [LayoutFinding] {
        guard window.width > 0 else { return [] }
        let scale = CGFloat(scan.width) / window.width
        var findings: [LayoutFinding] = []
        for pane in elements where paneIdentifiers.contains(pane.node.identifier) {
            let showsEmptyState = elements.contains {
                $0.pane == pane.node.identifier && $0.node.identifier.hasPrefix("ds.empty")
            }
            guard !showsEmptyState, pane.frame.height >= minimumPoints else { continue }
            let local = pane.frame.offsetBy(dx: -window.minX, dy: -window.minY)
            let rect = PixelRect(
                minX: Int((local.minX * scale).rounded()), minY: Int((local.minY * scale).rounded()),
                width: Int((local.width * scale).rounded()), height: Int((local.height * scale).rounded())
            )
            let run = scan.tallestBlankRun(in: rect)
            let points = CGFloat(run.length) / scale
            guard points >= minimumPoints, points >= minimumFraction * pane.frame.height else { continue }
            let band = CGRect(
                x: pane.frame.minX, y: window.minY + CGFloat(run.start) / scale,
                width: pane.frame.width, height: points
            )
            findings.append(LayoutFinding(
                rule: "blank-space", severity: .warning,
                message: "The \(pane.node.identifier) pane has a blank band \(format(points))pt tall, \(Int((points / pane.frame.height * 100).rounded()))% of its height",
                rect: band
            ))
        }
        return findings
    }
}
