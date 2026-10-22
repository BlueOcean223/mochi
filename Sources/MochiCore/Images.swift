import CoreGraphics
import Foundation
import ImageIO

public enum Images {
    /// 长边不超过 `maxPixel` 的图（不放大），按 EXIF 方向转正，画在自己的位图里。
    ///
    /// 不用 `CGImageSourceCreateThumbnailAtIndex`：它给的图背后挂着 ImageIO 的解码缓存（每张几 MB，最多留 30 来张），
    /// 图还在用时系统回收不了。面板里翻过几十张图，内存涨到一两百 MB，收起也不降。
    /// 这里整张解码再画小：解码用的内存用完就能收回，留下的只有画出来的那张。
    /// 降采样解码（`kCGImageSourceSubsampleFactor`）峰值低，可解出来的结果 ImageIO 也会留在缓存里收不回去，
    /// 所以只给特别大的图用（超过 1600 万像素，比如 4800 万像素的照片，整张解要近 200 MB）。
    public static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { downsample($0, maxPixel: maxPixel) }
    }

    public static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { downsample($0, maxPixel: maxPixel) }
    }

    /// 写成 PNG。先写到临时文件再换过去，读的一方不会读到半个文件。
    @discardableResult
    public static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, PasteboardTypes.png as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        return (try? (data as Data).write(to: url, options: .atomic)) != nil
    }

    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        var factor = 1
        while factor < 8, (width / factor) * (height / factor) > 16_000_000, max(width, height) / (factor * 2) >= maxPixel {
            factor *= 2
        }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
        let swapsSides = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let upright = swapsSides ? CGSize(width: image.height, height: image.width) : CGSize(width: image.width, height: image.height)
        let scale = min(1, CGFloat(maxPixel) / max(upright.width, upright.height))
        let outputWidth = max(1, Int((upright.width * scale).rounded()))
        let outputHeight = max(1, Int((upright.height * scale).rounded()))

        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(outputWidth) / upright.width, y: CGFloat(outputHeight) / upright.height)
        context.concatenate(transform(for: orientation, width: CGFloat(image.width), height: CGFloat(image.height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 把存的图（宽 `width`、高 `height`）画正的变换，用的是 Core Graphics 的坐标（原点在左下）。
    /// EXIF 方向说的是存的第 0 行、第 0 列在看的时候在哪一边，比如 `.right`：第 0 行在右边，第 0 列在上边。
    private static func transform(for orientation: CGImagePropertyOrientation, width w: CGFloat, height h: CGFloat) -> CGAffineTransform {
        switch orientation {
        case .up: .identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
    }
}
