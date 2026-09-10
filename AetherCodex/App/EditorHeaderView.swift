import Cocoa

/// Transparent header view for NSSplitViewItemAccessoryViewController.
/// Carries the document title for the scroll-edge soft blur compositor.
final class EditorHeaderView: NSView {

    let titleLabel: NSTextField

    override init(frame: NSRect) {
        titleLabel = NSTextField(labelWithString: "Untitled")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frame)

        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
