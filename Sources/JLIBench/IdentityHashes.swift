// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import CryptoKit
import Foundation
import JLISwift

// MARK: - Identity-hash harness (byte/bit-identity gate for perf work)

/// Deterministic 16-bit grayscale plane: a smooth ramp plus small seeded noise —
/// shaped like clinical data (smooth anatomy + acquisition noise) rather than
/// pure synthetic extremes. `bits` caps the sample range.
private func graySamples(size: Int, bits: Int, seed: UInt32, noiseAmp: Int) -> [UInt16] {
    let maxV = (1 << bits) - 1
    var state = seed
    var out = [UInt16](repeating: 0, count: size * size)
    for y in 0..<size {
        for x in 0..<size {
            state = state &* 1664525 &+ 1013904223
            let ramp = (x + y) * maxV / max(1, 2 * (size - 1))
            let noise = noiseAmp > 0 ? Int(state >> 24) % (2 * noiseAmp + 1) - noiseAmp : 0
            out[y * size + x] = UInt16(min(max(ramp + noise, 0), maxV))
        }
    }
    return out
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func sha(_ bytes: [UInt8]) -> String { hex(SHA256.hash(data: Data(bytes))) }

/// Encodes + decodes a fixed deterministic matrix of (image × configuration)
/// and prints a SHA-256 of every encoded stream and every decoded pixel buffer.
/// This is the universal byte/bit-identity gate for performance work: run it
/// before a change, run it after, `diff` the output. Any line that moves is a
/// behavior change — either a bug or something that must be explicitly opt-in.
func runIdentityHashes(out: String?) {
    var lines = [String]()
    func record(_ name: String, _ jpeg: [UInt8], decodeWith dcfg: JLIDecoderConfiguration = .default) {
        do {
            let dec = try JLIDecoder().decode(from: jpeg, configuration: dcfg)
            lines.append("\(name) enc=\(sha(jpeg)) bytes=\(jpeg.count) "
                + "dec=\(sha(dec.data)) \(dec.width)x\(dec.height) \(dec.pixelFormat)")
        } catch {
            lines.append("\(name) enc=\(sha(jpeg)) bytes=\(jpeg.count) dec=ERROR:\(error)")
        }
    }
    func encode(_ image: JLIImage, _ cfg: JLIEncoderConfiguration) -> [UInt8]? {
        try? JLIEncoder().encode(image, configuration: cfg)
    }

    // -- 8-bit RGB images × lossy/lossless configs --------------------------
    func cfg(_ mutate: (inout JLIEncoderConfiguration) -> Void) -> JLIEncoderConfiguration {
        var c = JLIEncoderConfiguration.default
        mutate(&c)
        return c
    }
    let rgbConfigs: [(String, JLIEncoderConfiguration)] = [
        ("default-420", .default),
        ("perc-444", cfg { $0.chromaSubsampling = .yuv444 }),
        ("annexK-420", cfg { $0.perceptualQuantTables = false }),
        ("prog-spec-444", cfg { $0.progressive = true; $0.chromaSubsampling = .yuv444 }),
        ("prog-SA-444", cfg { $0.progressive = true; $0.chromaSubsampling = .yuv444
                              $0.progressiveMode = .successiveApproximation }),
        ("rst4-444", cfg { $0.restartInterval = 4; $0.chromaSubsampling = .yuv444 }),
        ("jpegliAQ-444", cfg { $0.jpegliAdaptiveQuant = true; $0.chromaSubsampling = .yuv444 }),
        ("aqField-444", cfg { $0.adaptiveQuantField = true; $0.chromaSubsampling = .yuv444 }),
        ("xyb", cfg { $0.colorSpace = .xyb }),
        ("lossless-rgb8", cfg { $0.lossless = true }),
        ("nearloss-pt2-rgb8", cfg { $0.lossless = true; $0.losslessPointTransform = 2 }),
        ("lossless-p4-rgb8", cfg { $0.lossless = true; $0.losslessPredictor = 4 }),
        ("lossless-p7-rgb8", cfg { $0.lossless = true; $0.losslessPredictor = 7 }),
    ]
    // 256² plus a deliberately odd 67×61 (partial MCUs in both axes — the
    // edge-block extract/scatter paths) run the full config matrix.
    var rgbImages = TestImages.make(size: 256)
    let odd = TestImages.gradient(name: "gradient-67x61", size: 67)
    rgbImages.append(TestImage(name: "gradient-67x61", width: 67, height: 61,
                               rgb: Array(odd.rgb.prefix(67 * 61 * 3))))
    for ti in rgbImages {
        guard let image = try? JLIImage(width: ti.width, height: ti.height,
                                        pixelFormat: .uint8, colorModel: .rgb, data: ti.rgb)
        else { continue }
        for (cname, c) in rgbConfigs {
            if let jpeg = encode(image, c) { record("\(ti.name)/\(cname)", jpeg) }
        }
    }

    // -- Scaled + float32 decode of a fixed stream --------------------------
    let gradient = TestImages.gradient(name: "gradient-256", size: 256)
    if let image = try? JLIImage(width: 256, height: 256, pixelFormat: .uint8,
                                 colorModel: .rgb, data: gradient.rgb),
       let jpeg = encode(image, .default) {
        for s in [2, 4, 8] {
            record("gradient-256/default-420/scale\(s)", jpeg,
                   decodeWith: JLIDecoderConfiguration(scale: s))
        }
    }

    // -- 8-bit grayscale ------------------------------------------------------
    let gray8 = graySamples(size: 256, bits: 8, seed: 0xDECAF, noiseAmp: 6).map { UInt8($0) }
    if let image = try? JLIImage(width: 256, height: 256, pixelFormat: .uint8,
                                 colorModel: .grayscale, data: gray8) {
        for (cname, c) in [("default-gray", JLIEncoderConfiguration.default),
                           ("lossless-gray8", cfg { $0.lossless = true })] {
            if let jpeg = encode(image, c) { record("gray8-256/\(cname)", jpeg) }
        }
    }

    // -- 12/16-bit grayscale (the clinical path) -----------------------------
    let cases: [(String, Int, Int, Bool, JLIEncoderConfiguration)] = [
        ("gray12/sof1-lossy", 12, 4, false, .default),
        ("gray12/lossless", 12, 4, false, cfg { $0.lossless = true; $0.losslessPrecision = 12 }),
        ("gray16/lossless", 16, 40, false, cfg { $0.lossless = true; $0.losslessPrecision = 16 }),
        ("gray16/lossless-signed", 16, 40, true, cfg { $0.lossless = true; $0.losslessPrecision = 16 }),
        ("gray16/nearloss-pt3", 16, 40, false,
         cfg { $0.lossless = true; $0.losslessPrecision = 16; $0.losslessPointTransform = 3 }),
        ("gray16/lossless-p6", 16, 40, false,
         cfg { $0.lossless = true; $0.losslessPrecision = 16; $0.losslessPredictor = 6 }),
    ]
    // 256² sits exactly AT the lossless parallel gate (runs serial); 512²
    // crosses it, so the clinical configs also exercise the parallel residual
    // sweep and the parallel emit stitch in this report.
    for size in [256, 512] {
        for (name, bits, amp, signed, c) in cases {
            let samples = graySamples(size: size, bits: bits, seed: 0xC11AB5, noiseAmp: amp)
            var bytes = [UInt8](repeating: 0, count: samples.count * 2)
            for (i, s) in samples.enumerated() {
                bytes[i * 2] = UInt8(s & 0xFF); bytes[i * 2 + 1] = UInt8(s >> 8)
            }
            guard let image = try? JLIImage(width: size, height: size, pixelFormat: .uint16,
                                            colorModel: .grayscale, data: bytes, isSigned: signed)
            else { continue }
            if let jpeg = encode(image, c) {
                record("\(name)@\(size)", jpeg)
                if name == "gray12/sof1-lossy" && size == 256 {
                    record("gray12/sof1-lossy/float32", jpeg,
                           decodeWith: JLIDecoderConfiguration(outputPixelFormat: .float32))
                }
            }
        }
    }

    // -- 12-bit color ---------------------------------------------------------
    if let c12 = TestImages.color12(size: 64).first {
        var bytes = [UInt8](repeating: 0, count: c12.rgb.count * 2)
        for (i, s) in c12.rgb.enumerated() {
            bytes[i * 2] = UInt8(s & 0xFF); bytes[i * 2 + 1] = UInt8(s >> 8)
        }
        if let image = try? JLIImage(width: c12.width, height: c12.height,
                                     pixelFormat: .uint16, colorModel: .rgb, data: bytes),
           let jpeg = encode(image, .default) {
            record("color12-grad-64/sof1-lossy", jpeg)
        }
    }

    let body = lines.joined(separator: "\n")
    let aggregate = hex(SHA256.hash(data: Data(body.utf8)))
    let text = body + "\nAGGREGATE \(aggregate)\n"
    if let out = out {
        try? text.write(toFile: out, atomically: true, encoding: .utf8)
        print("identity-hashes: \(lines.count) entries → \(out)")
        print("AGGREGATE \(aggregate)")
    } else {
        print(text, terminator: "")
    }
}

// MARK: - Lossless (clinical-path) stage profiler

/// Tight lossless encode/decode loops at native clinical precision (run
/// `sample <pid>` during the sustain phases to attribute stage costs). This is
/// the path `--profile-encode/decode` never measured: SOF3 predictive coding,
/// grayscale, 8/12/16-bit.
func runProfileLossless(bits: Int, size: Int) {
    var cfg = JLIEncoderConfiguration(lossless: true)
    cfg.losslessPrecision = bits

    func makeImage(noiseAmp: Int, name: String) -> (JLIImage, String)? {
        let samples = graySamples(size: size, bits: bits, seed: 0xBEEF, noiseAmp: noiseAmp)
        if bits <= 8 {
            let b = samples.map { UInt8($0) }
            return (try? JLIImage(width: size, height: size, pixelFormat: .uint8,
                                  colorModel: .grayscale, data: b)).map { ($0, name) }
        }
        var b = [UInt8](repeating: 0, count: samples.count * 2)
        for (i, s) in samples.enumerated() {
            b[i * 2] = UInt8(s & 0xFF); b[i * 2 + 1] = UInt8(s >> 8)
        }
        return (try? JLIImage(width: size, height: size, pixelFormat: .uint16,
                              colorModel: .grayscale, data: b)).map { ($0, name) }
    }

    let amp = max(2, (1 << bits) / 256)   // noise scaled to precision (~CT-like)
    guard let (smooth, _) = makeImage(noiseAmp: amp, name: "smooth"),
          let (noisy, _) = makeImage(noiseAmp: (1 << bits) / 4, name: "noisy") else {
        print("profile-lossless: image construction failed"); return
    }
    print("PID \(ProcessInfo.processInfo.processIdentifier) — profiling \(size)×\(size) "
        + "\(bits)-bit grayscale LOSSLESS (SOF3)")

    func time(_ label: String, warm: Int = 2, seconds: Double, _ body: () -> Void) -> Double {
        for _ in 0..<warm { body() }
        var n = 0
        let t0 = Date(); let deadline = t0.addingTimeInterval(seconds)
        while Date() < deadline { body(); n += 1 }
        let ms = Date().timeIntervalSince(t0) * 1000 / Double(max(1, n))
        print(String(format: "  %-22@ %7.2f ms (%d runs)", label as NSString, ms, n))
        return ms
    }

    for (image, name) in [(smooth, "smooth"), (noisy, "noisy")] {
        let jpeg = try! JLIEncoder().encode(image, configuration: cfg)
        let bpp = Double(jpeg.count * 8) / Double(size * size)
        print("  \(name): \(jpeg.count) bytes (\(String(format: "%.2f", bpp)) bpp)")
        _ = time("\(name) encode", seconds: 2.0) { _ = try! JLIEncoder().encode(image, configuration: cfg) }
        _ = time("\(name) decode", seconds: 2.0) { _ = try! JLIDecoder().decode(from: jpeg) }
    }

    let jpeg = try! JLIEncoder().encode(smooth, configuration: cfg)
    print("sustaining smooth ENCODE ~8s — run: sample \(ProcessInfo.processInfo.processIdentifier) 5")
    var deadline = Date().addingTimeInterval(8)
    while Date() < deadline { _ = try! JLIEncoder().encode(smooth, configuration: cfg) }
    print("sustaining smooth DECODE ~8s — run: sample \(ProcessInfo.processInfo.processIdentifier) 5")
    deadline = Date().addingTimeInterval(8)
    while Date() < deadline { _ = try! JLIDecoder().decode(from: jpeg) }
}
