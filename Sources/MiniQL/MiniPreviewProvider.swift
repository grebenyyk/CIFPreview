import Foundation
import QuickLookUI
import UniformTypeIdentifiers

@objc(MiniPreviewProvider)
final class MiniPreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let text = Data("MINI EXTENSION WORKS\n".utf8)
        handler(QLPreviewReply(dataOfContentType: .plainText,
                               contentSize: CGSize(width: 300, height: 60)) { _ in text }, nil)
    }
}
