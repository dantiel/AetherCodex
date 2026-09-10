import Cocoa

/// Liquid Glass pane — wraps content with translucent glass material.
/// Uses NSGlassEffectView on macOS 26+ with proper transparency via NSVisualEffectView backdrop.
/// Supports two layout modes:
///   • autoresizing (for NSSplitView — frames managed by split view)
///   • auto-layout (for standalone use with constraints)
@available(macOS 26.0, *)
final class GlassPane: NSView {

    private let glassView: NSGlassEffectView

    // MARK: - Init

    /// Create a glass pane wrapping content.
    /// - Parameter usesAutoLayout: false = autoresizing mask (for NSSplitView subviews, avoids snap-back).
    ///   true = auto-layout constraints (for standalone views pinned via anchors).
    init(wrapping content: NSView, cornerRadius: CGFloat = 18, usesAutoLayout: Bool = false) {
        // Pure NSGlassEffectView with .clear style — tintColor drives the glass color
        glassView = NSGlassEffectView()
        glassView.cornerRadius = cornerRadius
        glassView.style = .clear
        glassView.alphaValue = 1.0

        super.init(frame: .zero)

        // Configure autoresizing
        glassView.translatesAutoresizingMaskIntoConstraints = !usesAutoLayout
        
        if usesAutoLayout {
            glassView.translatesAutoresizingMaskIntoConstraints = false
            translatesAutoresizingMaskIntoConstraints = false
            
            addSubview(glassView)
            
            // Pin content to glassView bounds via constraints
            content.translatesAutoresizingMaskIntoConstraints = false
            glassView.contentView = content
            
            NSLayoutConstraint.activate([
                // Glass fills parent
                glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
                glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
                glassView.topAnchor.constraint(equalTo: topAnchor),
                glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
                // Content fills glass
                content.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
                content.topAnchor.constraint(equalTo: glassView.topAnchor),
                content.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
            ])
        } else {
            // Autoresizing mode — fill parent. Split view manages our frame.
            glassView.autoresizingMask = [.width, .height]
            translatesAutoresizingMaskIntoConstraints = true
            autoresizingMask = [.width, .height]
            
            glassView.frame = bounds
            content.frame = glassView.bounds
            content.autoresizingMask = [.width, .height]
            glassView.contentView = content
            
            addSubview(glassView)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard translatesAutoresizingMaskIntoConstraints else { return }
        glassView.frame = bounds
    }

    // MARK: - Glass tuning

    /// Tint the glass toward a theme-derived color.
    /// The alpha component controls glass transparency intensity.
    var tintColor: NSColor? {
        get { glassView.tintColor }
        set { glassView.tintColor = newValue }
    }

    /// No-op on macOS 26+ — tintColor handles glass appearance.
    func updateMaterial(_ material: NSVisualEffectView.Material) {}
    
    /// Access the underlying glass effect view.
    var glassEffectView: NSGlassEffectView { glassView }
}

// MARK: - NSViewController wrapper for GlassPane

@available(macOS 26.0, *)
extension GlassPane {
    /// Returns an NSViewController containing this glass pane.
    var viewController: NSViewController {
        let vc = NSViewController()
        vc.view = self
        return vc
    }
}

/// Pre-macOS 26 fallback using NSVisualEffectView for glass-like effect.
/// Mimics Liquid Glass appearance with tint integration into blur.
@available(macOS, deprecated: 26.0, message: "Use GlassPane on macOS 26+")
final class VisualEffectPane: NSView {
    
    private let glassView: NSVisualEffectView   // single heavy blur — maximum density
    private let tintView: NSView                // theme tint overlay
    private let contentView: NSView
    
    init(wrapping content: NSView, material: NSVisualEffectView.Material = .windowBackground, cornerRadius: CGFloat = 18) {
        // Single glass layer — .windowBackground maximizes core blur density
        // while preserving native adaptive edge vignettes and responsive border highlights
        glassView = NSVisualEffectView()
        glassView.material = .windowBackground
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        // isEmphasized default (false) = softer, more diffuse blur
        
        // Tint layer — sits atop glass for theme color without killing blur
        tintView = NSView()
        tintView.wantsLayer = true
        
        // Store reference to content
        contentView = content
        
        super.init(frame: .zero)
        
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
        
        glassView.frame = bounds
        glassView.autoresizingMask = [.width, .height]
        
        tintView.frame = glassView.bounds
        tintView.autoresizingMask = [.width, .height]
        
        content.frame = glassView.bounds
        content.autoresizingMask = [.width, .height]
        
        // Stack: glassView → [tintView + content]
        // Content and tint sit directly atop the heavy blur — no vibrancy wash
        glassView.addSubview(tintView)
        glassView.addSubview(content)
        
        addSubview(glassView)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    
    /// Apply tint with alpha integrated atop the blur.
    var tintColor: NSColor? {
        get { nil }
        set {
            if let color = newValue {
                tintView.layer?.backgroundColor = color.cgColor
            } else {
                tintView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.10).cgColor
            }
        }
    }
    
    func updateMaterial(_ material: NSVisualEffectView.Material) {
        glassView.material = material
    }
    
    var viewController: NSViewController {
        let vc = NSViewController()
        vc.view = self
        return vc
    }
}