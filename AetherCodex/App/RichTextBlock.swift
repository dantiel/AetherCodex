import AppKit

/// A minimal CSS-style box model for rich-text block elements, mapped onto
/// TextKit's `NSTextBlock` primitive. The box is content → padding → border →
/// margin, with an explicit width that defaults to 100% of the text column so
/// structural blocks (code fences, quotes, and future callouts/panels) span the
/// full column instead of hugging their content.
///
/// This is the "simplified HTML box model" of the WYSIWYG surface: no layout
/// engine, just a declarative description of a block's box, rendered by TextKit.
struct RichTextBlockStyle {
    /// Per-edge widths in points. `top`/`bottom` map to TextKit's `.maxY`/`.minY`
    /// because text layout space is bottom-left origin.
    struct Insets {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat

        init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }

        init(uniform: CGFloat) {
            self.init(top: uniform, leading: uniform, bottom: uniform, trailing: uniform)
        }

        static let zero = Insets()
    }

    /// Block width as a percentage of the text column (100 = full column width).
    var width: CGFloat = 100
    var minWidth: CGFloat? = nil
    var maxWidth: CGFloat? = nil
    var padding = Insets.zero
    var border = Insets.zero
    var margin = Insets.zero
    var borderColor: NSColor? = nil
    var backgroundColor: NSColor? = nil

    func makeBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(width, type: .percentageValueType, for: .width)
        if let minWidth { block.setValue(minWidth, type: .percentageValueType, for: .minimumWidth) }
        if let maxWidth { block.setValue(maxWidth, type: .percentageValueType, for: .maximumWidth) }
        apply(border, layer: .border, to: block)
        apply(padding, layer: .padding, to: block)
        apply(margin, layer: .margin, to: block)
        if let borderColor { block.setBorderColor(borderColor) }
        block.backgroundColor = backgroundColor
        return block
    }

    /// A paragraph style carrying this block, ready to attach to a range.
    func makeParagraphStyle(lineSpacing: CGFloat = 2, paragraphSpacing: CGFloat = 2) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = [makeBlock()]
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    private func apply(_ insets: Insets, layer: NSTextBlock.Layer, to block: NSTextBlock) {
        block.setWidth(insets.top, type: .absoluteValueType, for: layer, edge: .maxY)
        block.setWidth(insets.bottom, type: .absoluteValueType, for: layer, edge: .minY)
        block.setWidth(insets.leading, type: .absoluteValueType, for: layer, edge: .minX)
        block.setWidth(insets.trailing, type: .absoluteValueType, for: layer, edge: .maxX)
    }
}
