#!/usr/bin/env python3
"""Cross-check CIFQuickLook --stats against independent parsers (pymatgen/ASE).

Modes:
  oracle_check.py [binary]              run the curated regression samples
  oracle_check.py --sweep N [--seed S]  stress-test N stratified-random CIFs
                                        from the local corpus (no committed paths)

The curated sample list lives in tests/regression/samples.local.json
(gitignored — real paths and CSD-licensed data stay private); see
samples.example.json for the schema.
"""
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import warnings

warnings.filterwarnings("ignore")

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(PROJECT, ".build", "release", "CIFQLTool")

# corpus roots swept in --sweep mode (tilde-expanded, never committed)
SWEEP_ROOTS = [
    "~/Yandex.Disk.localized/Working/Compounds",
    "~/Yandex.Disk.localized/Working/Structures",
    "~/Yandex.Disk.localized/Working/PDF/Refinements",
    "~/Documents/GitHub/PDF-MC",
    "~/Downloads",
]

# samples where independent parsers resolve a DIFFERENT result than the
# crystallographic ground truth (documented divergences, not regressions)
KNOWN_DIVERGENCES = {
    # pymatgen resolves the bar-less H-M symbol as P-4mm (#99) and expands to 3
    # sites; the file's own multiplicity column (B=6) confirms #221 → 7 atoms,
    # which is what the extension produces.
    "LaB6 NIST SRM (name-only H-M)",
}


def load_samples():
    path = os.path.join(PROJECT, "tests", "regression", "samples.local.json")
    if not os.path.exists(path):
        path = os.path.join(PROJECT, "tests", "regression", "samples.example.json")
    with open(path) as fh:
        return json.load(fh)


def run_ours(binary: str, path: str, timeout: float = 60) -> dict:
    try:
        r = subprocess.run([binary, "--stats", path], capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": "TIMEOUT"}
    lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
    try:
        return json.loads(lines[-1]) if lines else {"error": f"no output rc={r.returncode}"}
    except json.JSONDecodeError:
        return {"error": f"unparseable output rc={r.returncode}: {r.stdout[:120]}"}


def reference(path: str):
    """(atom count, cell or None) via pymatgen, falling back to ASE."""
    try:
        from pymatgen.io.cif import CifParser
        s = CifParser(path).parse_structures(primitive=False)[0]
        return len(s), list(s.lattice.abc) + list(s.lattice.angles)
    except Exception:
        pass
    try:
        from ase.io import read as ase_read
        a = ase_read(path)
        return len(a), list(a.cell.cellpar())
    except Exception:
        return None, None


def first_block_bytes(path: str) -> bytes:
    """truncate to the first data_ block containing an atom-site loop
    (mirrors the extension's BlockSelector, so multi-block dumps and parser
    quirks can't shift the reference to a different block)"""
    with open(path, "rb") as fh:
        data = fh.read()
    starts = [m.start() for m in re.finditer(rb"(?m)^data_", data)]
    if not starts:
        return data
    bounds = starts + [len(data)]
    for i in range(len(starts)):
        block = data[bounds[i]:bounds[i + 1]]
        if re.search(rb"(?mi)^\s*_atom_site_fract_x", block):
            return block
    return data


def check_one(binary: str, name: str, original: str, check_cell: bool):
    data = first_block_bytes(original)
    with tempfile.NamedTemporaryFile("wb", suffix=".cif", delete=False) as tmp:
        tmp.write(data)
        path = tmp.name
    try:
        ours = run_ours(binary, path)
        n_ref, cell_ref = reference(path)
    finally:
        os.unlink(path)

    notes, ok = [], True
    if ours.get("error"):
        # an error is only correct when the reference parsers find nothing either
        if n_ref is None:
            return True, "both-agree-unparseable"
        ok = False
        notes.append(f"ours-error={ours['error']}")
    elif n_ref is None:
        ok = False
        notes.append("reference-parsers-failed-but-ours-parsed")
    else:
        if ours.get("expandedAtoms") != n_ref:
            ok = False
            notes.append(f"atoms ours={ours.get('expandedAtoms')} ref={n_ref}")
        else:
            notes.append(f"atoms={n_ref}")
        if check_cell and ours["mode"] == "crystal" and cell_ref and len(cell_ref) == 6:
            cell_ours = ours.get("cell") or []
            if len(cell_ours) == 6:
                worst = max(abs(a - b) for a, b in zip(cell_ours, cell_ref))
                if worst > 1e-2:
                    ok = False
                    notes.append(f"cell Δ={worst:.4f}")
    return ok, "; ".join(notes)


def run_regression(binary: str) -> int:
    failures = 0
    for sample in load_samples():
        name, path = sample["name"], os.path.expanduser(sample["path"])
        ok, notes = check_one(binary, name, path, check_cell=True)
        if not ok and name in KNOWN_DIVERGENCES:
            ok, notes = True, notes + " [documented divergence]"
        if not ok:
            failures += 1
        print(f"{'PASS' if ok else 'FAIL'} {name:28s} {notes}")
    return failures


def sweep_candidates(roots):
    """all .cif files under roots, with sizes"""
    out = []
    for root in roots:
        root = os.path.expanduser(root)
        for dirpath, _, filenames in os.walk(root):
            for f in filenames:
                if f.lower().endswith(".cif"):
                    p = os.path.join(dirpath, f)
                    try:
                        out.append((p, os.path.getsize(p)))
                    except OSError:
                        pass
    return out


def stratified_sample(files, n, seed):
    """proportional sampling across file-size quartiles for diversity"""
    if len(files) <= n:
        return files
    files = sorted(files, key=lambda t: t[1])
    q = len(files) // 4
    quartiles = [files[:q], files[q:2 * q], files[2 * q:3 * q], files[3 * q:]]
    rng = random.Random(seed)
    picked = []
    quota = [n // 4] * 4
    for i in range(n - sum(quota)):
        quota[i] += 1
    for group, k in zip(quartiles, quota):
        picked += rng.sample(group, min(k, len(group)))
    return picked


def run_sweep(binary: str, n: int, seed: int) -> int:
    files = sweep_candidates(SWEEP_ROOTS)
    print(f"corpus: {len(files)} cif files; sweeping {n} stratified samples (seed {seed})")
    sample = stratified_sample(files, n, seed)
    failures = 0
    t_ours = 0.0
    for idx, (path, size) in enumerate(sample):
        ok, notes = check_one(binary, os.path.basename(path), path, check_cell=False)
        if not ok:
            failures += 1
        print(f"{'PASS' if ok else 'FAIL'} [{idx + 1:2d}/{len(sample)}] "
              f"{size:>9,d}B  {path.replace(os.path.expanduser('~'), '~')}  {notes}")
    print(f"\n{sweep_summary(sample)}")
    return failures


def sweep_summary(sample):
    sizes = [s for _, s in sample]
    return (f"summary: {len(sample)} files, size range {min(sizes):,}–{max(sizes):,} bytes "
            f"(median {sorted(sizes)[len(sizes) // 2]:,})")


if __name__ == "__main__":
    args = sys.argv[1:]
    binary = BINARY
    if args and not args[0].startswith("-") and os.path.exists(args[0]):
        binary = args[0]
        args = args[1:]
    if args and args[0] == "--sweep":
        n = int(args[1]) if len(args) > 1 else 20
        seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 20261007
        sys.exit(1 if run_sweep(binary, n, seed) else 0)
    sys.exit(1 if run_regression(binary) else 0)
