// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// One row of a regression baseline: a per-(codec, image, quality) snapshot
/// of byte count and PSNR. Timing is intentionally not in the baseline because
/// it's machine-dependent — regressions on bytes/PSNR are deterministic and
/// catch real correctness/quality changes.
struct BaselineRow: Codable, Hashable {
    let kind: String       // "self" or "cross"
    let codec: String      // for self: codec name; for cross: "encoder→decoder"
    let image: String      // CorpusImage.id
    let quality: Int
    let bytes: Int
    /// JSON encodes infinity as "inf" via a sentinel; we keep it as Double here.
    let psnrDB: Double
}

extension BaselineRow {
    func psnrDBOrSentinel() -> Double {
        psnrDB.isInfinite ? 999.0 : psnrDB
    }
}

struct Baseline: Codable {
    let createdAt: String
    let toolVersion: String
    let rows: [BaselineRow]

    func index() -> [BaselineRow: BaselineRow] {
        var d = [BaselineRow: BaselineRow]()
        for r in rows {
            // Use a key that drops bytes/psnr so we can find the matching row.
            let key = BaselineRow(
                kind: r.kind, codec: r.codec, image: r.image,
                quality: r.quality, bytes: 0, psnrDB: 0
            )
            d[key] = r
        }
        return d
    }
}

enum BaselineError: Error, CustomStringConvertible {
    case readFailed(String)
    case parseFailed(String)
    var description: String {
        switch self {
        case .readFailed(let s): return "baseline read failed: \(s)"
        case .parseFailed(let s): return "baseline parse failed: \(s)"
        }
    }
}

enum BaselineStore {
    static func save(_ baseline: Baseline, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(baseline)
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func load(_ path: String) throws -> Baseline {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw BaselineError.readFailed("\(error)") }
        do { return try JSONDecoder().decode(Baseline.self, from: data) }
        catch { throw BaselineError.parseFailed("\(error)") }
    }
}

/// One diff between a baseline row and the current run.
struct BaselineDiff {
    enum Kind { case missingInCurrent, missingInBaseline, regression, improvement, unchanged }
    let kind: Kind
    let key: BaselineRow         // identifier (kind/codec/image/quality)
    let baselineBytes: Int?
    let currentBytes: Int?
    let baselinePSNR: Double?
    let currentPSNR: Double?
    /// Free-text reason for non-trivial diffs.
    let note: String
}

/// Default tolerances:
/// - bytes: ±2% considered within noise (entropy coding can drift slightly
///   between codec patch revisions even at fixed quality)
/// - PSNR: ±0.05 dB
struct BaselineTolerance {
    let bytesRelative: Double
    let psnrAbsolute: Double
    static let `default` = BaselineTolerance(bytesRelative: 0.02, psnrAbsolute: 0.05)
}

enum BaselineCompare {
    /// Compares a current set of rows against a stored baseline, returning a
    /// list of diffs (regressions, improvements, or missing entries on either
    /// side). Rows within tolerance are reported as `.unchanged` so the summary
    /// can show the full count.
    static func diff(
        baseline: Baseline, current: [BaselineRow],
        tolerance: BaselineTolerance = .default
    ) -> [BaselineDiff] {
        let baseIndex = baseline.index()
        var diffs = [BaselineDiff]()
        var seenBaselineKeys = Set<BaselineRow>()

        for row in current {
            let key = BaselineRow(
                kind: row.kind, codec: row.codec, image: row.image,
                quality: row.quality, bytes: 0, psnrDB: 0
            )
            guard let base = baseIndex[key] else {
                diffs.append(BaselineDiff(
                    kind: .missingInBaseline, key: key,
                    baselineBytes: nil, currentBytes: row.bytes,
                    baselinePSNR: nil, currentPSNR: row.psnrDB,
                    note: "new row not in baseline"
                ))
                continue
            }
            seenBaselineKeys.insert(key)

            let bytesDelta = Double(row.bytes - base.bytes) / Double(max(1, base.bytes))
            let psnrDelta = row.psnrDBOrSentinel() - base.psnrDBOrSentinel()

            let bytesRegressed = bytesDelta > tolerance.bytesRelative
            let psnrRegressed  = psnrDelta < -tolerance.psnrAbsolute
            let bytesImproved  = bytesDelta < -tolerance.bytesRelative
            let psnrImproved   = psnrDelta > tolerance.psnrAbsolute

            let note = String(
                format: "bytes %+.2f%%, PSNR %+.2f dB",
                bytesDelta * 100, psnrDelta
            )

            let kind: BaselineDiff.Kind
            if bytesRegressed || psnrRegressed {
                kind = .regression
            } else if bytesImproved || psnrImproved {
                kind = .improvement
            } else {
                kind = .unchanged
            }
            diffs.append(BaselineDiff(
                kind: kind, key: key,
                baselineBytes: base.bytes, currentBytes: row.bytes,
                baselinePSNR: base.psnrDB, currentPSNR: row.psnrDB,
                note: note
            ))
        }

        // Anything in the baseline we didn't see in the current run.
        for (key, base) in baseIndex where !seenBaselineKeys.contains(key) {
            diffs.append(BaselineDiff(
                kind: .missingInCurrent, key: key,
                baselineBytes: base.bytes, currentBytes: nil,
                baselinePSNR: base.psnrDB, currentPSNR: nil,
                note: "row in baseline missing from current run"
            ))
        }
        return diffs
    }

    /// Prints a compact summary. Returns true if any regression was flagged.
    @discardableResult
    static func printSummary(_ diffs: [BaselineDiff]) -> Bool {
        var regressions = 0, improvements = 0, unchanged = 0
        var missingCurrent = 0, missingBaseline = 0
        for d in diffs {
            switch d.kind {
            case .regression: regressions += 1
            case .improvement: improvements += 1
            case .unchanged: unchanged += 1
            case .missingInCurrent: missingCurrent += 1
            case .missingInBaseline: missingBaseline += 1
            }
        }
        print("")
        print("=== Regression vs baseline ===")
        print("  unchanged:        \(unchanged)")
        print("  improvements:     \(improvements)")
        print("  regressions:      \(regressions)")
        print("  missing-current:  \(missingCurrent)")
        print("  missing-baseline: \(missingBaseline)")
        if regressions > 0 || missingCurrent > 0 {
            print("")
            print("  Flagged rows:")
            for d in diffs where d.kind == .regression || d.kind == .missingInCurrent {
                let label: String
                switch d.kind {
                case .regression:      label = "REGRESS "
                case .missingInCurrent: label = "MISSING "
                default:               label = ""
                }
                print("    \(label) \(d.key.kind) \(d.key.codec) \(d.key.image) q=\(d.key.quality)  \(d.note)")
            }
        }
        // Either a quality/byte regression or a missing case should fail CI.
        return regressions > 0 || missingCurrent > 0
    }
}
