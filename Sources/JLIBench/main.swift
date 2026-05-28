// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

// MARK: - CLI

struct BenchOptions {
    enum Mode { case syntheticOnly, dicomOnly, both }

    var mode: Mode = .syntheticOnly
    var dicomRoot: String = "Sources/LocalDatasets/medical-dicom-organized"
    var perModality: Int = 3
    var dicomQualities: [Int] = [50, 90]
    var rebuildCache: Bool = false
    /// Skip huge plates (e.g. 5k×5k DX) by default so a single bench run
    /// stays under a minute. Bump on the CLI for an exhaustive sweep.
    var maxPixels: Int = 4_000_000
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
    JLIBench — JPEG codec benchmark

    Usage:
      JLIBench [flags]

    Mode flags:
      --dicom                Also run the DICOM corpus bench (default: synthetic only)
      --dicom-only           Skip synthetic; run only the DICOM corpus
      --dicom-root <path>    DICOM corpus root (default: Sources/LocalDatasets/medical-dicom-organized)
      --per-modality <N>     DICOM images per modality (default: 3)
      --max-pixels <N>       Skip DICOMs above this pixel count (default: 4000000)
      --rebuild-cache        Clear ~/.cache/jlibench/corpus before running
    """)
}

let opts = parseArgs(CommandLine.arguments)
if opts.rebuildCache { DICOMCorpus.clearCache() }

// MARK: - Codec setup

let jli420 = JLISwiftCodec(subsampling: .yuv420)
let jli444 = JLISwiftCodec(subsampling: .yuv444)
let imageIO = ImageIOCodec()
let codecs: [Codec] = [jli420, jli444, imageIO]

let crossPairs: [(encoder: Codec, decoder: Codec)] = [
    (jli444, imageIO),
    (jli420, imageIO),
    (imageIO, jli444),
]

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
                        selfResults.append(r)
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
                    crossResults.append(r)
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
            for q in opts.dicomQualities {
                for codec in codecs {
                    do {
                        let r = try Harness.run(codec: codec, image: testImage, quality: q)
                        dicomSelf.append(r)
                    } catch {
                        print("FAIL self \(codec.name) / \(img.id) / q=\(q): \(error)")
                    }
                }
            }
            for q in opts.dicomQualities {
                for pair in crossPairs {
                    let r = Harness.runCross(
                        encoder: pair.encoder, decoder: pair.decoder,
                        image: testImage, quality: q
                    )
                    dicomCross.append(r)
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
