import SwiftUI
import AppKit

// MARK: - TextKit 2 measurement

/// Measures a document's full layout extent using TextKit 2, independently of
/// any view. Used to size the SwiftUI `ScrollView` content so SwiftUI owns the
/// scrolling and the native scroll-edge effect can engage.
enum TextKit2Layout {
    static func measure(_ attributedString: NSAttributedString, containerWidth: CGFloat) -> CGSize {
        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        storage.addTextLayoutManager(layout)

        let container = NSTextContainer(size: CGSize(width: containerWidth, height: 0))
        container.widthTracksTextView = false
        layout.textContainer = container

        storage.performEditingTransaction {
            storage.textStorage?.setAttributedString(attributedString)
        }

        let range = storage.documentRange
        layout.ensureLayout(for: range)

        var union = CGRect.zero
        layout.enumerateTextLayoutFragments(from: range.location,
                                            options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            union = union.union(fragment.layoutFragmentFrame)
            return true
        }
        return union.size
    }
}

// MARK: - TextKit 2 editor surface (NOT an NSScrollView)

/// Draws an attributed document via `NSTextLayoutManager` + `NSTextContentStorage`.
/// This view does zero scrolling of its own — it is passive content sized to the
/// full document extent and scrolled by a SwiftUI `ScrollView`. That ownership
/// split is the entire point: SwiftUI owns the scroll, so `.scrollEdgeEffectStyle`
/// applies natively.
final class TextKit2EditorView: NSView {
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private var fragments: [NSTextLayoutFragment] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        contentStorage.addTextLayoutManager(layoutManager)

        // Width 0 = no wrapping limit; lines extend to their natural width so
        // horizontal scrolling (and the trailing edge) has real content.
        let container = NSTextContainer(size: CGSize(width: 0, height: 0))
        container.widthTracksTextView = false
        layoutManager.textContainer = container
    }

    override var isFlipped: Bool { true }

    func setAttributedString(_ attributedString: NSAttributedString) {
        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(attributedString)
        }
        layoutManager.invalidateLayout(for: contentStorage.documentRange)

        let range = contentStorage.documentRange
        layoutManager.ensureLayout(for: range)

        fragments.removeAll()
        layoutManager.enumerateTextLayoutFragments(from: range.location,
                                                   options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            self.fragments.append(fragment)
            return true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame
            if frame.intersects(dirtyRect) {
                fragment.draw(at: frame.origin, in: context)
            }
        }
    }
}

// MARK: - NSViewRepresentable bridge

struct TextKit2EditorRepresentable: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> TextKit2EditorView {
        let view = TextKit2EditorView(frame: .zero)
        view.setAttributedString(attributedString)
        return view
    }

    func updateNSView(_ nsView: TextKit2EditorView, context: Context) {
        nsView.setAttributedString(attributedString)
    }
}
