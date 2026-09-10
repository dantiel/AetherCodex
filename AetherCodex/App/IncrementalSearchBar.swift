import Cocoa

/// Liquid-glass incremental search bar — centered near editor bottom.
/// Ctrl+S to toggle / navigate forward, Shift+Ctrl+S backward, Esc to dismiss.
/// Mirrors Spotlight's glass depth: translucent tint + subtle shadow + fade animation.
/// Theme-driven: follows current theme's glassTintColor and editorForeground.
final class IncrementalSearchBar: NSView {

    // MARK: - State

    var onSearchChange: ((String, Bool, Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onNavigate: ((Bool) -> Void)?   // true=forward, false=backward
    var onConfirm: (() -> Void)?        // Enter → navigate+select then dismiss

    private(set) var searchField: NSTextField!
    var currentEditor: NSText? { currentEditorRef }

    private var ignoreCase: Bool = true
    private var wrapAround: Bool = true
    private var currentEditorRef: NSText?
    private var suppressCallback: Bool = false

    // MARK: - Subviews

    private let glassHost: NSView  // NSGlassEffectView on 26+, NSVisualEffectView fallback
    private let matchLabel: NSTextField

    private let barPadH: CGFloat = 16

    // MARK: - Init

    override init(frame: NSRect) {
        let tf = NSTextField(frame: .zero)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.font = NSFont.systemFont(ofSize: 14)
        tf.placeholderString = "\u{2315}  Search\u{2026}"   // ⌕ Search…
        tf.focusRingType = .none
        tf.translatesAutoresizingMaskIntoConstraints = false
        self.searchField = tf

        matchLabel = NSTextField(labelWithString: "")
        matchLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── Liquid Glass host — translucent depth like Spotlight ──
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .clear
            g.cornerRadius = 10
            g.translatesAutoresizingMaskIntoConstraints = false
            g.wantsLayer = true
            g.layer?.shadowColor = NSColor.black.cgColor
            g.layer?.shadowOpacity = 0.12
            g.layer?.shadowOffset = CGSize(width: 0, height: -2)
            g.layer?.shadowRadius = 12
            // Theme-driven tint — applied after super.init below

            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(searchField)
            content.addSubview(matchLabel)
            NSLayoutConstraint.activate([
                searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: barPadH),
                searchField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                matchLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -barPadH),
                matchLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                searchField.trailingAnchor.constraint(equalTo: matchLabel.leadingAnchor, constant: -8),
            ])
            g.contentView = content
            glassHost = g
        } else {
            let g = NSVisualEffectView()
            g.material = .toolTip
            g.blendingMode = .behindWindow
            g.state = .active
            g.wantsLayer = true
            g.layer?.cornerRadius = 10
            g.layer?.masksToBounds = true
            g.layer?.shadowColor = NSColor.black.cgColor
            g.layer?.shadowOpacity = 0.12
            g.layer?.shadowOffset = CGSize(width: 0, height: -2)
            g.layer?.shadowRadius = 12
            g.translatesAutoresizingMaskIntoConstraints = false
            g.addSubview(searchField)
            g.addSubview(matchLabel)
            NSLayoutConstraint.activate([
                searchField.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: barPadH),
                searchField.centerYAnchor.constraint(equalTo: g.centerYAnchor),
                matchLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -barPadH),
                matchLabel.centerYAnchor.constraint(equalTo: g.centerYAnchor),
                searchField.trailingAnchor.constraint(equalTo: matchLabel.leadingAnchor, constant: -8),
            ])
            glassHost = g
        }

        super.init(frame: frame)

        // Apply theme tint to glass (must be after super.init for self access)
        if #available(macOS 26.0, *), let g = glassHost as? NSGlassEffectView {
            let theme = ThemeRegistry.shared.current
            let tint = theme.glassTintColor
            g.tintColor = tint.withAlphaComponent(max(tint.alphaComponent * 0.06, 0.03))
        }

        searchField.target = self
        searchField.action = #selector(searchFieldAction)

        addSubview(glassHost)
        NSLayoutConstraint.activate([
            glassHost.topAnchor.constraint(equalTo: topAnchor),
            glassHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Observe text changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(searchFieldTextDidChange),
            name: NSControl.textDidChangeNotification,
            object: searchField
        )
    }

    // MARK: - Actions

    @objc private func searchFieldAction() {
        // Enter — confirm selection and dismiss
        onConfirm?()
    }

    @objc private func searchFieldTextDidChange() {
        guard !suppressCallback else { return }
        onSearchChange?(searchField.stringValue, ignoreCase, wrapAround)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func show(in superview: NSView, centerX: CGFloat, bottomY: CGFloat) {
        let barWidth: CGFloat = 500
        let barHeight: CGFloat = 36

        let hadExistingText = !searchField.stringValue.isEmpty

        frame = NSRect(x: centerX - barWidth / 2,
                        y: bottomY,
                        width: barWidth,
                        height: barHeight)
        alphaValue = 0
        superview.addSubview(self)
        matchLabel.stringValue = ""
        updateTheme()  // follow current theme colors

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.searchField)
            if hadExistingText {
                // Select all without triggering search — suppressCallback guards
                // against NSControl.textDidChangeNotification fired by selectText(nil).
                self.suppressCallback = true
                self.searchField.selectText(nil)
                DispatchQueue.main.async {
                    self.suppressCallback = false
                }
            }
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            // Preserve search text — reopens with old query selected
            self.matchLabel.stringValue = ""
            self.removeFromSuperview()
            self.onDismiss?()
        }
    }

    /// Re-apply theme tint to the glass host — call on theme change or when showing.
    func updateTheme() {
        if #available(macOS 26.0, *) {
            if let glass = glassHost as? NSGlassEffectView {
                applyThemeGlass(to: glass)
            }
        } else {
            if let vev = glassHost as? NSVisualEffectView {
                let theme = ThemeRegistry.shared.current
                let isDark = theme.kind == .dark
                vev.material = isDark ? .toolTip : .underWindowBackground
                if let bg = theme.sidebarBackground {
                    vev.layer?.backgroundColor = bg.withAlphaComponent(0.10).cgColor
                }
            }
        }
        // Also update text color
        let theme = ThemeRegistry.shared.current
        let fg = theme.editorForeground
        searchField.textColor = fg
        matchLabel.textColor = fg.withAlphaComponent(0.5)
    }

    @available(macOS 26.0, *)
    private func applyThemeGlass(to glass: NSGlassEffectView) {
        let theme = ThemeRegistry.shared.current
        let tint = theme.glassTintColor
        // Near-transparent: use theme tint at just 6% of its alpha
        // — heavy blur + minimal tint for pure Liquid Glass depth
        glass.tintColor = tint.withAlphaComponent(max(tint.alphaComponent * 0.06, 0.03))
    }

    func selectAll() {
        searchField.selectText(nil)
    }

    func focusField() {
        window?.makeFirstResponder(searchField)
    }

    /// Re-fire current search from origin — used when Ctrl+S is pressed while bar is visible.
    func fireSearchFromCurrent() {
        onSearchChange?(searchField.stringValue, ignoreCase, wrapAround)
    }

    func updateMatch(current: Int, total: Int) {
        matchLabel.stringValue = total > 0 ? "\(current)/\(total)" : "0/0"
    }

    var isVisible: Bool { superview != nil }

    var searchText: String { searchField.stringValue }
}