// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
@testable import JLIDICOM

/// Photometric-interpretation handling on read: YBR (YCbCr) → RGB conversion and
/// MONOCHROME1 (inverted) polarity. The medical-grade audit flagged that YBR was
/// rendered as if it were RGB, and that MONOCHROME1 inversion was applied but
/// never asserted end to end.
@Suite("DICOM color / photometric")
struct DICOMColorTests {

    /// Forward full-range BT.601 RGB → YBR_FULL, the encoder side of the reader's
    /// inverse, so we can build a YBR image of a known color.
    private func rgbToYBR(_ r: Double, _ g: Double, _ b: Double) -> [UInt8] {
        let y = 0.299*r + 0.587*g + 0.114*b
        let cb = 128 - 0.168736*r - 0.331264*g + 0.5*b
        let cr = 128 + 0.5*r - 0.418688*g - 0.081312*b
        func u8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return [u8(y), u8(cb), u8(cr)]
    }

    @Test("YBR_FULL is converted to RGB on render (not shown as raw YCbCr)")
    func ybrFullToRGB() throws {
        // Three known colors; the round-trip through 8-bit YBR is lossy by ≤ a
        // couple of levels, so assert closeness rather than exact equality.
        let colors: [(Double, Double, Double)] = [(200, 100, 50), (30, 180, 220), (255, 255, 255), (0, 0, 0)]
        for (r, g, b) in colors {
            let ybr = rgbToYBR(r, g, b)
            let module = DICOMWriter.PixelModule(
                rows: 1, columns: 1, bitsAllocated: 8, bitsStored: 8, highBit: 7,
                samplesPerPixel: 3, photometricInterpretation: "YBR_FULL")
            let img = try DICOMReader.read(DICOMWriter.write(pixelData: ybr, module: module))
            let rgb = img.toRGB8()
            #expect(abs(Int(rgb[0]) - Int(r)) <= 2, "R off: got \(rgb[0]) vs \(r)")
            #expect(abs(Int(rgb[1]) - Int(g)) <= 2, "G off: got \(rgb[1]) vs \(g)")
            #expect(abs(Int(rgb[2]) - Int(b)) <= 2, "B off: got \(rgb[2]) vs \(b)")
        }
    }

    @Test("YBR_FULL_422 is treated as YBR (converted), not RGB")
    func ybr422IsConverted() throws {
        // A pure-luma gray YBR pixel (Cb=Cr=128) must render as neutral gray; if it
        // were mistaken for RGB it would render as (Y,128,128) — a blue-green tint.
        let module = DICOMWriter.PixelModule(
            rows: 1, columns: 1, bitsAllocated: 8, bitsStored: 8, highBit: 7,
            samplesPerPixel: 3, photometricInterpretation: "YBR_FULL_422")
        let img = try DICOMReader.read(DICOMWriter.write(pixelData: [150, 128, 128], module: module))
        let rgb = img.toRGB8()
        #expect(rgb[0] == rgb[1] && rgb[1] == rgb[2], "neutral YBR must render gray, got \(rgb[0...2])")
        #expect(abs(Int(rgb[0]) - 150) <= 1)
    }

    @Test("True RGB photometric is passed through unchanged")
    func rgbPassthrough() throws {
        let px: [UInt8] = [10, 20, 30, 200, 150, 100]
        let module = DICOMWriter.PixelModule(
            rows: 1, columns: 2, bitsAllocated: 8, bitsStored: 8, highBit: 7,
            samplesPerPixel: 3, photometricInterpretation: "RGB")
        let img = try DICOMReader.read(DICOMWriter.write(pixelData: px, module: module))
        #expect(Array(img.toRGB8()) == px, "RGB must pass through unchanged")
    }

    @Test("MONOCHROME1 inverts polarity vs MONOCHROME2 end to end")
    func monochrome1Inversion() throws {
        // Same stored ramp under MONOCHROME2 vs MONOCHROME1: the rendered gray must
        // be the photometric inverse (0↔255) at the endpoints.
        func render(_ photo: String) throws -> [UInt8] {
            var px = [UInt8](); for v in [UInt16(0), 1000, 2000, 4095] { px.append(UInt8(v & 0xFF)); px.append(UInt8(v >> 8)) }
            let module = DICOMWriter.PixelModule(
                rows: 1, columns: 4, bitsAllocated: 16, bitsStored: 12, highBit: 11,
                photometricInterpretation: photo)
            return try DICOMReader.read(DICOMWriter.write(pixelData: px, module: module)).toRGB8()
        }
        let m2 = try render("MONOCHROME2")
        let m1 = try render("MONOCHROME1")
        // MONOCHROME2: low value dark, high value bright.
        #expect(m2[0] < 40 && m2[9] > 215)
        // MONOCHROME1: inverted — low value bright, high value dark.
        #expect(m1[0] > 215 && m1[9] < 40)
        // Each pel is the ~photometric inverse of the other (R channel).
        for i in stride(from: 0, to: 12, by: 3) {
            #expect(abs((255 - Int(m2[i])) - Int(m1[i])) <= 1, "MONO1 not inverse of MONO2 at \(i)")
        }
    }
}
