import Cocoa

// MARK: - Inline Box Attachment

/// An NSTextAttachment that renders as a rounded, glass-morphic inline box.
/// Used for diagnostics, ghost completions, and Pythia's whispers.
final class InlineBoxAttachment: NSTextAttachment {

    enum Kind {
        case suggestion   // dim ghost completion
        case diagnostic   // warning / error
        case oracle       // Pythia's inline response
        case pill         // small rounded tag

        var icon: String {
            switch self {
            case .suggestion: return "→"
            case .diagnostic: return "⚠️"
            case .oracle:     return "🐍"
            case .pill:       return ""
            }
        }
    }

    let kind: Kind
    let message: String
    private let boxWidth: CGFloat

    init(kind: Kind, message: String, boxWidth: CGFloat? = nil) {
        self.kind = kind
        self.message = message
        self.boxWidth = boxWidth ?? Self.measure(message: message, font: Self.font)
        super.init(data: nil, ofType: nil)

        attachmentCell = InlineBoxCell(kind: kind, message: message, boxWidth: self.boxWidth)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not for hermetic constructs") }

    // MARK: - Sizing

    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    static private let iconSize: CGFloat = 16
    static private let paddingX: CGFloat = 8
    static private let paddingY: CGFloat = 3

    static func measure(message: String, font: NSFont) -> CGFloat {
        let iconW: CGFloat = 20
        let textW = (message as NSString).size(withAttributes: [.font: font]).width
        return iconW + textW + paddingX * 2 + 4
    }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: -3, width: boxWidth, height: lineFrag.height + 2)
    }
}

// MARK: - Inline Box Cell

final class InlineBoxCell: NSTextAttachmentCell {

    private let kind: InlineBoxAttachment.Kind
    private let message: String
    private let boxWidth: CGFloat

    init(kind: InlineBoxAttachment.Kind, message: String, boxWidth: CGFloat) {
        self.kind = kind
        self.message = message
        self.boxWidth = boxWidth
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not for hermetic constructs") }

    override func cellSize() -> NSSize {
        NSSize(width: boxWidth, height: 18)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        drawHermeticBox(in: cellFrame)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        drawHermeticBox(in: cellFrame)
    }

    private func drawHermeticBox(in rect: NSRect) {
        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()

        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1), xRadius: 6, yRadius: 6)

        // Fill
        switch kind {
        case .suggestion:
            NSColor.white.withAlphaComponent(0.06).setFill()
        case .diagnostic:
            NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 1).withAlphaComponent(0.12).setFill()
        case .oracle:
            NSColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1).withAlphaComponent(0.15).setFill()
        case .pill:
            NSColor.white.withAlphaComponent(0.08).setFill()
        }
        path.fill()

        // Border
        switch kind {
        case .suggestion:
            NSColor.white.withAlphaComponent(0.10).setStroke()
        case .diagnostic:
            NSColor(red: 1, green: 0.7, blue: 0.3, alpha: 1).withAlphaComponent(0.3).setStroke()
        case .oracle:
            NSColor(red: 0.7, green: 0.5, blue: 0.9, alpha: 1).withAlphaComponent(0.3).setStroke()
        case .pill:
            NSColor.white.withAlphaComponent(0.12).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        // Icon + text
        let icon = kind.icon
        let font = InlineBoxAttachment.font

        if !icon.isEmpty {
            let iconAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
            let iconW: CGFloat = 18
            (icon as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 2), withAttributes: iconAttrs)

            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.65)
            ]
            (message as NSString).draw(at: NSPoint(x: rect.minX + iconW + 2, y: rect.minY + 2),
                                        withAttributes: textAttrs)
        } else {
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.65)
            ]
            let textSize = (message as NSString).size(withAttributes: textAttrs)
            let x = rect.minX + (rect.width - textSize.width) / 2
            (message as NSString).draw(at: NSPoint(x: x, y: rect.minY + 2), withAttributes: textAttrs)
        }

        ctx?.restoreGraphicsState()
    }
}