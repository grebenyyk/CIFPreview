import Foundation

/// Streams over the raw bytes and returns only the FIRST `data_` block that
/// carries an atom-site loop. CSD-style query dumps routinely hold hundreds of
/// blocks (one 46.7 MB file has 7844); feeding all of it to SKCIFParser would
/// merge them into garbage, so we truncate to one block before parsing.
public enum BlockSelector {

    /// Returns the bytes of the first data block containing
    /// `_atom_site_fract_x` / `_atom_site_Cartn_x`, or nil when none exists.
    /// Carriage returns are stripped: CRLF is widespread in CCDC downloads and
    /// leaks into quoted values otherwise, confusing the downstream parser.
    public static func firstStructuralBlock(of data: Data, maxScan: Int = 64 << 20) -> Data? {
        let scanEnd = min(data.count, maxScan)

        var blockStart: Data.Index? = nil   // start offset of the open block
        var blockHasAtoms = false

        var lineStart = data.startIndex
        while lineStart < scanEnd {
            // find end of line (tolerate CRLF)
            var lineEnd = lineStart
            while lineEnd < scanEnd, data[lineEnd] != 0x0A { lineEnd = data.index(after: lineEnd) }
            var trimEnd = lineEnd
            if trimEnd > lineStart, data[data.index(before: trimEnd)] == 0x0D {
                trimEnd = data.index(before: trimEnd)
            }
            let line = data[lineStart..<trimEnd]

            if isBlockBoundary(line) {
                if let start = blockStart, blockHasAtoms {
                    return stripCarriageReturns(data[start..<lineStart])
                }
                blockStart = lineStart
                blockHasAtoms = false
            } else if !blockHasAtoms, isAtomSiteTag(line) {
                blockHasAtoms = true
            }

            lineStart = data.index(after: lineEnd)
        }

        if let start = blockStart, blockHasAtoms {
            return stripCarriageReturns(data[start...])
        }
        return nil
    }

    private static func stripCarriageReturns(_ d: Data) -> Data {
        d.contains(0x0D) ? d.filter { $0 != 0x0D } : d
    }

    /// `data_...` lines (case-insensitive) open a block.
    private static func isBlockBoundary(_ line: Data) -> Bool {
        guard line.count > 5 else { return false }
        return lowercasedPrefix(line, count: 5) == "data_"
    }

    private static func isAtomSiteTag(_ line: Data) -> Bool {
        // skip leading whitespace cheaply
        var i = line.startIndex
        while i < line.endIndex, line[i] == 0x20 || line[i] == 0x09 { i = line.index(after: i) }
        let rest = line[i...]
        if rest.count < 18 { return false }
        let head = lowercasedPrefix(rest, count: 18)
        return head.hasPrefix("_atom_site_fract_x") || head.hasPrefix("_atom_site_cartn_x")
    }

    private static func lowercasedPrefix(_ d: Data, count: Int) -> String {
        let n = min(count, d.count)
        var bytes = [UInt8](d.prefix(n))
        for idx in bytes.indices where bytes[idx] >= 65 && bytes[idx] <= 90 {
            bytes[idx] += 32
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
