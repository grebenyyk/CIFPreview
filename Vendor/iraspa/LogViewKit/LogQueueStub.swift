// Minimal stand-in for iRASPA's LogViewKit. The upstream module is an AppKit
// script-log text view; SymmetryKit only ever calls LogQueue.shared.warning(...),
// so we provide a no-op sink that sends warnings to stderr instead.
// Upstream (MIT): https://github.com/iRASPA/iRASPA-COCOA  LogViewKit/LogQueue.swift

import Foundation
import os.log

public final class LogQueue {
    public static let shared = LogQueue()
    private let log = OSLog(subsystem: "org.dimitrygrebenyuk.CIFPreview", category: "parser")

    public func warning(destination: AnyObject?, message: String, completionHandler: @escaping () -> () = {}) {
        os_log(.default, log: log, "warning: %{public}@", message)
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
        completionHandler()
    }
    public func error(destination: AnyObject?, message: String, completionHandler: @escaping () -> () = {}) {
        os_log(.default, log: log, "error: %{public}@", message)
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        completionHandler()
    }
    public func info(destination: AnyObject?, message: String, completionHandler: @escaping () -> () = {}) {
        completionHandler()
    }
    public func debug(destination: AnyObject?, message: String, completionHandler: @escaping () -> () = {}) {
        completionHandler()
    }
}
