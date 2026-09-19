// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

@main struct RenderIcon {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let size = points * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                let factor = CGFloat(size) / 1024
                let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
                let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
                NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.23, blue: 0.27, alpha: 1), ending: NSColor(srgbRed: 0.055, green: 0.10, blue: 0.16, alpha: 1))!.draw(in: tile, angle: -90)
                AppIcon.drawMark(in: NSRect(x: 216, y: 216, width: 592, height: 592), color: NSColor(srgbRed: 0.45, green: 0.89, blue: 0.80, alpha: 1))
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
    }
}
