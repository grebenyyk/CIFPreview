# cif-ql — Quick Look previews for crystallographic `.cif` files

A native macOS Quick Look preview extension that renders crystal structures
from CIF (Crystallographic Information Format) files on space-bar press in
Finder — a clean, light ball-and-stick view with unit cell, CPK colors and
distance-based bonds.

Built for crystallographers who want a fast structure glance without opening
Mercury/VESTA (neither of which ship Quick Look extensions), and without the
heavy/dark iRASPA preview.

```
Finder space-bar
  → QuickLook daemon
    → CIFPreviewQuickLook.appex
      → block selector (first data_ block with an atom loop)
      → SKCIFParser (vendored from iRASPA, MIT)
      → symmetry expansion (Seitz ops from file, else 230-group Hall table)
      → bond finding (covalent radii grid hash, periodic boundary)
      → SceneKit render → sRGB PNG → QLPreviewReply
```

## Features

- **Light, fast, styled**: white→gray gradient background, CPK colors, gray
  bonds, thin cell outline, 4×MSAA, 1600×1200 @2x snapshot
- **Corpus-hardened parser**, tested against a 490-file research corpus:
  - both `_symmetry_equiv_pos_as_xyz` and `_space_group_symop_operation_xyz`
  - space-group resolution from H-M/Hall/IT number when no symop loop exists
    (including bar-less ASCII symbols like `P m 3 m`)
  - Cartesian coordinates disguised under `_atom_site_fract_x` with a dummy
    ~1 Å cell (a common output of in-house CIF-writing scripts)
  - parenthesized uncertainties (`0.12416(18)`), CRLF, quoted values,
    semicolon text fields, junk columns (GSAS-II `_sm_*`), label-derived
    elements (`O11'` → O), multi-block CSD dumps (renders the first
    structural block; 46 MB / 7844-block files parse in ~0.2 s)
- **Correct periodic bonds**: minimum-image distances, bonds crossing cell
  faces drawn as half-bonds to rendered image atoms — no dangling stubs
- **Graceful degradation**: parse failure shows a one-line reason, never a
  blank pane; >15 000-atom structures render a capped subset

## Build & install

Requirements: macOS 12+, Xcode (for `xcodebuild`), [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./build.sh install     # builds, signs (ad-hoc), installs to ~/Applications
```

Then press space on any `.cif` in Finder.

`./build.sh` alone builds into `./build/CIFPreview.app` without installing.

## Layout

```
Package.swift            Swift package: CIFCore (ours) + vendored iRASPA targets
Sources/CIFCore/         BlockSelector, StructureExtractor, BondFinder,
                         SceneBuilder, Snapshot (pure logic + SceneKit)
Sources/CIFQuickLook/    PreviewProvider (QLPreviewProvider principal class)
Sources/CIFQLTool/       CLI: --stats (JSON), --render out.png, --probe
Sources/CIFPreviewHost/  minimal host app (launches once, lives in background)
Vendor/iraspa/           iRASPA-COCOA components (MIT) + PATCHES.md
Resources/               Info.plists + appex entitlements
scripts/oracle_check.py  cross-checks the parser against pymatgen/ASE
project.yml              xcodegen project spec (app + appex targets)
```

## Testing

```bash
swift build -c release
./scripts/oracle_check.py .build/release/CIFQLTool              # curated samples
./scripts/oracle_check.py .build/release/CIFQLTool --sweep 20   # corpus sweep
```

The curated sample list lives in `tests/regression/samples.local.json`
(gitignored — real paths and CSD-licensed structures stay private); see
`samples.example.json` for the schema. The oracle compares cell parameters,
expanded atom counts and space groups against pymatgen (falling back to ASE),
always truncating multi-block files to the same block the extension selects.

## Uninstall

```bash
./scripts/uninstall.sh
```

## Credits

- [iRASPA](https://github.com/iRASPA/iRASPA-COCOA) (MIT) — CIF/symmetry
  parsing core (`SymmetryKit`, `MathKit`, `BinaryCodable`), the 230-space-group
  Hall table and element data. Local modifications listed in
  `Vendor/iraspa/PATCHES.md`.
- [pymatgen](https://pymatgen.org) / [ASE](https://wiki.fysik.dtu.dk/ase/) —
  dev-time test oracles.
