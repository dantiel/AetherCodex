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
    /// Sidebar band width. The surface spans the window so its ruler column can
    /// carry the band itself, exactly like the code gutter.
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    /// Extra chrome height above the surface (the editor tab strip) that pushes
    /// the floating controls down when the tab bar is visible.
    var topInset: CGFloat = 0

    /// Leading ruler column — shared with the window chrome so the title and the
    /// tab strip clear it like a number gutter.
    static let rulerColumnWidth: CGFloat = 46

    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var cropMode = false
    /// Ruler unit. Pixels are exact; millimetres are physical, at the image's
    /// declared resolution when it has one, else the 96 dpi screen convention.
    @State private var rulerUnit: ImageRulerUnit = .pixels
    @State private var cropRect: CGRect?
    @State private var dragStart: CGPoint?
    @State private var moveInitialRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let column = Self.rulerColumnWidth
            let size = CGSize(width: max(proxy.size.width - leading - column - trailing, 1),
                              height: proxy.size.height)
            let fit = fitScale(for: size)
            ZStack(alignment: .topLeading) {
                // The field begins where the canvas begins. Under the ruler
                // column it was a second surface beneath the band's glass — the
                // sidebar region then read as its own pane.
                theme.editorBackgroundColor
                    .frame(width: max(proxy.size.width - leading - column, 1),
                           height: proxy.size.height)
                    .offset(x: leading + column)

                Group {
                    if let image = model.image, let px = model.pixelSize, px.width > 0, px.height > 0 {
                        if cropMode {
                            cropLayer(image: image, pixel: px, size: size, fit: fit)
                        } else {
                            zoomLayer(image: image, pixel: px, size: size, fit: fit)
                        }
                    } else {
                        errorState
                            .frame(width: size.width, height: size.height)
                    }
                }
                .frame(width: size.width, height: size.height)
                .offset(x: leading + column)

                // The leading column: sidebar band + measure column as one glass,
                // the code surface's own recipe, with the image's rulers riding it.
                LeadingChromeColumn(
                    leading: leading,
                    width: column,
                    height: proxy.size.height,
                    color: theme.rulerBackground,
                    opacity: Double(ThemeSettings.shared.resolvedRulerBackgroundOpacity(for: theme)),
                    separator: theme.rulerSeparator
                ) {
                    ImageRulerColumn(model: model, theme: theme, width: column,
                                     height: proxy.size.height,
                                     unit: rulerUnit,
                                     zoom: zoom, pan: pan, fit: fit,
                                     contentSize: size)
                }

                controls(size: size, fit: fit)
                    .padding(.leading, leading + column)

                if let notice = model.notice {
                    noticeBadge(notice)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
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

    /// The code view's top ramp, applied to a blurred copy of the image: the
    /// picture is fully frosted under the title/tab band, sharpens through the
    /// band's own height, and is untouched below. Nothing blurs at the sides or
    /// the bottom — this is the *scroll-edge* effect, not a vignette.
    private func edgeBlurMask(size: CGSize) -> some View {
        let ramp = EditorChromeMetrics.scrollEdgeBarHeight(topInset: topInset) + 36
        return VStack(spacing: 0) {
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.34),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: ramp)
            Color.clear
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
                Menu {
                    ForEach(ImageRulerUnit.allCases) { unit in
                        Button(unit.label) { rulerUnit = unit }
                    }
                } label: {
                    Image(systemName: "ruler")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Ruler unit")
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
// MARK: - Rulers

/// What the image's side ruler counts.
enum ImageRulerUnit: String, CaseIterable, Identifiable {
    /// Device-independent points of the picture itself, i.e. image pixels.
    case pixels
    /// Physical millimetres at the image's resolution (96 dpi fallback).
    case millimeters

    var id: String { rawValue }
    var label: String { self == .pixels ? "Pixels" : "Millimetres" }

    /// A length in image pixels, rendered in this unit.
    func value(forPixels pixels: CGFloat) -> CGFloat {
        switch self {
        case .pixels: return pixels
        case .millimeters: return pixels * 25.4 / 96
        }
    }

    func label(forPixels pixels: CGFloat) -> String {
        let v = value(forPixels: pixels)
        return v >= 100 ? String(format: "%.0f", v) : String(format: "%.0f", v)
    }
}

/// The image's measure column: a tick ruler that follows the picture's own
/// transform, so a tick always names the pixel it points at — even while the
/// image is zoomed and panned. Rides the shared leading column, so it is the code
/// gutter's glass and fade, with a ruler where the numbers would be.
private struct ImageRulerColumn: View {
    @ObservedObject var model: ImagePreviewModel
    let theme: SyntaxTheme
    let width: CGFloat
    let height: CGFloat
    let unit: ImageRulerUnit
    let zoom: CGFloat
    let pan: CGSize
    let fit: CGFloat
    let contentSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard let pixel = model.pixelSize, pixel.width > 0, pixel.height > 0,
                  fit > 0, zoom > 0 else { return }
            let scale = fit * zoom                       // points per image pixel
            let imageHeight = pixel.height * scale
            let originY = contentSize.height / 2 - imageHeight / 2 + pan.height

            let minor = step(minimum: 7 / scale)          // unlabelled
            let major = step(minimum: 44 / scale)         // labelled

            let minorColor = Color(nsColor: theme.rulerForeground).opacity(0.20)
            let majorColor = Color(nsColor: theme.rulerForeground).opacity(0.48)
            let labelColor = Color(nsColor: theme.rulerForeground).opacity(0.62)

            // Only the visible band of the picture is walked: a 6000 px scan at
            // high zoom must not cost 6000 strokes.
            let first = max(0, Int(floor((0 - originY) / (minor * scale))))
            let last = min(Int(ceil(pixel.height / minor)),
                           Int(ceil((size.height - originY) / (minor * scale))))

            guard first <= last else { return }

            for index in first...last {
                let pixels = CGFloat(index) * minor
                guard pixels <= pixel.height else { break }
                let y = originY + pixels * scale
                guard y >= -1, y <= size.height + 1 else { continue }

                let isMajor = pixels.truncatingRemainder(dividingBy: major) < 0.001
                let length: CGFloat = isMajor ? 12 : 5
                var path = Path()
                path.move(to: CGPoint(x: size.width - 2 - length, y: y))
                path.addLine(to: CGPoint(x: size.width - 2, y: y))
                context.stroke(path, with: .color(isMajor ? majorColor : minorColor),
                               lineWidth: isMajor ? 1.1 : 1)

                if isMajor {
                    context.draw(
                        Text(unit.label(forPixels: pixels))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(labelColor),
                        at: CGPoint(x: size.width - 16, y: y),
                        anchor: .trailing
                    )
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// Smallest "nice" step (1-2-5 series) at or above `minimum` image pixels.
    private func step(minimum: CGFloat) -> CGFloat {
        let series: [CGFloat] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250,
                                 500, 1000, 2000, 2500, 5000, 10000]
        return series.first { $0 >= minimum } ?? series[series.count - 1]
    }
}