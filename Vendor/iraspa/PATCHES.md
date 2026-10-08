# Local patches to vendored iRASPA code (upstream commit da74d38d)

1. MathKit/float4.swift: added `import AppKit` — upstream relies on an
   `@_exported import AppKit` from the Xcode project context; SPM needs it explicit.
2. LogViewKit/ replaced entirely with LogQueueStub.swift (SymmetryKit only calls
   LogQueue.shared.warning/error; the upstream module is an AppKit text-view kit).
3. SymmetryKit editor-UI cluster excluded in Package.swift: SKAtomTreeNode.swift (unconditional `import CloudKit`), SKAtomTreeController.swift, SKBondSetController.swift (depend on the former; pure document-UI machinery, unused by CIF parsing).
4. BinaryCodable/BinaryEncoder.swift: added `import Foundation` (same upstream Xcode-context issue as float4.swift).
5. Added `import AppKit` to 13 files using AppKit types (NSColorSpace etc.) without importing it — same upstream Xcode-context issue. List: SymmetryKit/{SKXYZParser,SKGaussianCubeParser,SKVASPLOCPOTParser,SKVASPELFCARParser,SKVASPCHGCARParser,SKVASPPOSCARParser,SKColorSet,SKVASPXDATCARParser,SKColorSets,SKAtomTreeController,SKBondNode,SKAsymmetricAtom}, BinaryCodable/BinaryEncoder.
6. SymmetryKit/SKSeitzIntegerMatrix.swift: `rotation` and `translation` promoted internal→public — CIFCore applies the Seitz operations directly (no public upstream accessor exists).
7. SKCIFSymmetryOperationParser.parseComponent: skip whitespace between tokens — upstream throws invalidFormat on the very common `"x, y, z"` quoting.
8. SKCIFParser.parseLoop: atom loops without `_atom_site_type_symbol` (COD style) now dispatch via `_atom_site_label`-derived element instead of being dropped.
9. SKCIFParser.parseSymmetry: H-M symbol resolution retries with the inversion bar restored on a bare " 3 " (ASCII files write "P m 3 m"; the Hall table stores "P m -3 m"). Exact match is always tried first, so genuine "P 3"-type symbols are unaffected.
