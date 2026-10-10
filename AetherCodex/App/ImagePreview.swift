import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - File type detection

/// Raster image extensions the preview recognizes. Vectors (SVG/PDF) are
/// deliberately excluded — they belong to the code/document path, not the
/// raster viewer.
enum ImageFileType {
    static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp",
        "heic", "heif", "webp", "icns", "ico", "avif",
    ]

    static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func exportFormat(forExtension ext: String) -> ImageExportFormat? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        case "webp": return .webp
        case "bmp": return .bmp
        default: return nil
        }
    }
}

// MARK: - Export formats

/// Conversion targets offered by the preview toolbar. Each maps to a
/// CoreGraphics image-destination UTI so re-encoding stays native.
enum ImageExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg, tiff, heic, webp, bmp

    var id: String { rawValue }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var displayName: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }

    /// CoreGraphics image-destination UTI string.
    var utiIdentifier: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .tiff: return UTType.tiff.identifier
        case .heic: return UTType.heic.identifier
        case .webp: return "org.webmproject.webp"
        case .bmp: return UTType.bmp.identifier
        }
    }

    /// UTType for `NSSavePanel.allowedContentTypes` (WebP has no static member).
    var utType: UTType? { UTType(utiIdentifier) }
}

// MARK: - Encoding / cropping

enum ImageEncoder {
    static func encode(_ image: NSImage, as format: ImageExportFormat, quality: CGFloat = 0.92) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, format.utiIdentifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }

    /// Crops in *pixel* coordinates (top-left origin), matching CGImage.
    static func crop(_ image: NSImage, to rect: CGRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }
}

extension NSImage {
    var pixelSize: NSSize? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSSize(width: cg.width, height: cg.height)
    }
}

// MARK: - Model

/// State + logic for the image preview. Owned by `EditorViewController` so the
/// save path (⌘S) and the editor's dirty flag stay unified.
final class ImagePreviewModel: ObservableObject {
    @Published var url: URL?
    @Published var image: NSImage?
    @Published var pixelSize: NSSize?
    @Published var isDirty = false
    @Published var originalFormat: ImageExportFormat = .png
    @Published var lastError: String?
    @Published var notice: String?

    /// Bridges the model's dirty state into the editor's title/⌘S plumbing.
    var onDirtyChange: ((Bool) -> Void)?

    var isActive: Bool { url != nil }

    func load(url: URL) {
        guard let img = NSImage(contentsOf: url) else {
            self.url = url
            self.image = nil
            self.pixelSize = nil
            self.lastError = "Could not decode image — unsupported or corrupt format."
            self.isDirty = false
            return
        }
        self.url = url
        self.image = img
        self.pixelSize = img.pixelSize
        self.originalFormat = ImageFileType.exportFormat(forExtension: url.pathExtension) ?? .png
        self.isDirty = false
        self.lastError = nil
        self.notice = nil
    }

    func clear() {
        url = nil
        image = nil
        pixelSize = nil
        isDirty = false
        lastError = nil
        notice = nil
    }

    func save() {
        guard let image, let url else { return }
        do {
            guard let data = ImageEncoder.encode(image, as: originalFormat) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            setDirty(false)
            flash("Saved \(url.lastPathComponent)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func convert(to format: ImageExportFormat) {
        guard let image, let url else { return }
        let suggested = url.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [format.utType].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.title = "Convert to \(format.displayName)"

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            do {
                guard let data = ImageEncoder.encode(image, as: format) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: target, options: .atomic)
                self.flash("Converted → \(target.lastPathComponent)")
            } catch {
                self.lastError = error.localizedDescription
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    func applyCrop(rect: CGRect) {
        guard let image else { return }
        guard let cropped = ImageEncoder.crop(image, to: rect) else { return }
        self.image = cropped
        self.pixelSize = cropped.pixelSize
        setDirty(true)
    }

    private func setDirty(_ dirty: Bool) {
        isDirty = dirty
        onDirtyChange?(dirty)
    }

    private func flash(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }
}

// MARK: - Surface

/// Raster image preview: zoom/pan, crop, and format conversion. Presented in
/// place of the text/rich-text surface when an image file is opened.
struct ImagePreviewSurface: View {
    @ObservedObject var model: ImagePreviewModel
    let theme: SyntaxTheme
    /// Extra chrome height above the surface (the editor tab strip) that pushes
    /// the floating controls down when the tab bar is visible.
    var topInset: CGFloat = 0

    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var cropMode = false
    @State private var cropRect: CGRect?
    @State private var dragStart: CGPoint?
    @State private var moveInitialRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fit = fitScale(for: size)
            ZStack {
                theme.editorBackgroundColor.ignoresSafeArea()

                if let image = model.image, let px = model.pixelSize, px.width > 0, px.height > 0 {
                    if cropMode {
                        cropLayer(image: image, pixel: px, size: size, fit: fit)
                    } else {
                        zoomLayer(image: image, pixel: px, size: size, fit: fit)
                    }
                } else {
                    errorState
                }

                controls(size: size, fit: fit)
                if let notice = model.notice {
                    noticeBadge(notice)
                }
            }
        }
        .onChange(of: model.url) { _, _ in reset() }
    }

    // MARK: Layers

    private func zoomLayer(image: NSImage, pixel: NSSize, size: CGSize, fit: CGFloat) -> some View {
        let fitW = pixel.width * fit
        let fitH = pixel.height * fit
        return ZStack {
            Color.clear
            imageBody(image, width: fitW, height: fitH)
            // Progressive edge blur: a blurred copy of the image masked to the
            // viewport's outer band, so the photo dissolves into the glass at the
            // edges — the same scroll-edge blur the code/rich-text surfaces use.
            ZStack {
                imageBody(image, width: fitW, height: fitH).blur(radius: 16)
            }
            .frame(width: size.width, height: size.height)
            .mask(edgeBlurMask(size: size))
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(magnificationGesture(fit: fit))
        .simultaneousGesture(dragGesture())
        .onTapGesture(count: 2) { toggleActualSize(fit: fit) }
    }

    /// The image at its current zoom/pan — shared by the sharp and blurred copies
    /// so both stay locked to the same transform.
    private func imageBody(_ image: NSImage, width: CGFloat, height: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: height)
            .scaleEffect(zoom)
            .offset(pan)
    }

    /// Opaque at the viewport edges, transparent toward the center — drives the
    /// progressive blur so only the outer band shows the blurred image copy.
    private func edgeBlurMask(size: CGSize) -> some View {
        let band: CGFloat = 64
        return ZStack {
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: band)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: band)
                .frame(maxHeight: .infinity, alignment: .bottom)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .frame(maxWidth: .infinity, alignment: .leading)
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: size.width, height: size.height)
    }

    private func cropLayer(image: NSImage, pixel: NSSize, size: CGSize, fit: CGFloat) -> some View {
        let displayW = pixel.width * fit
        let displayH = pixel.height * fit
        let imageRect = CGRect(x: (size.width - displayW) / 2,
                               y: (size.height - displayH) / 2,
                               width: displayW, height: displayH)

        return ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: displayW, height: displayH)
                .position(x: size.width / 2, y: size.height / 2)

            if let rect = cropRect {
                CropMask(rect: rect)
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Rectangle()
                    .stroke(Color.black.opacity(0.6), lineWidth: 0.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(cropDragGesture(imageRect: imageRect))
        .overlay(alignment: .bottom) {
            if cropRect != nil {
                cropActionBar(imageRect: imageRect, fit: fit)
            }
        }
    }

    private var errorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.lastError ?? "No image to display")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Gestures

    private func magnificationGesture(fit: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in zoom = clampZoom(zoomBase * value, fit: fit) }
            .onEnded { _ in zoomBase = zoom }
    }

    private func dragGesture() -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.001 else { return }
                pan = CGSize(width: panBase.width + value.translation.width,
                             height: panBase.height + value.translation.height)
            }
            .onEnded { _ in panBase = pan }
    }

    private func cropDragGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                    if let existing = cropRect, existing.contains(value.startLocation) {
                        moveInitialRect = existing
                    } else {
                        moveInitialRect = nil
                    }
                }
                guard let start = dragStart else { return }
                if let initial = moveInitialRect {
                    let moved = initial.offsetBy(dx: value.translation.width, dy: value.translation.height)
                    cropRect = clamped(moved, to: imageRect)
                } else {
                    cropRect = clamped(normalizedRect(start, value.location), to: imageRect)
                }
            }
            .onEnded { _ in
                dragStart = nil
                moveInitialRect = nil
            }
    }

    // MARK: Controls

    private func controls(size: CGSize, fit: CGFloat) -> some View {
        VStack(alignment: .trailing) {
            HStack(spacing: 6) {
                barButton("minus.magnifyingglass", "Zoom out") { zoomOut(fit: fit) }
                Text("\(Int(fit * zoom * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44)
                barButton("plus.magnifyingglass", "Zoom in") { zoomIn(fit: fit) }
                Divider().frame(height: 16)
                barButton("arrow.down.right.and.arrow.up.left", "Fit") { fitToScreen(fit: fit) }
                barButton("1.square", "Actual size") { actualSize(fit: fit) }
                Divider().frame(height: 16)
                barButton("crop", "Crop") { toggleCrop() }
                    .foregroundStyle(cropMode ? Color(nsColor: .controlAccentColor) : Color.secondary)
                convertMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

            Spacer()
        }
        .padding(.top, 48 + topInset)
        .padding(.trailing, 20)
    }

    private var convertMenu: some View {
        Menu {
            ForEach(ImageExportFormat.allCases) { format in
                Button(format.displayName) { model.convert(to: format) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Convert / export")
    }

    private func cropActionBar(imageRect: CGRect, fit: CGFloat) -> some View {
        HStack(spacing: 10) {
            Button("Cancel") { cancelCrop() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Apply Crop") { applyCrop(imageRect: imageRect, fit: fit) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.bottom, 16)
    }

    private func noticeBadge(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 48 + topInset)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: model.notice)
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Helpers

    private func fitScale(for size: CGSize) -> CGFloat {
        guard let px = model.pixelSize, px.width > 0, px.height > 0 else { return 1 }
        return min(size.width / px.width, size.height / px.height)
    }

    private func clampZoom(_ value: CGFloat, fit: CGFloat) -> CGFloat {
        let oneToOne = fit > 0 ? 1.0 / fit : 1.0
        return min(max(value, 1.0), max(oneToOne, 16))
    }

    private func zoomIn(fit: CGFloat) {
        zoom = clampZoom(zoom * 1.25, fit: fit)
        zoomBase = zoom
    }

    private func zoomOut(fit: CGFloat) {
        zoom = clampZoom(zoom / 1.25, fit: fit)
        zoomBase = zoom
    }

    private func fitToScreen(fit: CGFloat) {
        zoom = 1; zoomBase = 1
        pan = .zero; panBase = .zero
    }

    private func actualSize(fit: CGFloat) {
        let oneToOne = fit > 0 ? 1.0 / fit : 1.0
        zoom = oneToOne; zoomBase = oneToOne
        pan = .zero; panBase = .zero
    }

    private func toggleActualSize(fit: CGFloat) {
        if zoom > 1.001 || pan != .zero {
            fitToScreen(fit: fit)
        } else {
            actualSize(fit: fit)
        }
    }

    private func toggleCrop() {
        cropMode.toggle()
        if !cropMode { cropRect = nil }
    }

    private func cancelCrop() {
        cropMode = false
        cropRect = nil
    }

    private func applyCrop(imageRect: CGRect, fit: CGFloat) {
        guard let rect = cropRect, fit > 0 else { return }
        let pixelRect = CGRect(x: (rect.minX - imageRect.minX) / fit,
                               y: (rect.minY - imageRect.minY) / fit,
                               width: rect.width / fit,
                               height: rect.height / fit)
        model.applyCrop(rect: pixelRect)
        reset()
    }

    private func reset() {
        zoom = 1; zoomBase = 1
        pan = .zero; panBase = .zero
        cropMode = false
        cropRect = nil
        dragStart = nil
        moveInitialRect = nil
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
        let y = max(bounds.minY, min(rect.minY, bounds.maxY - rect.height))
        return CGRect(x: x, y: y,
                      width: min(rect.width, bounds.width),
                      height: min(rect.height, bounds.height))
    }
}

/// Even-odd mask that dims everything except the crop selection.
private struct CropMask: Shape {
    let rect: CGRect

    func path(in outer: CGRect) -> Path {
        var path = Path()
        path.addRect(outer)
        path.addRect(rect)
        return path
    }
}