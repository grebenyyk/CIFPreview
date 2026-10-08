// The real entry point of this appex is _NSExtensionMain (linker -e flag),
// exactly as Xcode links extension targets. SPM requires a main.swift for
// executableTargets, so this file exists but is never executed — the CLI
// debug harness lives in the CIFQLTool target instead.
import Foundation
import CIFCore

// keeps the principal class's ObjC record alive: nothing else in this target
// references it, and Info.plist references are invisible to the linker
private let _keepPrincipalClassAlive: [Any.Type] = [PreviewProvider.self]
