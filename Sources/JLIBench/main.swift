// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLISwift

let qualities = [50, 75, 90]
let sizes = [64, 256, 512]

let jli420 = JLISwiftCodec(subsampling: .yuv420)
let jli444 = JLISwiftCodec(subsampling: .yuv444)
let imageIO = ImageIOCodec()

let codecs: [Codec] = [jli420, jli444, imageIO]

print("JLIBench — JLISwift vs Apple ImageIO")
print("")
print("=== Self-codec round-trip (encode + decode in same codec) ===")
print("")

var selfResults = [Result]()
for size in sizes {
    let images = TestImages.make(size: size)
    for image in images {
        for q in qualities {
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

// MARK: - Cross-codec compatibility

// Encode with one codec, decode with another. Tests whether our output is spec-
// compliant (other tools can decode it) and whether our decoder handles JPEGs
// emitted by other encoders. All JLISwift instances share a decoder, so we only
// need one as the "decoder" representative on that side.
let crossPairs: [(encoder: Codec, decoder: Codec)] = [
    (jli444, imageIO),
    (jli420, imageIO),
    (imageIO, jli444),  // any JLISwift instance — decode ignores encoder subsampling
]

let crossSizes = [128, 256, 512]
let crossQualities = [50, 75, 90]

print("")
print("=== Cross-codec compatibility (encode → other-codec decode) ===")
print("")

var crossResults = [CrossResult]()
for size in crossSizes {
    for image in TestImages.make(size: size) {
        for q in crossQualities {
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

// MARK: - Sample JPEGs to disk for external verification

// Write a handful of JLISwift-encoded JPEGs to /tmp so the user can pipe them
// through djpeg/jpeginfo/identify/Preview.app to independently confirm spec
// compliance with tools we don't ship a wrapper for.
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
