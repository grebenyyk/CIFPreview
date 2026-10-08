// MARK: - CLI debug modes
// CIFQLTool — CLI oracle/debug harness (parse, stats, render). The appex
// executable is a separate target whose entry is the extension bootstrap.
import Foundation
import CIFCore

// CLI debug modes (used by the test oracle). Anything else — including how
// launchd invokes the appex — must fall through to the extension bootstrap:
// exiting here (e.g. with EX_USAGE on unrecognized argv) is what QuickLook
// surfaces as "extension not found".
let args = CommandLine.arguments
if args.count >= 3 {
    switch (args[1], args[2]) {

    case ("--probe", _):
        // simulate the extension runtime's principal-class lookup
        for name in ["PreviewProvider", "CIFQuickLook.PreviewProvider"] {
            let cls = NSClassFromString(name)
            print("\(name) -> \(cls.map(String.init(describing:)) ?? "nil")")
        }
        exit(0)

    case ("--stats", let path):
        stats(path)
        exit(0)   // stats() exits non-zero itself on failure

    case ("--render", let path) where args.count >= 4:
        render(input: path, output: args[3])
        exit(0)

    default:
        break
    }
}

func loadModel(_ path: String) -> Result<RenderModel, Error> {
    guard let data = FileManager.default.contents(atPath: path) else {
        return .failure(ExtractError.parsing("cannot read \(path)"))
    }
    do {
        return .success(try StructureExtractor.extract(from: data))
    } catch {
        return .failure(error)
    }
}

func stats(_ path: String) {
    struct Stats: Codable {
        var file: String
        var mode: String
        var spaceGroup: String?
        var spaceGroupNumber: Int?
        var hallSymbol: String?
        var formula: String?
        var cell: [Double]
        var asymAtoms: Int
        var expandedAtoms: Int
        var bonds: Int
        var truncated: Bool
        var warnings: [String]
        var error: String?
    }

    var stats = Stats(file: path, mode: "empty", spaceGroup: nil, spaceGroupNumber: nil,
                      hallSymbol: nil, formula: nil, cell: [], asymAtoms: 0, expandedAtoms: 0,
                      bonds: 0, truncated: false, warnings: [], error: nil)

    switch loadModel(path) {
    case .success(let model):
        stats.mode = model.meta.mode.rawValue
        stats.spaceGroup = model.meta.spaceGroup
        stats.spaceGroupNumber = model.meta.spaceGroupNumber
        stats.hallSymbol = model.meta.hallSymbol
        stats.formula = model.meta.formula
        stats.cell = model.meta.cellParams
        stats.asymAtoms = model.meta.asymCount
        stats.expandedAtoms = model.atoms.count
        stats.bonds = model.bonds.count
        stats.truncated = model.meta.truncated
        stats.warnings = model.meta.parseWarnings
    case .failure(let error):
        stats.error = String(describing: error)
        if let data = try? JSONEncoder().encode(stats) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(1)
    }

    let data = (try? JSONEncoder().encode(stats)) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
}

func render(input: String, output: String) {
    switch loadModel(input) {
    case .failure(let error):
        FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
        exit(1)
    case .success(let model):
        guard let scene = SceneBuilder.scene(for: model),
              let png = Snapshot.pngData(for: scene, size: SceneBuilder.canvasSize) else {
            FileHandle.standardError.write(Data("render failed: scene/snapshot error\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: output))
    }
}

// forensic: what does the bootstrap actually receive?
do {
    let bd = Bundle.main
    let info: [String: Any] = bd.infoDictionary ?? [:]
    let msg = "bundle:\(bd.bundlePath)\ninfoCount:\(info.count)\n"
    try? msg.write(to: URL(fileURLWithPath: "/tmp/cif_ql_probe.txt"), atomically: true, encoding: .utf8)
}
print("done")
