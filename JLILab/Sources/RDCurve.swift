// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

/// Which quality axis to plot. Butteraugli is "lower better"; SSIMULACRA2 and
/// PSNR are "higher better".
enum RDMetric: String, CaseIterable, Identifiable, Sendable {
    case butteraugli = "Butteraugli ↓"
    case ssimulacra2 = "SSIMULACRA2 ↑"
    case psnr = "PSNR dB ↑"
    var id: String { rawValue }
}

struct RDPoint: Sendable, Identifiable {
    var id: String { "\(codec)#\(quality)" }
    let codec: String
    let quality: Int
    let bpp: Double
    let psnr: Double
    let butteraugli: Double?
    let ssimulacra2: Double?

    func value(_ m: RDMetric) -> Double? {
        switch m {
        case .butteraugli: return butteraugli
        case .ssimulacra2: return ssimulacra2
        case .psnr: return psnr.isFinite ? psnr : nil
        }
    }
}

struct RDReport: Sendable {
    let width: Int
    let height: Int
    let qualities: [Int]
    let points: [RDPoint]
    let codecs: [String]
}

/// Sweeps quality across all available codecs and records (bpp, quality-metric)
/// points so a rate–distortion curve can be drawn — the only way to compare
/// codecs at a *matched bit-rate* rather than at one arbitrary quality.
enum RDCurveRunner {
    static let qualities = [40, 55, 70, 80, 88, 95]

    static func run(rgb8: [UInt8], width: Int, height: Int,
                    jliConfig: JLIEncoderConfiguration) -> RDReport {
        var points: [RDPoint] = []
        var names: [String] = []
        for c in LabCodecs.all(jliConfig: jliConfig) where c.available {
            names.append(c.name)
            for q in qualities {
                guard let jpeg = try? c.encode(rgb: rgb8, width: width, height: height, quality: q),
                      let dec = try? c.decode(jpeg),
                      dec.width == width, dec.height == height else { continue }
                let cmp = min(rgb8.count, dec.rgb.count)
                let psnr = Metrics.psnr8(Array(rgb8.prefix(cmp)), Array(dec.rgb.prefix(cmp)))
                let bpp = Double(jpeg.count * 8) / Double(width * height)
                let ba = Butteraugli.distance(reference: rgb8, distorted: dec.rgb, width: width, height: height)
                let s2 = Ssimulacra2.score(reference: rgb8, distorted: dec.rgb, width: width, height: height)
                points.append(RDPoint(codec: c.name, quality: q, bpp: bpp,
                                      psnr: psnr, butteraugli: ba, ssimulacra2: s2))
            }
        }
        return RDReport(width: width, height: height, qualities: qualities,
                        points: points, codecs: names)
    }
}
