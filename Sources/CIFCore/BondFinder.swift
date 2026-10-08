import Foundation
import simd
import MathKit
import SymmetryKit

/// Distance-criteria bond finding with periodic boundary handling.
/// Grid-hash neighbor search, covalent radii + 0.45 Å tolerance, hydrogen
/// bonded to its single nearest heavy neighbor at most. Bonds that cross a
/// cell face carry the lattice offset of the image they reach, so the scene
/// builder can draw them as two half-bonds (no dangling stubs at boundaries).
public enum BondFinder {

    public static let tolerance = 0.45
    public static let maxBonds = 120_000
    /// neighbor search covers ±1 bucket; bucket size must exceed the largest
    /// possible bond length (≈ 2×2.3 Cs + 0.45 ≈ 5.1 Å)
    static let bucketSize = 6.0

    public static func find(atoms: [RenderAtom], cell: RenderCell?, periodic: Bool) -> [RenderBond] {
        guard atoms.count > 1, atoms.count <= StructureExtractor.maxRenderedAtoms else { return [] }
        let radii = CovalentRadii.shared

        let candidates: [BondCandidate] = (periodic && cell != nil)
            ? periodicCandidates(atoms, cell!, radii)
            : molecularCandidates(atoms, radii)

        return canonicalize(filterHydrogens(candidates, atoms: atoms))
    }

    // MARK: - candidate generation

    struct BondCandidate {
        var i: Int, j: Int
        var d2: Double
        var offset: SIMD3<Int32>   // lattice image of j (periodic mode), .zero otherwise
    }

    /// molecular mode: plain buckets over the Cartesian bounding box, no images
    private static func molecularCandidates(_ atoms: [RenderAtom], _ radii: CovalentRadii) -> [BondCandidate] {
        var minP = atoms[0].position, maxP = minP
        for a in atoms {
            minP = simd_min(minP, a.position); maxP = simd_max(maxP, a.position)
        }
        var grid: [Int: [Int]] = [:]
        let origin = minP - SIMD3<Double>(repeating: bucketSize)
        for (idx, a) in atoms.enumerated() {
            let c = SIMD3<Int32>(((a.position - origin) / bucketSize).rounded(.down))
            grid[key(c, wrap: nil), default: []].append(idx)
        }

        var result: [BondCandidate] = []
        for (idx, a) in atoms.enumerated() {
            let c = SIMD3<Int32>(((a.position - origin) / bucketSize).rounded(.down))
            for neighbor in grid.nearby(center: c, keyer: { key($0, wrap: nil) }) {
                guard neighbor > idx else { continue }              // each pair once
                guard atoms[idx].element != "H" || atoms[neighbor].element != "H" else { continue }
                let d = atoms[neighbor].position - a.position
                let d2 = simd_dot(d, d)
                if d2 <= cutoff2(a, atoms[neighbor], radii) {
                    result.append(BondCandidate(i: idx, j: neighbor, d2: d2, offset: .zero))
                }
            }
        }
        return result
    }

    /// periodic mode: fractional buckets, minimum-image distances, image offsets
    private static func periodicCandidates(_ atoms: [RenderAtom], _ cell: RenderCell,
                                           _ radii: CovalentRadii) -> [BondCandidate] {
        let lattice = cell.columnsAsMatrix
        guard let inverse = try? lattice.inverse else { return [] }
        let fracs = atoms.map { SIMD3<Double>(inverse * $0.position) }

        // grid density from perpendicular widths (1/|a*| etc.), so triclinic cells bucket correctly
        let volume = abs(simd_dot(cell.a, simd_cross(cell.b, cell.c)))
        guard volume > 1e-8 else { return [] }
        let perpWidths = [simd_cross(cell.b, cell.c), simd_cross(cell.c, cell.a), simd_cross(cell.a, cell.b)]
            .map { volume / simd_length($0) }
        let divisions = SIMD3<Int32>(perpWidths.map { Int32(min(max(Int($0 / bucketSize), 1), 1024)) })

        var grid: [Int: [Int]] = [:]
        for (idx, f) in fracs.enumerated() {
            grid[key(bucket(f, divisions), wrap: divisions), default: []].append(idx)
        }

        var result: [BondCandidate] = []
        for (idx, f) in fracs.enumerated() {
            let c = bucket(f, divisions)
            for (neighbor, wrap) in grid.nearbyWrapped(center: c, divisions: divisions,
                                                       keyer: { key($0, wrap: divisions) }) {
                guard atoms[idx].element != "H" || atoms[neighbor].element != "H" else { continue }
                // minimum-image displacement from i to (the image of) j
                let delta = fracs[neighbor] - f
                var d = delta
                if wrap != .zero { d += SIMD3<Double>(wrap) }
                d -= d.rounded(.toNearestOrAwayFromZero)
                let cart = lattice * d
                let d2 = simd_dot(cart, cart)
                if d2 <= cutoff2(atoms[idx], atoms[neighbor], radii) {
                    // image actually reached: n such that fracs[j] + n ≈ fracs[i] + d
                    let diff = d - delta
                    let n = SIMD3<Int32>(Int32(diff.x.rounded()), Int32(diff.y.rounded()), Int32(diff.z.rounded()))
                    result.append(BondCandidate(i: idx, j: neighbor, d2: d2, offset: n))
                }
            }
        }
        return result
    }

    // MARK: - filtering & canonical form

    /// hydrogen keeps only its single shortest bond
    private static func filterHydrogens(_ candidates: [BondCandidate], atoms: [RenderAtom]) -> [BondCandidate] {
        var bestForH: [Int: Int] = [:]
        for (idx, c) in candidates.enumerated() {
            if atoms[c.i].element == "H" {
                if let cur = bestForH[c.i], candidates[cur].d2 <= c.d2 { continue }
                bestForH[c.i] = idx
            }
            if atoms[c.j].element == "H" {
                if let cur = bestForH[c.j], candidates[cur].d2 <= c.d2 { continue }
                bestForH[c.j] = idx
            }
        }
        let keep = Set(bestForH.values)
        return candidates.enumerated().compactMap { offset, c in
            (atoms[c.i].element == "H" || atoms[c.j].element == "H") ? (keep.contains(offset) ? c : nil) : c
        }
    }

    /// one bond per (i, j, n): drop the mirrored (j, i, -n) duplicate
    private static func canonicalize(_ candidates: [BondCandidate]) -> [RenderBond] {
        var seen = Set<UInt64>()
        var result: [RenderBond] = []
        result.reserveCapacity(candidates.count)
        for c in candidates {
            if isCanonical(c) {
                if seen.insert(key(c)).inserted, result.count < maxBonds {
                    result.append(RenderBond(i: c.i, j: c.j, offset: c.offset))
                }
            } else {
                let mirror = BondCandidate(i: c.j, j: c.i, d2: c.d2, offset: -c.offset)
                if seen.insert(key(mirror)).inserted, result.count < maxBonds {
                    result.append(RenderBond(i: mirror.i, j: mirror.j, offset: mirror.offset))
                }
            }
        }
        return result
    }

    @inline(__always)
    private static func isCanonical(_ c: BondCandidate) -> Bool {
        if c.i != c.j { return c.i < c.j }
        // self-image bonds (tiny cells): pick the lexicographically positive offset
        return (c.offset.x, c.offset.y, c.offset.z) > (0, 0, 0)
    }

    @inline(__always)
    private static func key(_ c: BondCandidate) -> UInt64 {
        var h: UInt64 = 0x9E3779B97F4A7C15
        for v in [UInt64(truncatingIfNeeded: c.i), UInt64(truncatingIfNeeded: c.j),
                  UInt64(bitPattern: Int64(c.offset.x)), UInt64(bitPattern: Int64(c.offset.y)),
                  UInt64(bitPattern: Int64(c.offset.z))] {
            h = (h ^ v) &* 0x100000001B3
        }
        return h
    }

    @inline(__always)
    private static func cutoff2(_ a: RenderAtom, _ b: RenderAtom, _ radii: CovalentRadii) -> Double {
        let r = radii[a.element] + radii[b.element] + tolerance
        return r * r
    }

    @inline(__always)
    private static func bucket(_ f: SIMD3<Double>, _ divisions: SIMD3<Int32>) -> SIMD3<Int32> {
        let c = (f * SIMD3<Double>(divisions)).rounded(.down)
        return SIMD3<Int32>(min(max(Int32(c.x), 0), divisions.x - 1),
                            min(max(Int32(c.y), 0), divisions.y - 1),
                            min(max(Int32(c.z), 0), divisions.z - 1))
    }

    @inline(__always)
    private static func key(_ c: SIMD3<Int32>, wrap: SIMD3<Int32>?) -> Int {
        if let wrap {
            let m = SIMD3<Int32>(((c.x % wrap.x) + wrap.x) % wrap.x,
                                 ((c.y % wrap.y) + wrap.y) % wrap.y,
                                 ((c.z % wrap.z) + wrap.z) % wrap.z)
            // divisions ≤ 1024 per axis → non-overlapping packing
            return Int(m.x) &+ (Int(m.y) &<< 10) &+ (Int(m.z) &<< 20)
        }
        // molecular mode: unbounded coordinates → hash
        return Int(c.x) &* 73856093 ^ Int(c.y) &* 19349663 ^ Int(c.z) &* 83492791
    }
}

// MARK: - grid helpers

private extension Dictionary where Key == Int, Value == [Int] {
    /// all atom indices in the 3×3×3 bucket neighborhood (molecular, unwrapped)
    func nearby(center c: SIMD3<Int32>, keyer: (SIMD3<Int32>) -> Int) -> [Int] {
        var out: [Int] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let d = SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))
                    out.append(contentsOf: self[keyer(c &+ d)] ?? [])
                }
            }
        }
        return out
    }

    /// neighborhood with periodic wrapping; yields (atom, bucket delta that crossed
    /// a boundary, or .zero) so callers can build correct minimum-image displacements
    func nearbyWrapped(center c: SIMD3<Int32>, divisions: SIMD3<Int32>,
                       keyer: (SIMD3<Int32>) -> Int) -> [(Int, SIMD3<Int32>)] {
        var out: [(Int, SIMD3<Int32>)] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let delta = SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))
                    let t = c &+ delta
                    let w = SIMD3<Int32>(((t.x % divisions.x) + divisions.x) % divisions.x,
                                         ((t.y % divisions.y) + divisions.y) % divisions.y,
                                         ((t.z % divisions.z) + divisions.z) % divisions.z)
                    let crossed = (t != w) ? delta : SIMD3<Int32>.zero
                    for atom in self[keyer(w)] ?? [] {
                        out.append((atom, crossed))
                    }
                }
            }
        }
        return out
    }
}

// MARK: - element radii

/// Covalent radii (Å) indexed by element symbol, built once from the vendored
/// SKElement table (Cordero-style values; unknown symbols → 0.8 fallback).
public final class CovalentRadii {
    public static let shared = CovalentRadii()
    private let table: [String: Double]
    private init() {
        var t: [String: Double] = [:]
        for element in PredefinedElements.sharedInstance.elementSet where !element.chemicalSymbol.isEmpty {
            t[element.chemicalSymbol] = element.covalentRadius > 0 ? element.covalentRadius : 0.8
        }
        table = t
    }
    public subscript(_ symbol: String) -> Double { table[symbol] ?? 0.8 }
}
