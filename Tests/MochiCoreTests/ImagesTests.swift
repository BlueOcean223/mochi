import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MochiCore

final class ImagesTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "mochi-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test(arguments: [
        CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
    ])
    func turnsUprightLikeImageIO(orientation: CGImagePropertyOrientation) throws {
        // TIFF 存得下方向（PNG 存不下，读回来都是 .up，测不出东西）。
        let url = try write(quadrants(width: 60, height: 40), orientation: orientation, type: .tiff)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyOrientation] as? UInt32 == orientation.rawValue)

        let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
        ] as CFDictionary))
        let ours = try #require(Images.downsample(url, maxPixel: 1000))
        #expect(ours.width == reference.width)
        #expect(ours.height == reference.height)
        for (x, y) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            #expect(color(ours, x, y) == color(reference, x, y), "\(x), \(y)")
        }
    }

    @Test func uprightImageKeepsItsCorners() throws {
        let url = try write(quadrants(width: 60, height: 40), orientation: .up, type: .png)
        let image = try #require(Images.downsample(url, maxPixel: 1000))
        // 左上红、右上绿、左下蓝、右下白。取色从上往下数。
        #expect(color(image, 0.25, 0.25) == [255, 0, 0])
        #expect(color(image, 0.75, 0.25) == [0, 255, 0])
        #expect(color(image, 0.25, 0.75) == [0, 0, 255])
        #expect(color(image, 0.75, 0.75) == [255, 255, 255])
    }

    @Test func shrinksLongEdgeToMaxPixel() throws {
        let url = try write(quadrants(width: 3000, height: 2000), orientation: .up, type: .png)
        let image = try #require(Images.downsample(url, maxPixel: 1200))
        #expect(image.width == 1200)
        #expect(image.height == 800)
        let thumbnail = try #require(Images.downsample(url, maxPixel: 96))
        #expect(thumbnail.width == 96)
        #expect(thumbnail.height == 64)
        #expect(color(thumbnail, 0.75, 0.25) == [0, 255, 0])
    }

    @Test func neverEnlarges() throws {
        let url = try write(quadrants(width: 300, height: 200), orientation: .up, type: .png)
        let image = try #require(Images.downsample(url, maxPixel: 1200))
        #expect(image.width == 300)
        #expect(image.height == 200)
    }

    @Test func missingFileGivesNil() {
        #expect(Images.downsample(directory.appending(path: "nope.png"), maxPixel: 96) == nil)
        #expect(Images.pixelSize(directory.appending(path: "nope.png")) == nil)
    }

    @Test func pixelSizeIsUpright() throws {
        let up = try write(quadrants(width: 60, height: 40), orientation: .up, type: .png)
        #expect(Images.pixelSize(up) == CGSize(width: 60, height: 40))
        let right = try write(quadrants(width: 60, height: 40), orientation: .right, type: .tiff)
        #expect(Images.pixelSize(right) == CGSize(width: 40, height: 60))
    }

    // MARK: -

    /// 四个象限：左上红、右上绿、左下蓝、右下白。
    private func quadrants(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // Core Graphics 的原点在左下。
        for (rect, rgb) in [(CGRect(x: 0, y: h, width: w, height: h), (1.0, 0.0, 0.0)), (CGRect(x: w, y: h, width: w, height: h), (0, 1, 0)),
                            (CGRect(x: 0, y: 0, width: w, height: h), (0, 0, 1)), (CGRect(x: w, y: 0, width: w, height: h), (1, 1, 1))] {
            context.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            context.fill(rect)
        }
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, orientation: CGImagePropertyOrientation, type: UTType) throws -> URL {
        let url = directory.appending(path: "\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// 相对位置（从左上角量）那个像素的 sRGB 颜色。
    private func color(_ image: CGImage, _ x: Double, _ y: Double) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
            context.draw(image, in: CGRect(x: -px.rounded(.down), y: -py.rounded(.down), width: Double(image.width), height: Double(image.height)))
        }
        return Array(pixel.prefix(3))
    }
}
