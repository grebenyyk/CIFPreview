import AppKit
import SceneKit
import Metal

/// Offscreen render of the scene to an sRGB-tagged PNG.
public enum Snapshot {

    public static func pngData(for scene: SCNScene, size: CGSize) -> Data? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        if let camera = scene.rootNode.childNode(withName: "camera", recursively: false) {
            renderer.pointOfView = camera
        }

        let image = renderer.snapshot(atTime: 0,
                                      with: size,
                                      antialiasingMode: .multisampling4X)
        return sRGBPNG(from: image)
    }

    /// Re-draw into an sRGB bitmap so Finder/QuickLook never guess the color space.
    private static func sRGBPNG(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width, height = cgImage.height
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let tagged = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: tagged)
        return rep.representation(using: .png, properties: [:])
    }
}
