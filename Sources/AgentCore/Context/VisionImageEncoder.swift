//
//  VisionImageEncoder.swift
//
//  Loads a raster image from disk, downscales if needed, and produces a
//  `ChatImagePayload` suitable for multimodal chat-completions requests.
//  Uses ImageIO only (no AppKit) so AgentCore stays UI-free.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

public enum VisionImageEncoder {

    /// Longest edge after downscale (pixels). Vision token cost scales with
    /// resolution; 1536 is a common local-server sweet spot.
    public static let maxLongEdge: CGFloat = 1536

    /// Hard cap on images per user turn (context + latency).
    public static let maxImagesPerMessage = 4

    /// Skip encoding if source file is larger than this (pre-decode).
    public static let maxSourceBytes = 25 * 1024 * 1024

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"
    ]

    public static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    public static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        default: return "image/jpeg"
        }
    }

    /// Encode a file into a vision payload, or nil if not an image / unreadable.
    public static func payload(
        fromFilePath path: String,
        displayName: String? = nil,
        maxLongEdge: CGFloat = maxLongEdge
    ) -> ChatImagePayload? {
        let expanded = (path as NSString).expandingTildeInPath
        guard isImagePath(expanded) else { return nil }
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
           let size = attrs[.size] as? NSNumber,
           size.intValue > maxSourceBytes {
            return nil
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }

        // Prefer JPEG for photos (smaller); keep PNG for images with alpha
        // when the source was PNG and has alpha.
        let sourceMIME = mimeType(forPath: expanded)
        let usePNG = sourceMIME == "image/png" && cgImage.alphaInfo != .none
            && cgImage.alphaInfo != .noneSkipLast
            && cgImage.alphaInfo != .noneSkipFirst

        guard let (data, mime) = encode(cgImage: cgImage, asPNG: usePNG) else { return nil }
        let b64 = data.base64EncodedString()
        return ChatImagePayload(
            mimeType: mime,
            base64Data: b64,
            sourcePath: expanded,
            displayName: displayName ?? url.lastPathComponent
        )
    }

    /// Encode an in-memory bitmap (computer-use screenshot). Downscales
    /// so local vision context stays bounded. JPEG by default (smaller
    /// than PNG for desktop photos); pass `preferJPEG: false` for UI
    /// screenshots that must stay lossless.
    public static func payload(
        fromCGImage image: CGImage,
        displayName: String,
        maxLongEdge: CGFloat = maxLongEdge,
        preferJPEG: Bool = true
    ) -> ChatImagePayload? {
        let scaled = downscaled(image, maxLongEdge: maxLongEdge)
        guard let (data, mime) = encode(cgImage: scaled, asPNG: !preferJPEG) else { return nil }
        return ChatImagePayload(
            mimeType: mime,
            base64Data: data.base64EncodedString(),
            displayName: displayName
        )
    }

    /// Pixel size after the same downscale `payload(fromCGImage:)` applies.
    public static func scaledSize(width: Int, height: Int, maxLongEdge: CGFloat = maxLongEdge) -> (width: Int, height: Int) {
        let w = CGFloat(max(1, width))
        let h = CGFloat(max(1, height))
        let longEdge = max(w, h)
        guard longEdge > maxLongEdge, maxLongEdge > 0 else {
            return (width: max(1, width), height: max(1, height))
        }
        let scale = maxLongEdge / longEdge
        return (
            width: max(1, Int((w * scale).rounded())),
            height: max(1, Int((h * scale).rounded()))
        )
    }

    /// Encode multiple attachment paths; non-images skipped; capped at maxImages.
    public static func payloads(
        fromPaths paths: [(path: String, displayName: String?)],
        maxImages: Int = maxImagesPerMessage
    ) -> [ChatImagePayload] {
        var out: [ChatImagePayload] = []
        for item in paths {
            guard out.count < maxImages else { break }
            if let p = payload(fromFilePath: item.path, displayName: item.displayName) {
                out.append(p)
            }
        }
        return out
    }

    // MARK: - Encode

    private static func downscaled(_ image: CGImage, maxLongEdge: CGFloat) -> CGImage {
        let target = scaledSize(width: image.width, height: image.height, maxLongEdge: maxLongEdge)
        guard target.width != image.width || target.height != image.height else { return image }
        let colorSpace: CGColorSpace
        if let space = image.colorSpace, space.model == .rgb {
            colorSpace = space
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }
        let alpha = image.alphaInfo
        let bitmapInfo: CGBitmapInfo
        if alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        } else {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return ctx.makeImage() ?? image
    }

    private static func encode(cgImage: CGImage, asPNG: Bool) -> (Data, String)? {
        let data = NSMutableData()
        let uti: CFString = asPNG
            ? UTType.png.identifier as CFString
            : UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if !asPNG {
            props[kCGImageDestinationLossyCompressionQuality] = 0.85
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, asPNG ? "image/png" : "image/jpeg")
    }
}
