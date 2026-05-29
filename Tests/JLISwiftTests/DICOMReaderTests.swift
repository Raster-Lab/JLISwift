// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
@testable import JLIDICOM

/// Builds a minimal Explicit VR Little Endian DICOM in memory (no patient data)
/// so the reader can be exercised in CI without shipping clinical files.
private struct DICOMBuilder {
    var elements: [UInt8] = []

    mutating func us(_ g: UInt16, _ e: UInt16, _ v: UInt16) {
        short(g, e, "US", [UInt8(v & 0xFF), UInt8(v >> 8)])
    }
    mutating func str(_ g: UInt16, _ e: UInt16, _ vr: String, _ s: String) {
        var bytes = Array(s.utf8)
        if bytes.count % 2 != 0 { bytes.append(0x20) }   // pad to even length
        short(g, e, vr, bytes)
    }
    mutating func ow(_ g: UInt16, _ e: UInt16, _ samples: [UInt16]) {
        var value = [UInt8]()
        for s in samples { value.append(UInt8(s & 0xFF)); value.append(UInt8(s >> 8)) }
        // Long form: group, element, VR, 2 reserved, 4-byte length.
        append16(g); append16(e); elements += Array("OW".utf8); append16(0)
        append32(UInt32(value.count)); elements += value
    }
    private mutating func short(_ g: UInt16, _ e: UInt16, _ vr: String, _ value: [UInt8]) {
        append16(g); append16(e); elements += Array(vr.utf8); append16(UInt16(value.count))
        elements += value
    }
    private mutating func append16(_ v: UInt16) { elements.append(UInt8(v & 0xFF)); elements.append(UInt8(v >> 8)) }
    private mutating func append32(_ v: UInt32) {
        elements.append(UInt8(v & 0xFF)); elements.append(UInt8((v >> 8) & 0xFF))
        elements.append(UInt8((v >> 16) & 0xFF)); elements.append(UInt8((v >> 24) & 0xFF))
    }

    func bytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 128)   // preamble
        out += Array("DICM".utf8)
        // File meta: Transfer Syntax = Explicit VR Little Endian.
        var meta = DICOMBuilder()
        meta.str(0x0002, 0x0010, "UI", "1.2.840.10008.1.2.1\0")
        out += meta.elements
        out += elements
        return out
    }
}

@Suite("DICOM reader")
struct DICOMReaderTests {

    @Test("Rescale slope/intercept are applied before windowing (CT not blown white)")
    func rescaleApplied() throws {
        // CT-like: 2×2, 16-bit unsigned, intercept −1024 (HU = raw − 1024),
        // window center 40 / width 400 → display range HU [−160, 240].
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 1)                       // SamplesPerPixel
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")    // Photometric
        b.us(0x0028, 0x0010, 2)                       // Rows
        b.us(0x0028, 0x0011, 2)                       // Columns
        b.us(0x0028, 0x0100, 16)                      // BitsAllocated
        b.us(0x0028, 0x0101, 16)                      // BitsStored
        b.us(0x0028, 0x0103, 0)                       // PixelRepresentation (unsigned)
        b.str(0x0028, 0x1050, "DS", "40")             // WindowCenter
        b.str(0x0028, 0x1051, "DS", "400")            // WindowWidth
        b.str(0x0028, 0x1052, "DS", "-1024")          // RescaleIntercept
        b.str(0x0028, 0x1053, "DS", "1")              // RescaleSlope
        // raw → HU: 924→−100, 1024→0, 1224→200, 1424→400
        b.ow(0x7FE0, 0x0010, [924, 1024, 1224, 1424])

        let img = try DICOMReader.read(b.bytes())
        #expect(img.width == 2 && img.height == 2)
        #expect(img.rescaleIntercept == -1024 && img.rescaleSlope == 1)

        let rgb = img.toRGB8()
        // Pixel 0 (raw 924, HU −100) maps near the dark end. WITHOUT the rescale
        // intercept, raw 924 sits far above the [−160,240] window and clamps to
        // 255 (the white-CT bug) — so a dark value here proves rescale is applied.
        #expect(rgb[0] < 80, "pixel 0 should be dark (got \(rgb[0])) — rescale not applied?")
        // Pixel 3 (HU 400) is above the window top → white.
        #expect(rgb[9] == 255)
        // Monotonic increasing brightness across the four samples.
        #expect(rgb[0] < rgb[3] && rgb[3] < rgb[6] && rgb[6] <= rgb[9])
    }

    @Test("No rescale tags → identity (8-bit photographic DICOM unchanged)")
    func noRescaleIdentity() throws {
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 1)
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 4)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 16)
        b.us(0x0028, 0x0103, 0)
        // No window, no rescale → auto min/max over [0, 100, 200, 300].
        b.ow(0x7FE0, 0x0010, [0, 100, 200, 300])

        let img = try DICOMReader.read(b.bytes())
        #expect(img.rescaleSlope == 1 && img.rescaleIntercept == 0)
        let rgb = img.toRGB8()
        #expect(rgb[0] == 0)        // min → black
        #expect(rgb[9] == 255)      // max → white
    }
}
