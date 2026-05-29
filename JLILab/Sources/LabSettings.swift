// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

/// Which pixel pipeline the round-trip runs through.
enum LabMode: String, CaseIterable, Identifiable, Sendable {
    case rgb8 = "8-bit RGB"
    case gray12 = "12-bit grayscale"
    var id: String { rawValue }
}

enum LabSubsampling: String, CaseIterable, Identifiable, Sendable {
    case s444 = "4:4:4 (none)"
    case s422 = "4:2:2"
    case s420 = "4:2:0"
    var id: String { rawValue }
    var jli: JLIChromaSubsampling {
        switch self {
        case .s444: return .yuv444
        case .s422: return .yuv422
        case .s420: return .yuv420
        }
    }
}

enum LabColorSpace: String, CaseIterable, Identifiable, Sendable {
    case yCbCr = "YCbCr"
    case xyb = "XYB (experimental)"
    var id: String { rawValue }
    var jli: JLIEncodingColorSpace { self == .xyb ? .xyb : .yCbCr }
}

enum LabProgressiveMode: String, CaseIterable, Identifiable, Sendable {
    case spectral = "Spectral selection"
    case successive = "Successive approximation"
    var id: String { rawValue }
    var jli: JLIProgressiveMode { self == .successive ? .successiveApproximation : .spectralSelection }
}

/// All knobs that, when changed, require re-encoding. Kept `Equatable` so the UI
/// can auto-run the round-trip whenever any of them changes.
struct LabSettings: Equatable, Sendable {
    var mode: LabMode = .rgb8

    // Lossy vs lossless (SOF3).
    var lossless: Bool = false

    // Lossy DCT controls.
    var useDistance: Bool = false
    var quality: Double = 90
    var distance: Double = 1.0
    var subsampling: LabSubsampling = .s420
    var colorSpace: LabColorSpace = .yCbCr
    var progressive: Bool = false
    var progressiveMode: LabProgressiveMode = .spectral
    var optimiseHuffman: Bool = true
    var adaptiveQuantization: Bool = true
    var adaptiveQuantField: Bool = false
    var perceptualQuantTables: Bool = false
    var restartInterval: Int = 0

    // Lossless controls.
    var losslessPredictor: Int = 1
    var losslessPointTransform: Int = 0

    /// Builds the encoder configuration this set of knobs describes, for the
    /// given pipeline mode. Grayscale (12-bit) mode forces single-channel output.
    func encoderConfiguration() -> JLIEncoderConfiguration {
        var cfg = JLIEncoderConfiguration.default
        cfg.lossless = lossless
        cfg.optimiseHuffman = optimiseHuffman

        if lossless {
            cfg.losslessPredictor = losslessPredictor
            cfg.losslessPointTransform = losslessPointTransform
            cfg.losslessPrecision = 0   // derive from pixel format (8 for uint8, 12 for uint16)
            return cfg
        }

        cfg.distance = useDistance ? distance : nil
        cfg.quality = quality
        cfg.chromaSubsampling = (mode == .gray12) ? .yuv400 : subsampling.jli
        cfg.colorSpace = (mode == .gray12) ? .yCbCr : colorSpace.jli
        cfg.progressive = progressive
        cfg.progressiveMode = progressiveMode.jli
        cfg.restartInterval = restartInterval
        cfg.adaptiveQuantization = adaptiveQuantization
        cfg.adaptiveQuantField = adaptiveQuantField
        cfg.perceptualQuantTables = perceptualQuantTables
        return cfg
    }
}
