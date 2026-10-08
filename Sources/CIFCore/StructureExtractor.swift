import Foundation
import simd
import MathKit
import SymmetryKit

/// Turns raw CIF bytes into a render-ready model:
/// block selection → SKCIFParser → symmetry resolution → expansion → dedup → caps.
public enum StructureExtractor {

    /// Hard caps. The expansion cap stops pathological symmetry blowups; the
    /// render cap keeps SceneKit interactive. Atoms keep file order, so the
    /// explicitly listed (asymmetric) atoms are always rendered first.
    public static let maxExpandedAtoms = 60_000
    public static let maxRenderedAtoms = 15_000

    public static func extract(from fileData: Data) throws -> RenderModel {
        guard let block = BlockSelector.firstStructuralBlock(of: fileData) else {
            throw ExtractError.noStructuralBlock
        }

        let parser: SKCIFParser
        do {
            parser = try SKCIFParser(displayName: "preview", data: block)
            try parser.startParsing()
        } catch {
            throw ExtractError.parsing(String(describing: error))
        }

        guard let frame = parser.scene.first?.first else {
            throw ExtractError.noStructure
        }
        return try model(from: frame)
    }

    // MARK: - frame → model

    private static func model(from frame: SKStructure) throws -> RenderModel {
        var model = RenderModel()
        model.meta.asymCount = frame.atoms.count
        model.meta.formula = frame.chemicalFormulaSum?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !frame.atoms.isEmpty else {
            model.meta.mode = .empty
            return model
        }

        // ---- cell & dummy-cell detection ----------------------------------
        // 197 files in the user's corpus (P_cif.py output) store Cartesian Å
        // coordinates under _atom_site_fract_x with a dummy cubic cell of
        // a≈1.0–1.02 Å. Real crystals never have a < 3 Å cell whose stored
        // "fractional" coordinates exceed the cell edge, so that combination
        // means: coordinates are Cartesian, the cell is meaningless.
        var cell: SKCell? = frame.cell
        if let skCell = cell {
            let lengths = [skCell.unitCell.columns.0, skCell.unitCell.columns.1, skCell.unitCell.columns.2]
                .map { simd_length($0) }
            let minEdge = lengths.min() ?? 0
            let maxExtent = frame.atoms.reduce(0.0) {
                max($0, abs($1.position.x), abs($1.position.y), abs($1.position.z))
            }
            if minEdge < 3.0 && maxExtent > minEdge {
                cell = nil
                model.meta.mode = .cartesian
                model.meta.parseWarnings.append("dummy unit cell: coordinates are Cartesian")
            } else {
                let angles = [skCell.alpha, skCell.beta, skCell.gamma].map { $0 * 180.0 / .pi }
                model.meta.cellParams = lengths + angles
            }
        }
        model.cell = cell.map { RenderCell(a: $0.unitCell.columns.0,
                                           b: $0.unitCell.columns.1,
                                           c: $0.unitCell.columns.2) }

        // ---- symmetry operations ------------------------------------------
        let ops = resolveOperations(for: frame)
        recordSpaceGroupMeta(frame, into: &model)

        // ---- expansion ------------------------------------------------------
        // crystal mode: wrap into the cell, expand by symmetry, dedup.
        // cartesian mode (dummy cell): coordinates pass through verbatim —
        // wrapping them into [0,1) would fold an 8 Å cluster back into the cell.
        let isCrystal = model.meta.mode == .crystal
        let lattice = model.cell?.columnsAsMatrix ?? double3x3(columns: (SIMD3<Double>(1, 0, 0),
                                                                         SIMD3<Double>(0, 1, 0),
                                                                         SIMD3<Double>(0, 0, 1)))
        var expanded = expand(atoms: frame.atoms, ops: ops, lattice: lattice,
                              wrap: isCrystal, cap: maxExpandedAtoms)
        model.meta.truncated = expanded.count > maxRenderedAtoms
        if model.meta.truncated {
            // prefer heavy atoms in the rendered set: drop bare hydrogen first, then truncate
            let heavy = expanded.filter { $0.element != "H" }
            expanded = heavy.count >= maxRenderedAtoms / 4
                ? Array(heavy.prefix(maxRenderedAtoms))
                : Array(expanded.prefix(maxRenderedAtoms))
        }
        model.atoms = expanded
        model.bonds = BondFinder.find(atoms: model.atoms, cell: model.cell, periodic: isCrystal)
        return model
    }

    // MARK: - symmetry

    private static func resolveOperations(for frame: SKStructure) -> [SKSeitzIntegerMatrix] {
        // 1. operations written in the file itself are authoritative (they may
        //    reflect non-standard origin choices the H-M name cannot express)
        if let fromFile = frame.cifSymmetryOperations, !fromFile.isEmpty {
            return fromFile
        }
        // 2. resolve from the declared space group (Hall number picked by the
        //    parser from H-M / Hall / IT-number, or 1 when absent)
        if let hall = frame.spaceGroupHallNumber, hall > 0 {
            let setting = SKSpacegroup(HallNumber: hall).spaceGroupSetting
            return SKIntegerSymmetryOperationSet(spaceGroupSetting: setting,
                                                 centroSymmetric: false).operations
        }
        // 3. P1
        return [SKSeitzIntegerMatrix()]
    }

    private static func recordSpaceGroupMeta(_ frame: SKStructure, into model: inout RenderModel) {
        let hall = frame.spaceGroupHallNumber ?? 0
        guard hall > 0 else { return }
        let setting = SKSpacegroup(HallNumber: hall).spaceGroupSetting
        model.meta.spaceGroup = setting.HM.isEmpty ? nil : setting.HM
        model.meta.spaceGroupNumber = setting.spaceGroupNumber > 0 ? setting.spaceGroupNumber : nil
        model.meta.hallSymbol = setting.Hall.isEmpty ? nil : setting.Hall
    }

    private static func expand(atoms: [SKAsymmetricAtom],
                               ops: [SKSeitzIntegerMatrix],
                               lattice: double3x3,
                               wrap: Bool,
                               cap: Int) -> [RenderAtom] {
        var result: [RenderAtom] = []
        result.reserveCapacity(min(atoms.count * ops.count, cap))
        var seen = DedupGrid()

        for atom in atoms {
            let element = elementSymbol(atomicNumber: atom.elementIdentifier,
                                        fallbackLabel: atom.displayName)
            for op in ops {
                let f = apply(op, to: atom.position, wrap: wrap)
                // dedup only makes sense in wrapped fractional space; the
                // cartesian path holds explicit-atom supercells with no repeats
                let isNew = wrap ? seen.insert(f, element: element) : true
                if isNew {
                    if result.count >= cap { return result }
                    // fractional → Cartesian (identity for the a=b=c=1, 90° dummy cell,
                    // which is why Cartesian-disguised files survive this path too)
                    result.append(RenderAtom(element: element, position: lattice * f))
                }
            }
        }
        return result
    }

    /// Seitz application with the iRASPA convention: translation denominator = 24.
    @inline(__always)
    private static func apply(_ op: SKSeitzIntegerMatrix, to f: SIMD3<Double>, wrap: Bool) -> SIMD3<Double> {
        let r = op.rotation
        var out = SIMD3<Double>.zero
        out.x = Double(r[0, 0]) * f.x + Double(r[0, 1]) * f.y + Double(r[0, 2]) * f.z
        out.y = Double(r[1, 0]) * f.x + Double(r[1, 1]) * f.y + Double(r[1, 2]) * f.z
        out.z = Double(r[2, 0]) * f.x + Double(r[2, 1]) * f.y + Double(r[2, 2]) * f.z
        out += SIMD3<Double>(op.translation) / 24.0
        guard wrap else { return out }
        // wrap into [0,1)
        out -= out.rounded(.down)
        if out.x >= 1.0 { out.x -= 1.0 }
        if out.y >= 1.0 { out.y -= 1.0 }
        if out.z >= 1.0 { out.z -= 1.0 }
        return out
    }

    // MARK: - elements

    private static let knownSymbols: Set<String> = {
        var set = Set<String>()
        for element in PredefinedElements.sharedInstance.elementSet where !element.chemicalSymbol.isEmpty {
            set.insert(element.chemicalSymbol)
        }
        return set
    }()

    /// Element symbol from the atomic number, falling back to parsing the site
    /// label ("O11'" → O, "Th1" → Th, "H6A" → H) for the rare files that carry
    /// no clean `_atom_site_type_symbol`.
    private static func elementSymbol(atomicNumber: Int, fallbackLabel: String) -> String {
        let elements = PredefinedElements.sharedInstance.elementSet
        if atomicNumber > 0, atomicNumber < elements.count {
            let s = elements[atomicNumber].chemicalSymbol
            if !s.isEmpty { return s }
        }
        let letters = fallbackLabel.prefix { $0.isLetter }
        if letters.count >= 2,
           let two = characters(letters, 2), knownSymbols.contains(two) {
            return two
        }
        if let one = characters(letters, 1), knownSymbols.contains(one) {
            return one
        }
        return letters.count >= 2 ? String(letters.prefix(2)) : (letters.isEmpty ? "X" : String(letters))
    }

    private static func characters(_ s: Substring, _ n: Int) -> String? {
        guard s.count >= n else { return nil }
        return String(s.prefix(n))
    }
}

/// Hash-grid over wrapped fractional coordinates for O(1) duplicate rejection.
/// Symmetry-generated duplicates coincide to floating-point exactness (≈1e-12),
/// while genuinely distinct sites — including disorder components — differ by
/// ≫ 1e-4 fractional, so a tight tolerance merges exactly the duplicates.
struct DedupGrid {
    static let tolerance = 5e-5
    private var buckets: [Int: [Int]] = [:]
    private var coords: [SIMD3<Double>] = []
    private var elements: [String] = []

    mutating func insert(_ f: SIMD3<Double>, element: String) -> Bool {
        let base = bucketCoords(f)
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let delta = SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))
                    let key = bucketKey(base &+ delta)
                    for idx in buckets[key] ?? [] {
                        guard elements[idx] == element else { continue }
                        if minImageDelta(f, coords[idx]) {
                            return false
                        }
                    }
                }
            }
        }
        let idx = coords.count
        coords.append(f)
        elements.append(element)
        buckets[bucketKey(base), default: []].append(idx)
        return true
    }

    private func bucketCoords(_ f: SIMD3<Double>) -> SIMD3<Int32> {
        let scale = 1.0 / Self.tolerance
        return SIMD3<Int32>(Int32((f.x * scale).rounded(.down)),
                            Int32((f.y * scale).rounded(.down)),
                            Int32((f.z * scale).rounded(.down)))
    }

    private func bucketKey(_ cell: SIMD3<Int32>) -> Int {
        Int(cell.x) &+ (Int(cell.y) &<< 20) &+ (Int(cell.z) &<< 42)
    }

    /// true when |Δ| ≤ tolerance per axis, minimum-image across the periodic seam.
    private func minImageDelta(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        var d = a - b
        d -= d.rounded(.toNearestOrAwayFromZero)
        return abs(d.x) <= Self.tolerance && abs(d.y) <= Self.tolerance && abs(d.z) <= Self.tolerance
    }
}
