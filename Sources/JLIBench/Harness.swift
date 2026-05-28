// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

enum BenchError: Error, CustomStringConvertible {
    case codecFailed(String)
    var description: String {
        switch self {
        case .codecFailed(let s): return s
        }
    }
}

/// One image to bench against.
struct TestImage {
    let name: String
    let width: Int
    let height: Int
    let rgb: [UInt8]
}

/// Synthetic test corpus. Three patterns that stress different parts of the pipeline:
/// gradient → DC + low-frequency, checker → high-frequency edges, noise → flat-spectrum
/// (worst case for compression and a stress test for entropy coding).
enum TestImages {
    static func make(size: Int) -> [TestImage] {
        return [
            gradient(name: "gradient-\(size)", size: size),
            checkerboard(name: "checker-\(size)", size: size, cell: 8),
            noise(name: "noise-\(size)", size: size),
        ]
    }

    static func gradient(name: String, size: Int) -> TestImage {
        var rgb = [UInt8](repeating: 0, count: size * size * 3)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 3
                rgb[i]     = UInt8(x * 255 / max(1, size - 1))
                rgb[i + 1] = UInt8(y * 255 / max(1, size - 1))
                rgb[i + 2] = UInt8(((x + y) % size) * 255 / max(1, size - 1))
            }
        }
        return TestImage(name: name, width: size, height: size, rgb: rgb)
    }

    static func checkerboard(name: String, size: Int, cell: Int) -> TestImage {
        var rgb = [UInt8](repeating: 0, count: size * size * 3)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 3
                let on = ((x / cell) + (y / cell)) % 2 == 0
                let v: UInt8 = on ? 230 : 25
                rgb[i] = v; rgb[i + 1] = v; rgb[i + 2] = v
            }
        }
        return TestImage(name: name, width: size, height: size, rgb: rgb)
    }

    static func noise(name: String, size: Int) -> TestImage {
        // Deterministic LCG so runs are repeatable.
        var state: UInt32 = 0xCAFEBABE
        func next() -> UInt8 {
            state = state &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        var rgb = [UInt8](repeating: 0, count: size * size * 3)
        for i in 0..<rgb.count { rgb[i] = next() }
        return TestImage(name: name, width: size, height: size, rgb: rgb)
    }
}

/// Single bench result for one (codec, image, quality) triple.
struct Result {
    let codec: String
    let image: String
    let quality: Int
    let encodedBytes: Int
    let encodeMs: Double
    let decodeMs: Double
    /// PSNR in dB between the original RGB and the round-tripped RGB. Higher is better.
    /// `.infinity` means lossless; below ~25 dB is visibly bad.
    let psnrDB: Double
    let bpp: Double
}

enum Harness {

    /// Median-of-N millisecond timing — robust to GC, scheduler hiccups.
    static func timeMs(iterations: Int = 5, _ body: () throws -> Void) rethrows -> Double {
        var samples = [Double]()
        for _ in 0..<iterations {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try body()
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 - t0) / 1_000_000.0)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// PSNR between two RGB byte arrays. Returns `.infinity` for an exact match.
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        precondition(a.count == b.count, "PSNR inputs must be same length")
        var sse: Double = 0
        for i in 0..<a.count {
            let d = Double(a[i]) - Double(b[i])
            sse += d * d
        }
        if sse == 0 { return .infinity }
        let mse = sse / Double(a.count)
        return 10.0 * log10((255.0 * 255.0) / mse)
    }

    static func run(codec: Codec, image: TestImage, quality: Int) throws -> Result {
        // Shell-out codecs are overhead-dominated; one sample is enough.
        let iters = codec.isExternal ? 1 : 5

        var jpegBytes = [UInt8]()
        let encMs = try timeMs(iterations: iters) {
            jpegBytes = try codec.encode(
                rgb: image.rgb, width: image.width, height: image.height, quality: quality
            )
        }

        var decoded: (rgb: [UInt8], width: Int, height: Int) = ([], 0, 0)
        let decMs = try timeMs(iterations: iters) {
            decoded = try codec.decode(jpeg: jpegBytes)
        }

        // ImageIO can return a transposed/cropped image for odd inputs; truncate to compare.
        let cmp = min(image.rgb.count, decoded.rgb.count)
        let psnr = Harness.psnr(Array(image.rgb.prefix(cmp)), Array(decoded.rgb.prefix(cmp)))
        let bpp = Double(jpegBytes.count * 8) / Double(image.width * image.height)

        return Result(
            codec: codec.name, image: image.name, quality: quality,
            encodedBytes: jpegBytes.count, encodeMs: encMs, decodeMs: decMs,
            psnrDB: psnr, bpp: bpp
        )
    }
}

/// One cross-codec compatibility result: encode with codec A, decode with codec B.
struct CrossResult {
    let encoderName: String
    let decoderName: String
    let image: String
    let quality: Int
    let encodedBytes: Int
    /// PSNR against the original source. `nil` if decode failed.
    let psnrDB: Double?
    /// `nil` on success, otherwise a short description of what broke.
    let failure: String?
}

extension Harness {
    /// Encode `image` with `encoder`, decode the resulting bytes with `decoder`,
    /// PSNR against the original. Captures both encode and decode failures so a
    /// broken pair shows up in the results table instead of aborting the run.
    static func runCross(
        encoder: Codec, decoder: Codec, image: TestImage, quality: Int
    ) -> CrossResult {
        let jpeg: [UInt8]
        do {
            jpeg = try encoder.encode(
                rgb: image.rgb, width: image.width, height: image.height, quality: quality
            )
        } catch {
            return CrossResult(
                encoderName: encoder.name, decoderName: decoder.name,
                image: image.name, quality: quality,
                encodedBytes: 0, psnrDB: nil, failure: "encode: \(error)"
            )
        }

        let decoded: (rgb: [UInt8], width: Int, height: Int)
        do {
            decoded = try decoder.decode(jpeg: jpeg)
        } catch {
            return CrossResult(
                encoderName: encoder.name, decoderName: decoder.name,
                image: image.name, quality: quality,
                encodedBytes: jpeg.count, psnrDB: nil, failure: "decode: \(error)"
            )
        }

        let cmp = min(image.rgb.count, decoded.rgb.count)
        let psnr = Harness.psnr(Array(image.rgb.prefix(cmp)), Array(decoded.rgb.prefix(cmp)))
        return CrossResult(
            encoderName: encoder.name, decoderName: decoder.name,
            image: image.name, quality: quality,
            encodedBytes: jpeg.count, psnrDB: psnr, failure: nil
        )
    }
}

func printCrossTable(_ results: [CrossResult]) {
    let header = String(
        format: "%-18s -> %-18s  %-18s  %4s  %10s  %8s  %s",
        ("encoder" as NSString).utf8String!, ("decoder" as NSString).utf8String!,
        ("image" as NSString).utf8String!, ("q" as NSString).utf8String!,
        ("bytes" as NSString).utf8String!, ("PSNR" as NSString).utf8String!,
        ("status" as NSString).utf8String!
    )
    print(header)
    print(String(repeating: "-", count: header.count))
    for r in results {
        let psnrStr: String
        if let p = r.psnrDB {
            psnrStr = p.isInfinite ? "    ∞  " : String(format: "%7.2f ", p)
        } else {
            psnrStr = "    --  "
        }
        let status = r.failure ?? "ok"
        print(String(
            format: "%-18s -> %-18s  %-18s  %4d  %10d  %s  %s",
            (r.encoderName as NSString).utf8String!,
            (r.decoderName as NSString).utf8String!,
            (r.image as NSString).utf8String!,
            r.quality, r.encodedBytes,
            (psnrStr as NSString).utf8String!,
            (status as NSString).utf8String!
        ))
    }
}

func printTable(_ results: [Result]) {
    let header = String(
        format: "%-10s  %-18s  %4s  %10s  %7s  %9s  %9s  %7s",
        ("codec" as NSString).utf8String!,
        ("image" as NSString).utf8String!,
        ("q" as NSString).utf8String!,
        ("bytes" as NSString).utf8String!,
        ("bpp" as NSString).utf8String!,
        ("enc ms" as NSString).utf8String!,
        ("dec ms" as NSString).utf8String!,
        ("PSNR" as NSString).utf8String!
    )
    print(header)
    print(String(repeating: "-", count: header.count))
    for r in results {
        let psnrStr = r.psnrDB.isInfinite ? "  ∞ " : String(format: "%6.2f", r.psnrDB)
        print(String(
            format: "%-10s  %-18s  %4d  %10d  %7.3f  %9.3f  %9.3f  %7s",
            (r.codec as NSString).utf8String!,
            (r.image as NSString).utf8String!,
            r.quality, r.encodedBytes, r.bpp,
            r.encodeMs, r.decodeMs,
            (psnrStr as NSString).utf8String!
        ))
    }
}
