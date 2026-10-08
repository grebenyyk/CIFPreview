// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cif-ql",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "CIFCore", targets: ["CIFCore"]),
        .library(name: "SymmetryKit", targets: ["SymmetryKit"]),
    ],
    targets: [
        // MARK: vendored iRASPA components (MIT) — see Vendor/iraspa/NOTICE
        .target(
            name: "MathKit",
            path: "Vendor/iraspa/MathKit",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "BinaryCodable",
            dependencies: ["MathKit"],
            path: "Vendor/iraspa/BinaryCodable",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "LogViewKit",
            path: "Vendor/iraspa/LogViewKit",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "SymmetryKit",
            dependencies: ["MathKit", "BinaryCodable", "LogViewKit"],
            path: "Vendor/iraspa/SymmetryKit",
            exclude: [
                "Info.plist",
                // editor-model UI cluster: SKAtomTreeNode has an unconditional `import CloudKit`,
                // and the tree/bond controllers only serve iRASPA's document UI — not CIF parsing.
                "SKAtomTreeNode.swift",
                "SKAtomTreeController.swift",
                "SKBondSetController.swift",
            ]
        ),

        // MARK: ours
        .target(
            name: "CIFCore",
            dependencies: ["SymmetryKit", "MathKit"],
            path: "Sources/CIFCore"
        ),
        .executableTarget(
            name: "CIFQuickLook",
            dependencies: ["CIFCore", "SymmetryKit"],
            path: "Sources/CIFQuickLook",
            linkerSettings: [
                // Apple's extension entry point, as Xcode links appex targets
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .executableTarget(
            name: "CIFQLTool",
            dependencies: ["CIFCore", "SymmetryKit"],
            path: "Sources/CIFQLTool"
        ),
        .executableTarget(
            name: "CIFPreviewHost",
            path: "Sources/CIFPreviewHost"
        ),
    ]
)
