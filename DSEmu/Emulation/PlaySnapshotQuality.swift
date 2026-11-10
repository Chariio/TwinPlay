// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Tells a real gameplay still from a blank frame, and copies a still out of
// a CAMetalLayer's `contents` (the 3DS Vulkan swapchain has no software FB).
import CoreImage
import IOSurface
import QuartzCore
import UIKit

enum PlaySnapshotQuality {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// True when enough pixels are not near-black for this to be a real picture.
    static func isUsable(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        return isUsable(cg)
    }

    static func isUsable(_ cg: CGImage) -> Bool {
        let w = 48, h = 48
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lit = 0
        var i = 0
        while i < px.count {
            if max(px[i], px[i + 1], px[i + 2]) > 28 { lit += 1 }
            i += 4
        }
        return lit > (w * h) / 100
    }

    /// Durable copy of `CAMetalLayer.contents` / `presentation()?.contents`.
    /// Returns nil when the object is missing or the picture is blank.
    static func image(fromLayerContents contents: Any?) -> UIImage? {
        guard let contents else { return nil }
        let cf = contents as CFTypeRef
        let type = CFGetTypeID(cf)
        if type == CGImage.typeID {
            return usable(UIImage(cgImage: unsafeBitCast(contents, to: CGImage.self)))
        }
        if let img = contents as? UIImage { return usable(img) }
        if type == IOSurfaceGetTypeID() {
            let surface = unsafeBitCast(contents, to: IOSurface.self)
            let ci = CIImage(ioSurface: surface)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
            return usable(UIImage(cgImage: cg))
        }
        return nil
    }

    private static func usable(_ image: UIImage) -> UIImage? {
        isUsable(image) ? image : nil
    }
}
