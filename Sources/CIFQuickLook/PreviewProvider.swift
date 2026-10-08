import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import os.log
import CIFCore

/// Quick Look preview extension principal class.
/// Renders a static ball-and-stick PNG of the first structural block; on any
/// parse/render failure it returns a short text reason instead of nothing.
/// Note: @objc alias + keep-alive in main.swift — without an ObjC-visible
/// name and reference the linker dead-strips the class record entirely
/// (Info.plist references are invisible to it), and QuickLook reports
/// "extension not found". Info.plist must then use the bare ObjC name.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    private static let log = Logger(subsystem: "org.cifpreview.CIFPreview", category: "preview")

    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        Self.log.info("preview requested for \(request.fileURL.lastPathComponent, privacy: .public)")
        let breadcrumb = FileManager.default.temporaryDirectory
            .appendingPathComponent("cif_ql_breadcrumb.txt")
        try? "providePreview ran at \(Date()) for \(request.fileURL.lastPathComponent)\n"
            .write(to: breadcrumb, atomically: true, encoding: .utf8)
        do {
            let data = try Data(contentsOf: request.fileURL)
            let model = try StructureExtractor.extract(from: data)
            guard let scene = SceneBuilder.scene(for: model) else {
                throw ExtractError.noStructure
            }
            guard let png = Snapshot.pngData(for: scene, size: SceneBuilder.canvasSize) else {
                throw ExtractError.parsing("scene snapshot failed")
            }
            let reply = QLPreviewReply(dataOfContentType: .png,
                                       contentSize: CGSize(width: 800, height: 600)) { _ in
                png
            }
            handler(reply, nil)
        } catch {
            let text = Data("CIF structure preview unavailable.\n\(error)\n".utf8)
            let reply = QLPreviewReply(dataOfContentType: .plainText,
                                       contentSize: CGSize(width: 480, height: 120)) { _ in
                text
            }
            handler(reply, nil)
        }
    }
}
