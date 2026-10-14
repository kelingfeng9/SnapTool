import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Retains one desktop snapshot per capture session and small derived drawing
/// caches. UI previews and exports share the same drawing code.
public final class AnnotationRenderer {
    public let desktop: CGImage
    public let pixelScale: CGFloat
    private struct Entry {
        let annotation: Annotation
        let bounds: CGRect
        let path: CGPath?
        let mosaic: CGImage?
        let mosaicRect: CGRect?
    }
    private var cache: [UUID: Entry] = [:]
    public var cachedAnnotationCount: Int { cache.count }

    public init(desktop: CGImage, pixelScale: CGFloat) {
        self.desktop = desktop
        self.pixelScale = pixelScale
    }

    public func clearCache() { cache.removeAll() }

    public func pruneCache(activeIDs: Set<UUID>) {
        cache = cache.filter { activeIDs.contains($0.key) }
    }

    public func render(selection: CGRect, shape: CaptureShape, vertices: [CGPoint] = [],
                       annotations: [Annotation] = []) throws -> CGImage {
        guard pixelScale.isFinite, pixelScale > 0 else { throw SnapCoreError.invalidScale }
        let rect = selection.standardized
        let extent = CGRect(x: 0, y: 0, width: CGFloat(desktop.width) / pixelScale,
                            height: CGFloat(desktop.height) / pixelScale)
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= extent.maxX + 0.001, rect.maxY <= extent.maxY + 0.001 else {
            throw SnapCoreError.invalidSelection
        }
        if shape == .polygon && vertices.count < 3 { throw SnapCoreError.invalidPolygon }
        let pixelRect = CGRect(x: rect.minX * pixelScale, y: rect.minY * pixelScale,
                               width: rect.width * pixelScale, height: rect.height * pixelScale).integral
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(desktop.width), height: CGFloat(desktop.height)))
        guard let cropped = desktop.cropping(to: pixelRect),
              let context = Self.bitmapContext(width: cropped.width, height: cropped.height) else {
            throw SnapCoreError.imageAllocationFailed
        }
        let outputSize = CGSize(width: CGFloat(cropped.width) / pixelScale,
                                height: CGFloat(cropped.height) / pixelScale)
        let outputOrigin = CGPoint(x: pixelRect.minX / pixelScale, y: pixelRect.minY / pixelScale)
        let localRect = CGRect(x: rect.minX - outputOrigin.x, y: rect.minY - outputOrigin.y,
                               width: rect.width, height: rect.height)
        context.scaleBy(x: pixelScale, y: pixelScale)
        context.translateBy(x: 0, y: outputSize.height)
        context.scaleBy(x: 1, y: -1)
        let localVertices = vertices.map { CGPoint(x: $0.x - outputOrigin.x, y: $0.y - outputOrigin.y) }
        context.addPath(ShapeGeometry.path(shape: shape, in: localRect,
                                          vertices: localVertices))
        context.clip()
        Self.drawImage(cropped, in: CGRect(origin: .zero, size: outputSize), context: context)
        context.translateBy(x: -outputOrigin.x, y: -outputOrigin.y)
        drawAnnotations(in: context, annotations: annotations)
        guard let output = context.makeImage() else { throw SnapCoreError.imageAllocationFailed }
        return output
    }

    /// The caller supplies a CGContext whose coordinates are desktop top-left
    /// logical points. Set a clip before calling to avoid work outside dirty areas.
    /// Include objects being drawn or dragged in transientIDs so their mutable
    /// point arrays are not retained by a completed-object cache snapshot.
    public func drawAnnotations(in context: CGContext, annotations: [Annotation], transientIDs: Set<UUID> = []) {
        let clip = context.boundingBoxOfClipPath
        for annotation in annotations where annotation.tool != .select {
            let transient = transientIDs.contains(annotation.id)
            if transient { cache.removeValue(forKey: annotation.id) }
            let bounds: CGRect
            if let cached = cache[annotation.id], cached.annotation == annotation { bounds = cached.bounds }
            else { bounds = AnnotationGeometry.bounds(of: annotation) }
            // In particular, avoid even creating a mosaic crop when it lies
            // outside the current preview's dirty rectangle.
            guard bounds.intersects(clip) else { continue }
            let entry = cachedEntry(annotation, retain: !transient)
            context.saveGState()
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(AnnotationGeometry.safeWidth(annotation.width))
            context.setLineCap(.round); context.setLineJoin(.round)
            switch annotation.tool {
            case .rectangle:
                if annotation.filled { context.fill(annotation.rect) }
                else { context.stroke(annotation.rect) }
            case .ellipse:
                if annotation.filled { context.fillEllipse(in: annotation.rect) }
                else { context.strokeEllipse(in: annotation.rect) }
            case .arrow, .line, .pen, .highlight:
                if annotation.tool == .highlight {
                    context.setAlpha(0.28)
                    context.setLineWidth(AnnotationGeometry.safeWidth(annotation.width) * 4)
                }
                if let path = entry.path {
                    context.addPath(path); context.strokePath()
                }
                if (annotation.tool == .pen || annotation.tool == .highlight) && annotation.points.count == 1 {
                    let radius = AnnotationGeometry.safeWidth(annotation.width) * (annotation.tool == .highlight ? 2 : 0.5)
                    let p = annotation.points[0]
                    context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                                   width: radius * 2, height: radius * 2))
                }
            case .text:
                Self.drawText(annotation.text, at: annotation.start, size: annotation.fontSize,
                              color: annotation.color, context: context)
            case .number:
                let radius = AnnotationGeometry.numberRadius(annotation)
                context.fillEllipse(in: CGRect(x: annotation.start.x - radius, y: annotation.start.y - radius,
                                               width: radius * 2, height: radius * 2))
                let text = String(annotation.number)
                let size = AnnotationGeometry.safeFontSize(annotation.fontSize)
                let metrics = AnnotationGeometry.textSize(text, fontSize: size)
                Self.drawText(text, at: CGPoint(x: annotation.start.x - metrics.width / 2,
                                                y: annotation.start.y - metrics.height / 2),
                              size: size, color: .white, context: context)
            case .mosaic:
                if let image = entry.mosaic, let rect = entry.mosaicRect {
                    context.interpolationQuality = .none
                    Self.drawImage(image, in: rect, context: context)
                }
            case .select: break
            }
            context.restoreGState()
        }
    }

    public static func PNGData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapCoreError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapCoreError.pngEncodingFailed }
        return data as Data
    }

    public static func opaqueImage(_ image: CGImage, background: RGBAColor = .white) throws -> CGImage {
        guard let context = bitmapContext(width: image.width, height: image.height) else {
            throw SnapCoreError.imageAllocationFailed
        }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        var opaque = background; opaque.alpha = 1
        context.setFillColor(opaque.cgColor); context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw SnapCoreError.imageAllocationFailed }
        return result
    }

    private func cachedEntry(_ annotation: Annotation, retain: Bool = true) -> Entry {
        if retain, let entry = cache[annotation.id], entry.annotation == annotation { return entry }
        let path: CGPath?
        switch annotation.tool {
        case .arrow: path = AnnotationGeometry.arrowPath(annotation)
        case .line:
            let line = CGMutablePath(); line.move(to: annotation.start); line.addLine(to: annotation.end); path = line
        case .pen, .highlight:
            let line = CGMutablePath()
            let points = annotation.points.isEmpty ? [annotation.start, annotation.end] : annotation.points
            if let first = points.first { line.move(to: first); points.dropFirst().forEach { line.addLine(to: $0) } }
            path = line
        default: path = nil
        }
        var mosaic: CGImage?, mosaicRect: CGRect?
        if annotation.tool == .mosaic, pixelScale.isFinite, pixelScale > 0 {
            let logicalExtent = CGRect(x: 0, y: 0, width: CGFloat(desktop.width) / pixelScale,
                                       height: CGFloat(desktop.height) / pixelScale)
            let rect = annotation.rect.intersection(logicalExtent)
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                let pixels = CGRect(x: rect.minX * pixelScale, y: rect.minY * pixelScale,
                                    width: rect.width * pixelScale, height: rect.height * pixelScale).integral
                if let source = desktop.cropping(to: pixels) {
                    let block = CGFloat(max(2, min(256, annotation.blockSize))) * pixelScale
                    let columns = max(1, Int(ceil(CGFloat(source.width) / block)))
                    let rows = max(1, Int(ceil(CGFloat(source.height) / block)))
                    if let context = Self.bitmapContext(width: columns, height: rows) {
                        context.interpolationQuality = .low
                        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(columns), height: CGFloat(rows)))
                        mosaic = context.makeImage(); mosaicRect = rect
                    }
                }
            }
        }
        let entry = Entry(annotation: annotation, bounds: AnnotationGeometry.bounds(of: annotation),
                          path: path, mosaic: mosaic, mosaicRect: mosaicRect)
        if retain { cache[annotation.id] = entry }
        return entry
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        // CGImage raster rows already use top-left ordering. Counter-flip only
        // the image draw, leaving shapes and text in top-left logical coordinates.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat,
                                 color: RGBAColor, context: CGContext) {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, AnnotationGeometry.safeFontSize(size), nil)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + max(2, CTFontGetLeading(font))
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let string = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
            ])
            context.saveGState()
            context.translateBy(x: point.x, y: point.y + CGFloat(index) * lineHeight + CTFontGetAscent(font))
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity; context.textPosition = .zero
            CTLineDraw(CTLineCreateWithAttributedString(string as CFAttributedString), context)
            context.restoreGState()
        }
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue)
    }
}
