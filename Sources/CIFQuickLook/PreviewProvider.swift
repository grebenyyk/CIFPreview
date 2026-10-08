import AppKit
import QuickLookUI
import os.log
import CIFCore

/// Quick Look preview extension principal class (macOS view-service contract):
/// the system instantiates this NSViewController and hosts its view in the
/// preview pane, then calls preparePreviewOfFile(at:). We render the structure
/// offscreen via SceneKit and present the resulting image.
///
/// Note: a keep-alive reference in main.swift keeps this class (and its
/// mangled ObjC name) from being dead-stripped — Info.plist references are
/// invisible to the linker.
final class PreviewProvider: NSViewController, QLPreviewingController {

    private static let log = Logger(subsystem: "org.cifpreview.CIFPreview", category: "preview")
    private static let previewSize = CGSize(width: 800, height: 600)

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.previewSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        view = root
    }

    func preparePreviewOfFile(at url: URL) async throws {
        Self.log.info("preview requested for \(url.lastPathComponent, privacy: .public)")
        do {
            let data = try Data(contentsOf: url)
            let model = try StructureExtractor.extract(from: data)
            guard let scene = SceneBuilder.scene(for: model),
                  let png = Snapshot.pngData(for: scene, size: SceneBuilder.canvasSize) else {
                throw ExtractError.noStructure
            }
            guard let image = NSImage(data: png) else {
                throw ExtractError.parsing("PNG decode failed")
            }
            await MainActor.run {
                let imageView = NSImageView(frame: view.bounds)
                imageView.image = image
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.autoresizingMask = [.width, .height]
                view.addSubview(imageView)
            }
        } catch {
            Self.log.error("preview failed: \(String(describing: error), privacy: .public)")
            await MainActor.run { Self.show(text: "CIF structure preview unavailable.\n\(error)", in: view) }
        }
    }

    @MainActor
    private static func show(text: String, in view: NSView) {
        let field = NSTextField(labelWithString: text)
        field.frame = view.bounds.insetBy(dx: 16, dy: 16)
        field.autoresizingMask = [.width, .height]
        field.isSelectable = true
        field.textColor = .secondaryLabelColor
        view.addSubview(field)
    }
}
