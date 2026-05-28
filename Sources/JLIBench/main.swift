// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

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
}

func parseArgs(_ argv: [String]) -> BenchOptions {
    var opts = BenchOptions()
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--dicom":             opts.mode = .both
        case "--dicom-only":        opts.mode = .dicomOnly
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
      --rebuild-cache        Clear ~/.cache/jlibench/corpus before running

    Regression flags:
      --save-baseline <path>   Save run results as baseline JSON
      --check-baseline <path>  Load baseline JSON, compare, exit 1 on regression
    """)
}

let opts = parseArgs(CommandLine.arguments)
if opts.rebuildCache { DICOMCorpus.clearCache() }

// MARK: - Codec setup

let jli420 = JLISwiftCodec(subsampling: .yuv420)
let jli444 = JLISwiftCodec(subsampling: .yuv444)
let imageIO = ImageIOCodec()

// Reference codecs shell out to external binaries; each probes its install
// paths at construction time and reports `enabled` accordingly. Missing tools
// are dropped from the bench rather than failing every row.
let refCodecs: [CLICodec] = [
    ReferenceCodecs.libjpegTurbo(),
    ReferenceCodecs.mozjpeg(),
    ReferenceCodecs.jpegli(),
]

var codecs: [Codec] = [jli420, jli444, imageIO]
for c in refCodecs where c.enabled { codecs.append(c) }

// Cross-codec pairs:
//   - JLISwift (both subsamplings) → every other codec's decoder
//   - every other codec's encoder → JLISwift decoder
// We deliberately skip third-party ↔ third-party pairs — they exercise
// libraries we don't ship and don't validate JLISwift.
var crossPairs: [(encoder: Codec, decoder: Codec)] = []
let jlEncoders: [Codec] = [jli444, jli420]
let otherCodecs: [Codec] = [imageIO] + refCodecs.filter { $0.enabled }
for jl in jlEncoders {
    for other in otherCodecs {
        crossPairs.append((jl, other))
    }
}
for other in otherCodecs {
    crossPairs.append((other, jli444))
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
func recordSelf(_ r: Result) {
    baselineRows.append(BaselineRow(
        kind: "self", codec: r.codec, image: r.image, quality: r.quality,
        bytes: r.encodedBytes, psnrDB: r.psnrDB
    ))
}

@MainActor @inline(__always)
func recordCross(_ r: CrossResult) {
    guard let psnr = r.psnrDB else {
        // Decode failure — encode an explicit -inf so a baseline can pin
        // "this pair fails" and the regression check flags it if it changes.
        baselineRows.append(BaselineRow(
            kind: "cross", codec: "\(r.encoderName)->\(r.decoderName)",
            image: r.image, quality: r.quality,
            bytes: r.encodedBytes, psnrDB: -Double.infinity
        ))
        return
    }
    baselineRows.append(BaselineRow(
        kind: "cross", codec: "\(r.encoderName)->\(r.decoderName)",
        image: r.image, quality: r.quality,
        bytes: r.encodedBytes, psnrDB: psnr
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
                        let r = try Harness.run(codec: codec, image: image, quality: q)
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
                        let r = try Harness.run(codec: codec, image: testImage, quality: q)
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
