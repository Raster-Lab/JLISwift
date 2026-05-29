// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

/// The outcome of one encode→decode round-trip. Everything here is `Sendable`
/// so it can cross back from a detached compute task to the main actor, which
/// turns the raw buffers into `CGImage`s for display.
struct RoundTripOutput: Sendable {
    var width: Int
    var height: Int
    var encoded: [UInt8]
    /// Decoded image rendered to 8-bit RGB (w·h·3) for display and difference.
    var decodedRGB8: [UInt8]

    var encodedBytes: Int
    var bpp: Double
    var compressionRatio: Double
    var psnr: Double           // dB; .infinity when bit-exact
    var maxAbsError: Int
    var butteraugli: Double?    // lower is better
    var ssimulacra2: Double?    // higher is better (100 = identical)
    var encodeMs: Double
    var decodeMs: Double
    var summary: String
}

enum RoundTripEngine {

    static func run(source: SourceImage, settings: LabSettings) throws -> RoundTripOutput {
        if settings.mode == .gray12, let gray = source.gray12 {
            return try runGray12(width: source.width, height: source.height,
                                  gray: gray, settings: settings)
        }
        return try runRGB8(width: source.width, height: source.height,
                            rgb: source.rgb8, settings: settings)
    }

    // MARK: - 8-bit RGB pipeline

    private static func runRGB8(
        width w: Int, height h: Int, rgb: [UInt8], settings: LabSettings
    ) throws -> RoundTripOutput {
        let input = try JLIImage(width: w, height: h, pixelFormat: .uint8,
                                 colorModel: .rgb, data: rgb)
        let cfg = settings.encoderConfiguration()

        let t0 = Date()
        let encoded = try JLIEncoder().encode(input, configuration: cfg)
        let encodeMs = Date().timeIntervalSince(t0) * 1000

        let t1 = Date()
        let decoded = try JLIDecoder().decode(from: encoded)
        let decodeMs = Date().timeIntervalSince(t1) * 1000

        let decodedRGB8 = decodedToRGB8(decoded, width: w, height: h)
        let psnr = Metrics.psnr8(rgb, decodedRGB8)
        let maxErr = Metrics.maxAbs8(rgb, decodedRGB8)
        let ba = Butteraugli.distance(reference: rgb, distorted: decodedRGB8, width: w, height: h)
        let s2 = Ssimulacra2.score(reference: rgb, distorted: decodedRGB8, width: w, height: h)

        return RoundTripOutput(
            width: w, height: h, encoded: encoded, decodedRGB8: decodedRGB8,
            encodedBytes: encoded.count,
            bpp: Double(encoded.count * 8) / Double(w * h),
            compressionRatio: Double(w * h * 3) / Double(max(1, encoded.count)),
            psnr: psnr, maxAbsError: maxErr, butteraugli: ba, ssimulacra2: s2,
            encodeMs: encodeMs, decodeMs: decodeMs,
            summary: summary(settings: settings, channels: "RGB")
        )
    }

    // MARK: - 12-bit grayscale (medical) pipeline

    private static func runGray12(
        width w: Int, height h: Int, gray: [UInt16], settings: LabSettings
    ) throws -> RoundTripOutput {
        let packed = packLE(gray)
        let input = try JLIImage(width: w, height: h, pixelFormat: .uint16,
                                 colorModel: .grayscale, data: packed)
        let cfg = settings.encoderConfiguration()

        let t0 = Date()
        let encoded = try JLIEncoder().encode(input, configuration: cfg)
        let encodeMs = Date().timeIntervalSince(t0) * 1000

        let t1 = Date()
        let decoded = try JLIDecoder().decode(from: encoded)
        let decodeMs = Date().timeIntervalSince(t1) * 1000

        let decodedSamples = unpackLE(decoded.data, count: w * h)
        let psnr = Metrics.psnr16(gray, decodedSamples, peak: 4095)
        let maxErr = Metrics.maxAbs16(gray, decodedSamples)
        let decodedRGB8 = gray12ToRGB8(decodedSamples, width: w, height: h)

        return RoundTripOutput(
            width: w, height: h, encoded: encoded, decodedRGB8: decodedRGB8,
            encodedBytes: encoded.count,
            bpp: Double(encoded.count * 8) / Double(w * h),
            compressionRatio: Double(w * h * 2) / Double(max(1, encoded.count)),
            psnr: psnr, maxAbsError: maxErr, butteraugli: nil, ssimulacra2: nil,
            encodeMs: encodeMs, decodeMs: decodeMs,
            summary: summary(settings: settings, channels: "12-bit gray")
        )
    }

    // MARK: - Helpers

    /// Renders a decoded image to an 8-bit RGB buffer of exactly w·h·3, handling
    /// 8-bit RGB/grayscale and 16-bit (12-bit-range) grayscale outputs.
    private static func decodedToRGB8(_ img: JLIImage, width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        let pixels = w * h
        switch (img.colorModel, img.pixelFormat) {
        case (.rgb, .uint8), (.rgba, .uint8):
            let cc = img.colorModel.componentCount
            let n = min(pixels, img.data.count / cc)
            for i in 0..<n {
                out[i * 3]     = img.data[i * cc]
                out[i * 3 + 1] = img.data[i * cc + 1]
                out[i * 3 + 2] = img.data[i * cc + 2]
            }
        case (.grayscale, .uint8):
            let n = min(pixels, img.data.count)
            for i in 0..<n { let g = img.data[i]; out[i*3]=g; out[i*3+1]=g; out[i*3+2]=g }
        case (.grayscale, .uint16):
            let s = unpackLE(img.data, count: pixels)
            for i in 0..<min(pixels, s.count) {
                let g = UInt8(min(255, Int(Double(s[i]) * 255.0 / 4095.0 + 0.5)))
                out[i*3]=g; out[i*3+1]=g; out[i*3+2]=g
            }
        default:
            // Best-effort: copy whatever bytes line up as RGB8.
            let n = min(out.count, img.data.count)
            for i in 0..<n { out[i] = img.data[i] }
        }
        return out
    }

    private static func gray12ToRGB8(_ s: [UInt16], width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<min(w * h, s.count) {
            let g = UInt8(min(255, Int(Double(s[i]) * 255.0 / 4095.0 + 0.5)))
            out[i*3]=g; out[i*3+1]=g; out[i*3+2]=g
        }
        return out
    }

    private static func packLE(_ s: [UInt16]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: s.count * 2)
        for i in 0..<s.count { out[i*2] = UInt8(s[i] & 0xFF); out[i*2+1] = UInt8(s[i] >> 8) }
        return out
    }

    private static func unpackLE(_ b: [UInt8], count: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: count)
        let n = min(count, b.count / 2)
        for i in 0..<n { out[i] = UInt16(b[i*2]) | (UInt16(b[i*2+1]) << 8) }
        return out
    }

    private static func summary(settings s: LabSettings, channels: String) -> String {
        if s.lossless {
            var t = "Lossless SOF3 · \(channels) · predictor \(s.losslessPredictor)"
            if s.losslessPointTransform > 0 { t += " · near-lossless Pt=\(s.losslessPointTransform)" }
            return t
        }
        var parts: [String] = []
        parts.append(s.progressive ? "Progressive (\(s.progressiveMode == .successive ? "SA" : "spectral"))" : "Baseline")
        if s.mode == .gray12 {
            parts.append("12-bit gray")
        } else {
            parts.append("\(s.colorSpace == .xyb ? "XYB" : "YCbCr") \(s.subsampling.rawValue)")
        }
        parts.append(s.useDistance ? String(format: "d=%.2f", s.distance) : "q\(Int(s.quality))")
        var flags: [String] = []
        if s.optimiseHuffman { flags.append("opt-Huff") }
        if s.adaptiveQuantization { flags.append("trellis") }
        if s.adaptiveQuantField { flags.append("aq-field") }
        if s.perceptualQuantTables { flags.append("perceptual") }
        if s.restartInterval > 0 { flags.append("RST=\(s.restartInterval)") }
        if !flags.isEmpty { parts.append(flags.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}
