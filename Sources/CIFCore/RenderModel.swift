import Foundation
import simd
import MathKit

/// Value types shared by the extractor, bond finder and scene builder.
/// Positions are Cartesian Ångström; 1 scene unit = 1 Å.

public struct RenderAtom {
    public var element: String          // clean element symbol, e.g. "Th", "O"
    public var position: SIMD3<Double>  // Cartesian Å
    public init(element: String, position: SIMD3<Double>) {
        self.element = element
        self.position = position
    }
}

public struct RenderBond {
    public var i: Int
    public var j: Int
    /// Periodic image of atom j the bond actually goes to, in lattice vectors.
    /// `.zero` for bonds inside the cell; nonzero for bonds crossing a cell face,
    /// which the scene builder draws as two half-bonds meeting at the boundary.
    public var offset: SIMD3<Int32>
    public init(i: Int, j: Int, offset: SIMD3<Int32> = SIMD3<Int32>(0, 0, 0)) {
        self.i = i
        self.j = j
        self.offset = offset
    }
}

public struct RenderCell {
    public var a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>  // Å
    public init(a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>) {
        self.a = a; self.b = b; self.c = c
    }
    public var columnsAsMatrix: double3x3 { double3x3(columns: (a, b, c)) }
}

public struct RenderModel {
    public var atoms: [RenderAtom] = []
    public var bonds: [RenderBond] = []
    public var cell: RenderCell?
    public var meta: Meta = .init()

    public struct Meta {
        public var mode: Mode = .crystal
        public var spaceGroup: String?
        public var spaceGroupNumber: Int?
        public var hallSymbol: String?
        public var formula: String?
        public var cellParams: [Double] = []   // a,b,c,alpha,beta,gamma (Å,°) when crystal
        public var asymCount = 0
        public var truncated = false
        public var parseWarnings: [String] = []

        public enum Mode: String, Codable { case crystal, cartesian, empty }
    }

    public init() {}
}

public enum ExtractError: Error, CustomStringConvertible {
    case noStructuralBlock
    case parsing(String)
    case noStructure

    public var description: String {
        switch self {
        case .noStructuralBlock: return "no data block with an atom site loop found in file"
        case .parsing(let m):    return "CIF parsing failed: \(m)"
        case .noStructure:       return "file parsed but contains no renderable structure"
        }
    }
}
