import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

public enum ImageFormats {
    private static let extensions: Set<String> = {
        let builtIn = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
            .flatMap { UTType($0)?.tags[.filenameExtension] ?? [] }
        return Set(builtIn.map { $0.lowercased() }).union([
            "avif", "bmp", "cur", "gif", "heic", "heif", "ico", "jpeg", "jpg", "jp2", "j2k",
            "pbm", "pdf", "pgm", "png", "pnm", "ppm", "pxd", "pxm", "svg", "svgz",
            "tga", "tif", "tiff", "wbmp", "webp", "xbm", "xpm"
        ])
    }()

    public static func accepts(name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }

    public static func accepts(_ url: URL) -> Bool { accepts(name: url.lastPathComponent) }
    public static func isPixelmator(_ url: URL) -> Bool { ["pxd", "pxm"].contains(url.pathExtension.lowercased()) }
}

public struct DecodedImage: Sendable {
    public let image: CGImage
    public let frameCount: Int
    public let frameDelay: TimeInterval
    /// nil means the format has no loop metadata. Zero means infinite playback.
    public let loopCount: Int?
    public var byteCount: Int { image.bytesPerRow * image.height }
}

public final class AnimationPlayback: Sendable {
    fileprivate let url: URL
    fileprivate let id = UUID()
    private let source = OSAllocatedUnfairLock<CGImageSource?>(uncheckedState: nil)

    public init(url: URL) { self.url = url }

    fileprivate func decode(frame: Int) -> DecodedImage? {
        source.withLockUnchecked { source in
            if source == nil { source = ImageDecoder.fileSource(url) }
            return source.flatMap { ImageDecoder.decode($0, extension: url.pathExtension.lowercased(), frame: frame) }
        }
    }
}

public enum ImageDecoder {
    public static func decode(_ url: URL, frame: Int = 0) -> DecodedImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return pdf(url) }
        if ext == "svg" || ext == "svgz" { return vector(url, compressed: ext == "svgz") }
        if ["wbmp", "xbm", "xpm"].contains(ext) { return LegacyBitmaps.decode(url).map(still) }
        if ImageFormats.isPixelmator(url) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let preview = PixelmatorPreview.read(url),
                  let source = CGImageSourceCreateWithData(preview as CFData, options) else { return nil }
            return decode(source, extension: ext, frame: frame)
        }
        return fileSource(url).flatMap { decode($0, extension: ext, frame: frame) }
    }

    fileprivate static func fileSource(_ url: URL) -> CGImageSource? {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let hint = UTType(filenameExtension: url.pathExtension.lowercased())?.identifier {
            options[kCGImageSourceTypeIdentifierHint] = hint
        }
        return CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary)
    }

    fileprivate static func prefetch(_ url: URL, frame: Int, byteLimit: Int) -> DecodedImage? {
        let ext = url.pathExtension.lowercased()
        // These formats need their dedicated loader before a reliable pixel estimate is available.
        guard byteLimit > 0, !ImageFormats.isPixelmator(url),
              !["pdf", "svg", "svgz", "wbmp", "xbm", "xpm"].contains(ext),
              let source = fileSource(url) else { return nil }
        return decode(source, extension: ext, frame: frame, prefetchByteLimit: byteLimit)
    }

    fileprivate static func decode(_ source: CGImageSource, extension ext: String, frame: Int,
                                   prefetchByteLimit: Int? = nil) -> DecodedImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [String: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        if let limit = prefetchByteLimit {
            guard width > 0, height > 0 else { return nil }
            let depth = properties[kCGImagePropertyDepth as String] as? Int ?? 16
            let isFloat = properties[kCGImagePropertyIsFloat as String] as? Bool == true
            let bytesPerPixel = isFloat || depth > 16 ? 16 : (depth > 8 ? 8 : 4)
            guard width <= limit / bytesPerPixel / height else { return nil }
        }
        let oriented: CGImage?
        if let orientation = properties[kCGImagePropertyOrientation as String] as? Int, orientation > 1,
           width > 0, height > 0 {
            oriented = CGImageSourceCreateThumbnailAtIndex(source, frame, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: max(width, height),
               kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            oriented = nil
        }
        let imageOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = oriented ?? CGImageSourceCreateImageAtIndex(source, frame, imageOptions) else { return nil }

        let animationKey = ext == "gif" ? "{GIF}" : "{WebP}"
        let timing = properties[animationKey] as? [String: Any]
        let delay = timing?["UnclampedDelayTime"] as? Double ?? timing?["DelayTime"] as? Double ?? 0.1
        let container = (CGImageSourceCopyProperties(source, nil) as? [String: Any])?[animationKey] as? [String: Any]
        return DecodedImage(image: image, frameCount: ["gif", "webp"].contains(ext) ? CGImageSourceGetCount(source) : 1,
                            frameDelay: delay >= 0.02 && delay.isFinite ? delay : 0.1,
                            loopCount: container?["LoopCount"] as? Int)
    }

    private static func still(_ image: CGImage) -> DecodedImage {
        DecodedImage(image: image, frameCount: 1, frameDelay: 0, loopCount: nil)
    }

    private static func vector(_ url: URL, compressed: Bool) -> DecodedImage? {
        let image: NSImage?
        if compressed {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 << 20,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let expanded = data.inflated(gzip: true, limit: 32 << 20) else { return nil }
            image = NSImage(data: expanded)
        } else { image = NSImage(contentsOf: url) }
        guard let image else { return nil }
        let largest = max(image.size.width, image.size.height)
        guard largest.isFinite, largest > 0 else { return nil }
        let scale = min(1, 4096 / largest)
        var bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        guard let raster = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return nil }
        let width = max(1, Int(ceil(image.size.width * scale)))
        let height = max(1, Int(ceil(image.size.height * scale)))
        if raster.width == width, raster.height == height { return still(raster) }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(raster, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(still)
    }

    private static func pdf(_ url: URL) -> DecodedImage? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let width = rotated ? box.height : box.width
        let height = rotated ? box.width : box.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let scale = min(2, 4096 / max(width, height))
        let w = max(1, Int(ceil(width * scale)))
        let h = max(1, Int(ceil(height * scale)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage().map(still)
    }
}

public actor ImagePipeline {
    private struct Key: Hashable, Sendable {
        let path: String
        let modified: Date
        let size: Int
        let identity: String
        let frame: Int
        let playback: UUID?
    }

    private struct Cached {
        let image: DecodedImage
        var access: UInt64
    }

    private let limit: Int
    private var bytes = 0
    private var access: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var cache: [Key: Cached] = [:]
    private let foreground: DecodeLane
    private let background: DecodeLane

    public init(byteLimit: Int = 192 * 1024 * 1024) {
        self.init(byteLimit: byteLimit, prefetchDecode: { url, frame in
            ImageDecoder.prefetch(url, frame: frame, byteLimit: min(byteLimit, 64 * 1024 * 1024))
        }, decode: ImageDecoder.decode)
    }

    init(byteLimit: Int = 192 * 1024 * 1024, prefetchDecode: (@Sendable (URL, Int) -> DecodedImage?)? = nil,
         decode: @escaping @Sendable (URL, Int) -> DecodedImage?) {
        limit = byteLimit
        foreground = DecodeLane(label: "YeeX decode", qos: .userInitiated, decode: decode)
        background = DecodeLane(label: "YeeX prefetch", qos: .utility, decode: prefetchDecode ?? decode)
    }

    public func invalidateImages(in folder: URL) {
        let path = folder.standardizedFileURL.path.decomposedStringWithCanonicalMapping
        invalidate { ($0.path as NSString).deletingLastPathComponent == path }
    }

    private func invalidate(where matches: (Key) -> Bool) {
        cacheGeneration &+= 1
        for key in cache.keys.filter(matches) {
            if let removed = cache.removeValue(forKey: key) { bytes -= removed.image.byteCount }
        }
    }

    public func image(_ record: ImageRecord, frame: Int = 0, prefetch: Bool = false,
                      refresh: Bool = false, playback: AnimationPlayback? = nil) async -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        let playback = playback.flatMap { $0.url == record.url ? $0 : nil }
        let key = Key(path: record.id, modified: record.modified, size: record.size,
                      identity: record.identity, frame: frame, playback: playback?.id)
        access &+= 1
        if !refresh, let cached = cache[key] {
            cache[key]?.access = access
            return cached.image
        }
        if refresh {
            invalidate { $0.path == record.id }
        }
        let generation = cacheGeneration
        let lane = prefetch ? background : foreground
        guard let image = await lane.run(url: record.url, frame: frame, playback: playback),
              !Task.isCancelled else { return nil }
        if generation == cacheGeneration, image.byteCount <= limit {
            if let previous = cache.removeValue(forKey: key) { bytes -= previous.image.byteCount }
            while bytes + image.byteCount > limit || cache.count >= 64 {
                guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key,
                      let dropped = cache.removeValue(forKey: oldest) else { break }
                bytes -= dropped.image.byteCount
            }
            access &+= 1
            cache[key] = Cached(image: image, access: access)
            bytes += image.byteCount
        }
        return image
    }
}

private final class DecodeLane: Sendable {
    private let queue: DispatchQueue
    private let decode: @Sendable (URL, Int) -> DecodedImage?

    init(label: String, qos: DispatchQoS, decode: @escaping @Sendable (URL, Int) -> DecodedImage?) {
        queue = DispatchQueue(label: label, qos: qos)
        self.decode = decode
    }

    func run(url: URL, frame: Int, playback: AnimationPlayback?) async -> DecodedImage? {
        let cancelled = OSAllocatedCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let image = cancelled.value ? nil : autoreleasepool {
                        if let playback { return playback.decode(frame: frame) }
                        return self.decode(url, frame)
                    }
                    continuation.resume(returning: image)
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }
}

private final class OSAllocatedCancellation: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { lock.withLock { $0 } }
    func cancel() { lock.withLock { $0 = true } }
}
