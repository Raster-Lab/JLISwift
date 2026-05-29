// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

// MARK: - WS4 RD-matrix (quality-per-byte: which JLISwift config should be default?)

/// Encodes a config matrix × quality sweep on the DICOM corpus + a synthetic
/// anchor and reports butteraugli (lower better) vs bytes, so the 0.2.0
/// defaults decision (perceptual / adaptive-field / subsampling) is data-driven.
func runRDMatrix(root: String) {
    var images: [(name: String, rgb: [UInt8], w: Int, h: Int)] = [
        ("gradient-512", TestImages.gradient(name: "g", size: 512).rgb, 512, 512)
    ]
    for c in DICOMCorpus.load(rootDir: root, perModality: 1)
    where c.width * c.height <= 1_200_000 {   // skip huge plates to bound runtime
        images.append((c.id, c.rgb, c.width, c.height))
    }

    func make(_ perceptual: Bool, _ aqf: Bool, _ sub: JLIChromaSubsampling, _ q: Int) -> JLIEncoderConfiguration {
        var c = JLIEncoderConfiguration.default
        c.quality = Double(q); c.chromaSubsampling = sub
        c.perceptualQuantTables = perceptual; c.adaptiveQuantField = aqf
        return c
    }
    let configs: [(String, (Int) -> JLIEncoderConfiguration)] = [
        ("annexK-420   ", { make(false, false, .yuv420, $0) }),
        ("perceptual-420", { make(true,  false, .yuv420, $0) }),
        ("annexK-444   ", { make(false, false, .yuv444, $0) }),
        ("perceptual-444", { make(true,  false, .yuv444, $0) }),
        ("percept+aqf-444", { make(true,  true,  .yuv444, $0) }),
    ]
    let refs: [(String, CLICodec)] = [("jpegli       ", ReferenceCodecs.jpegli()),
                                      ("mozjpeg      ", ReferenceCodecs.mozjpeg())]
    let qualities = [60, 78, 90]

    print("\n=== WS4 RD matrix (butteraugli ↓ vs bytes) — \(images.count) images ===")
    guard Butteraugli.isAvailable else { print("butteraugli_main not found — cannot run"); return }
    for img in images {
        print("\n# \(img.name)  \(img.w)×\(img.h)")
        print(String(format: "  %-16@ %4@ %9@ %7@ %9@", "config" as NSString, "q" as NSString,
                     "bytes" as NSString, "bpp" as NSString, "b-augli" as NSString))
        func row(_ name: String, _ q: Int, _ bytes: Int, _ dec: [UInt8]) {
            let ba = Butteraugli.distance(reference: img.rgb, distorted: dec, width: img.w, height: img.h) ?? -1
            let bpp = Double(bytes * 8) / Double(img.w * img.h)
            print(String(format: "  %-16@ %4d %9d %7.3f %9.4f", name as NSString, q, bytes, bpp, ba))
        }
        for (cname, cmake) in configs {
            for q in qualities {
                guard let image = try? JLIImage(width: img.w, height: img.h, pixelFormat: .uint8, colorModel: .rgb, data: img.rgb),
                      let jpeg = try? JLIEncoder().encode(image, configuration: cmake(q)),
                      let d = try? JLIDecoder().decode(from: jpeg) else { continue }
                row(cname, q, jpeg.count, d.data)
            }
        }
        for (rname, codec) in refs where codec.enabled {
            for q in qualities {
                guard let jpeg = try? codec.encode(rgb: img.rgb, width: img.w, height: img.h, quality: q),
                      let dec = try? codec.decode(jpeg: jpeg) else { continue }
                row(rname, q, jpeg.count, dec.rgb)
            }
        }
    }
}

/// Tight encode loop for profiling (run `sample <pid>` while it spins). Prints
/// per-encode ms for gradient/checker/noise, then sustains the checkerboard loop.
func runProfileEncode(size: Int) {
    let imgs = TestImages.make(size: size)
    let cfg = JLIEncoderConfiguration.default
    func loop(_ ti: TestImage, seconds: Double) -> (Int, Double) {
        let image = try! JLIImage(width: ti.width, height: ti.height,
                                  pixelFormat: .uint8, colorModel: .rgb, data: ti.rgb)
        for _ in 0..<3 { _ = try! JLIEncoder().encode(image, configuration: cfg) }  // warm
        var n = 0; let t0 = Date(); let deadline = t0.addingTimeInterval(seconds)
        while Date() < deadline { _ = try! JLIEncoder().encode(image, configuration: cfg); n += 1 }
        return (n, Date().timeIntervalSince(t0) * 1000 / Double(max(1, n)))
    }
    print("PID \(ProcessInfo.processInfo.processIdentifier) — profiling \(size)×\(size) encode (.default)")
    for ti in imgs {
        let (n, ms) = loop(ti, seconds: 2.0)
        print(String(format: "  %-14@ %6.2f ms/encode (%d runs)", ti.name as NSString, ms, n))
    }
    let checker = imgs.first { $0.name.contains("checker") } ?? imgs[0]
    print("sustaining \(checker.name) loop ~10s — run: sample \(ProcessInfo.processInfo.processIdentifier) 5")
    _ = loop(checker, seconds: 10.0)
}

// MARK: - CLI

struct BenchOptions {
    enum Mode { case syntheticOnly, dicomOnly, both }
    enum Regression { case none, save(String), check(String) }

    var mode: Mode = .syntheticOnly
    var dicomRoot: String = "Sources/LocalDatasets/medical-dicom-organized"
    var perModality: Int = 3
    var dicomQualities: [Int] = [50, 90]
    var rebuildCache: Bool = false
    var regression: Regression = .none
    var maxPixels: Int = 4_000_000  // skip huge plates (e.g. 5k×5k DX) to keep runtime bounded
    /// Run the 12-bit grayscale DICOM bench (native clinical precision).
    var dicom12: Bool = false
    /// Compute butteraugli perceptual distance for self-codec rows (slow:
    /// shell-out per row). Needs libjxl's `butteraugli_main`.
    var butteraugli: Bool = false
}

func parseArgs(_ argv: [String]) -> BenchOptions {
    var opts = BenchOptions()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--dicom":             opts.mode = .both
        case "--dicom-only":        opts.mode = .dicomOnly
        case "--dicom12":           opts.dicom12 = true
        case "--butteraugli":       opts.butteraugli = true
        case "--rebuild-cache":     opts.rebuildCache = true
        case "--dicom-root":
            i += 1; opts.dicomRoot = argv[i]
        case "--per-modality":
            i += 1; opts.perModality = Int(argv[i]) ?? opts.perModality
        case "--max-pixels":
            i += 1; opts.maxPixels = Int(argv[i]) ?? opts.maxPixels
        case "--save-baseline":
            i += 1; opts.regression = .save(argv[i])
        case "--check-baseline":
            i += 1; opts.regression = .check(argv[i])
        case "--help", "-h":
            printHelp(); exit(0)
        default:
            FileHandle.standardError.write(Data("unknown flag: \(a)\n".utf8))
            printHelp(); exit(2)
        }
        i += 1
    }
    return opts
}

func printHelp() {
    print("""
    JLIBench — JPEG codec benchmark and regression harness

    Usage:
      JLIBench [flags]

    Mode flags:
      --dicom                Also run the DICOM corpus bench (default: synthetic only)
      --dicom-only           Skip synthetic; run only the DICOM corpus
      --dicom-root <path>    DICOM corpus root (default: Sources/LocalDatasets/medical-dicom-organized)
      --per-modality <N>     DICOM images per modality (default: 3)
      --max-pixels <N>       Skip DICOMs above this pixel count (default: 4000000)
      --dicom12              Run the 12-bit grayscale DICOM bench (native precision)
      --butteraugli          Add butteraugli perceptual distance to self-codec rows (slow)
      --rebuild-cache        Clear ~/.cache/jlibench/corpus before running

    Regression flags:
      --save-baseline <path>   Save run results as baseline JSON
      --check-baseline <path>  Load baseline JSON, compare, exit 1 on regression
    """)
}

if let i = CommandLine.arguments.firstIndex(of: "--profile-encode") {
    let size = (i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) : nil) ?? 1024
    runProfileEncode(size: size); exit(0)
}
if CommandLine.arguments.contains("--rd-matrix") {
    var root = "Sources/LocalDatasets/medical-dicom-organized"
    if let i = CommandLine.arguments.firstIndex(of: "--dicom-root"), i + 1 < CommandLine.arguments.count {
        root = CommandLine.arguments[i + 1]
    }
    runRDMatrix(root: root); exit(0)
}
let opts = parseArgs(CommandLine.arguments)
if opts.rebuildCache { DICOMCorpus.clearCache() }

// MARK: - Codec setup

let jli420 = JLISwiftCodec(subsampling: .yuv420)
let jli444 = JLISwiftCodec(subsampling: .yuv444)
let jli444prog = JLISwiftCodec(subsampling: .yuv444, progressive: true)
let jli444progSA = JLISwiftCodec(subsampling: .yuv444, progressive: true,
                                 progressiveMode: .successiveApproximation)
let jli444rst = JLISwiftCodec(subsampling: .yuv444, restartInterval: 4)
let imageIO = ImageIOCodec()

// Reference codecs shell out to external binaries; each probes its install
// paths at construction time and reports `enabled` accordingly. Missing tools
// are dropped from the bench rather than failing every row.
let refCodecs: [CLICodec] = [
    ReferenceCodecs.libjpegTurbo(),
    ReferenceCodecs.mozjpeg(),
    ReferenceCodecs.jpegli(),
]

var codecs: [Codec] = [jli420, jli444, jli444prog, jli444progSA, jli444rst, imageIO]
for c in refCodecs where c.enabled { codecs.append(c) }

// Cross-codec pairs:
//   - JLISwift (4:4:4, 4:2:0, progressive) → every other codec's decoder
//   - every other codec's encoder → JLISwift decoder
// We deliberately skip third-party ↔ third-party pairs — they exercise
// libraries we don't ship and don't validate JLISwift. The progressive
// variant in the encoder set checks that ImageIO/libjpeg/mozjpeg decode
// JLISwift's progressive output.
var crossPairs: [(encoder: Codec, decoder: Codec)] = []
let jlEncoders: [Codec] = [jli444, jli420, jli444prog, jli444progSA, jli444rst]
let otherCodecs: [Codec] = [imageIO] + refCodecs.filter { $0.enabled }
for jl in jlEncoders {
    for other in otherCodecs {
        crossPairs.append((jl, other))
    }
}
for other in otherCodecs {
    crossPairs.append((other, jli444))
}
// Reverse restart direction: an independent encoder's restart-marker output must
// decode in JLISwift. (Forward — JLISwift restart → others — is covered above.)
let ltRestart = ReferenceCodecs.libjpegTurboRestart()
if ltRestart.enabled {
    crossPairs.append((ltRestart, jli444))
}

print("active codecs: \(codecs.map(\.name).joined(separator: ", "))")
let missing = refCodecs.filter { !$0.enabled }.map(\.name)
if !missing.isEmpty {
    print("inactive (install via brew): \(missing.joined(separator: ", "))")
}
print("")

// Accumulator that everything (synthetic + DICOM, self + cross) appends to,
// then fed into baseline save / regression check.
var baselineRows = [BaselineRow]()

@MainActor @inline(__always)
func recordSelf(_ r: Result, kind: String = "self") {
    baselineRows.append(BaselineRow(
        kind: kind, codec: r.codec, image: r.image, quality: r.quality,
        bytes: r.encodedBytes, psnrDB: r.psnrDB
    ))
}

@MainActor @inline(__always)
func recordCross(_ r: CrossResult, kind: String = "cross") {
    // Decode failure → -inf so a baseline can pin "this pair fails today" and
    // the regression check fires the moment it changes.
    baselineRows.append(BaselineRow(
        kind: kind, codec: "\(r.encoderName)->\(r.decoderName)",
        image: r.image, quality: r.quality,
        bytes: r.encodedBytes, psnrDB: r.psnrDB ?? -Double.infinity
    ))
}

// MARK: - Synthetic bench

if opts.mode != .dicomOnly {
    print("JLIBench — JLISwift vs Apple ImageIO")
    print("")
    print("=== Self-codec round-trip (synthetic) ===")
    print("")
    var selfResults = [Result]()
    for size in [64, 256, 512] {
        for image in TestImages.make(size: size) {
            for q in [50, 75, 90] {
                for codec in codecs {
                    do {
                        let r = try Harness.run(codec: codec, image: image, quality: q, butteraugli: opts.butteraugli)
                        selfResults.append(r); recordSelf(r)
                    } catch {
                        print("FAIL \(codec.name) / \(image.name) / q=\(q): \(error)")
                    }
                }
            }
        }
    }
    printTable(selfResults)

    print("")
    print("=== Cross-codec compatibility (synthetic) ===")
    print("")
    var crossResults = [CrossResult]()
    for size in [128, 256, 512] {
        for image in TestImages.make(size: size) {
            for q in [50, 75, 90] {
                for pair in crossPairs {
                    let r = Harness.runCross(
                        encoder: pair.encoder, decoder: pair.decoder,
                        image: image, quality: q
                    )
                    crossResults.append(r); recordCross(r)
                }
            }
        }
    }
    printCrossTable(crossResults)
}

// MARK: - DICOM corpus bench

if opts.mode != .syntheticOnly {
    print("")
    print("=== DICOM corpus (\(opts.perModality)/modality from \(opts.dicomRoot)) ===")
    print("")
    let corpus = DICOMCorpus.load(rootDir: opts.dicomRoot, perModality: opts.perModality)
    if corpus.isEmpty {
        print("no DICOM images loaded — check --dicom-root path and that files are uncompressed")
    } else {
        // Group images by modality for a per-modality summary line.
        var byModality = [String: [CorpusImage]]()
        for img in corpus { byModality[img.modality, default: []].append(img) }
        print("loaded \(corpus.count) images:")
        for m in DICOMCorpus.modalities {
            if let imgs = byModality[m] {
                let totalPixels = imgs.reduce(0) { $0 + $1.width * $1.height }
                print("  \(m): \(imgs.count) images (\(totalPixels / 1000) Kpx total)")
            }
        }
        print("")

        var dicomSelf = [Result]()
        var dicomCross = [CrossResult]()
        for img in corpus {
            if img.width * img.height > opts.maxPixels {
                print("skip \(img.id) (\(img.width)×\(img.height) > max \(opts.maxPixels) px)")
                continue
            }
            let testImage = TestImage(
                name: img.id, width: img.width, height: img.height, rgb: img.rgb
            )
            // Self-codec
            for q in opts.dicomQualities {
                for codec in codecs {
                    do {
                        let r = try Harness.run(codec: codec, image: testImage, quality: q, butteraugli: opts.butteraugli)
                        dicomSelf.append(r); recordSelf(r)
                    } catch {
                        print("FAIL self \(codec.name) / \(img.id) / q=\(q): \(error)")
                    }
                }
            }
            // Cross-codec
            for q in opts.dicomQualities {
                for pair in crossPairs {
                    let r = Harness.runCross(
                        encoder: pair.encoder, decoder: pair.decoder,
                        image: testImage, quality: q
                    )
                    dicomCross.append(r); recordCross(r)
                }
            }
        }

        print("--- DICOM self-codec ---")
        printTable(dicomSelf)
        print("")
        print("--- DICOM cross-codec ---")
        printCrossTable(dicomCross)
    }
}

// MARK: - 12-bit grayscale DICOM bench

if opts.dicom12 {
    print("")
    print("=== DICOM corpus 12-bit grayscale (native precision) ===")
    print("")
    let lt12 = ReferenceCodecs.libjpegTurbo12()
    // JLISwift grayscale ignores subsampling, so one instance represents it.
    let gray16Codecs: [Gray16Codec] = lt12.enabled ? [jli444, lt12] : [jli444]
    print("active 12-bit codecs: \(gray16Codecs.map(\.name).joined(separator: ", "))")
    if !lt12.enabled {
        print("(libjpeg-turbo-12 unavailable — install jpeg-turbo for 12-bit cross-codec)")
    }
    print("")

    let corpus = DICOMCorpus.load(rootDir: opts.dicomRoot, perModality: opts.perModality)
    var self12 = [Result]()
    var cross12 = [CrossResult]()
    for img in corpus {
        if img.width * img.height > opts.maxPixels { continue }
        let g16 = Gray16Image(name: img.id, width: img.width, height: img.height, samples: img.gray12)
        for q in opts.dicomQualities {
            for codec in gray16Codecs {
                do {
                    let r = try Harness.runGray16(codec: codec, image: g16, quality: q)
                    self12.append(r); recordSelf(r, kind: "self12")
                } catch {
                    print("FAIL self12 \(codec.name) / \(img.id) / q=\(q): \(error)")
                }
            }
            // Cross JLISwift ↔ libjpeg-turbo-12 (only if the reference is present).
            if lt12.enabled {
                let a = Harness.runCrossGray16(encoder: jli444, decoder: lt12, image: g16, quality: q)
                cross12.append(a); recordCross(a, kind: "cross12")
                let b = Harness.runCrossGray16(encoder: lt12, decoder: jli444, image: g16, quality: q)
                cross12.append(b); recordCross(b, kind: "cross12")
            }
        }
    }
    print("--- 12-bit self-codec (PSNR peak 4095) ---")
    printTable(self12)
    if !cross12.isEmpty {
        print("")
        print("--- 12-bit cross-codec ---")
        printCrossTable(cross12)
    }

    // 12-bit color — synthetic only (no 12-bit color DICOM; clinical data is gray).
    print("")
    print("=== 12-bit color (synthetic, native precision) ===")
    let lt12c = ReferenceCodecs.libjpegTurbo12Color()
    let color16Codecs: [Color16Codec] = lt12c.enabled ? [jli444, lt12c] : [jli444]
    print("active 12-bit color codecs: \(color16Codecs.map(\.name).joined(separator: ", "))")
    if !lt12c.enabled {
        print("(libjpeg-turbo-12 unavailable — install jpeg-turbo for 12-bit color cross-codec)")
    }
    print("")
    var selfC12 = [Result]()
    var crossC12 = [CrossResult]()
    for img in TestImages.color12(size: 64) {
        for q in opts.dicomQualities {
            for codec in color16Codecs {
                do {
                    let r = try Harness.runColor16(codec: codec, image: img, quality: q)
                    selfC12.append(r); recordSelf(r, kind: "self12c")
                } catch {
                    print("FAIL self12c \(codec.name) / \(img.name) / q=\(q): \(error)")
                }
            }
            if lt12c.enabled {
                let a = Harness.runCrossColor16(encoder: jli444, decoder: lt12c, image: img, quality: q)
                crossC12.append(a); recordCross(a, kind: "cross12c")
                let b = Harness.runCrossColor16(encoder: lt12c, decoder: jli444, image: img, quality: q)
                crossC12.append(b); recordCross(b, kind: "cross12c")
            }
        }
    }
    print("--- 12-bit color self-codec (PSNR peak 4095) ---")
    printTable(selfC12)
    if !crossC12.isEmpty {
        print("")
        print("--- 12-bit color cross-codec ---")
        printCrossTable(crossC12)
    }
}

// MARK: - Regression

switch opts.regression {
case .none:
    break

case .save(let path):
    let baseline = Baseline(
        createdAt: ISO8601DateFormatter().string(from: Date()),
        toolVersion: JLISwift.version,
        rows: baselineRows
    )
    do {
        try BaselineStore.save(baseline, to: path)
        print("")
        print("baseline saved: \(path) (\(baselineRows.count) rows)")
    } catch {
        FileHandle.standardError.write(Data("save failed: \(error)\n".utf8))
        exit(2)
    }

case .check(let path):
    do {
        let baseline = try BaselineStore.load(path)
        let diffs = BaselineCompare.diff(baseline: baseline, current: baselineRows)
        let hasRegression = BaselineCompare.printSummary(diffs)
        exit(hasRegression ? 1 : 0)
    } catch {
        FileHandle.standardError.write(Data("check failed: \(error)\n".utf8))
        exit(2)
    }
}

// MARK: - Sample JPEGs to disk

let sampleDir = NSTemporaryDirectory() + "jlibench-samples"
try? FileManager.default.createDirectory(
    atPath: sampleDir, withIntermediateDirectories: true
)
let sampleImage = TestImages.gradient(name: "gradient-256", size: 256)
var samplesWritten = [String]()
for codec in codecs {
    for q in [50, 90] {
        do {
            let bytes = try codec.encode(
                rgb: sampleImage.rgb,
                width: sampleImage.width, height: sampleImage.height, quality: q
            )
            let safe = codec.name.replacingOccurrences(of: "(", with: "-")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: ":", with: "")
            let path = "\(sampleDir)/\(safe)_q\(q)_\(sampleImage.name).jpg"
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            samplesWritten.append(path)
        } catch {
            print("FAIL writing sample for \(codec.name) q=\(q): \(error)")
        }
    }
}

print("")
print("=== Sample JPEGs written for external inspection ===")
print("Compare with:  djpeg -fast <file>.jpg | wc -c   or   identify <file>.jpg")
for path in samplesWritten {
    print("  \(path)")
}
