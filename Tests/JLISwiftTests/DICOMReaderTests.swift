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
    /// 8-bit pixel data (OB), bytes verbatim.
    mutating func ob(_ g: UInt16, _ e: UInt16, _ value: [UInt8]) {
        append16(g); append16(e); elements += Array("OB".utf8); append16(0)
        append32(UInt32(value.count)); elements += value
    }
    /// An undefined-length (FFFFFFFF) sequence carrying one undefined-length item
    /// that itself contains `inner` elements, closed by Item- and Sequence-
    /// Delimitation Items. Exercises the SQ-skip path that must not derail the
    /// pixel-module parse.
    mutating func undefinedLengthSQ(_ g: UInt16, _ e: UInt16, inner: [UInt8]) {
        append16(g); append16(e); elements += Array("SQ".utf8); append16(0)
        append32(0xFFFFFFFF)                       // undefined sequence length
        append16(0xFFFE); append16(0xE000); append32(0xFFFFFFFF)   // Item, undefined length
        elements += inner
        append16(0xFFFE); append16(0xE00D); append32(0)            // Item Delimitation
        append16(0xFFFE); append16(0xE0DD); append32(0)            // Sequence Delimitation
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

    @Test("render8bit re-maps an explicit window/level")
    func explicitWindow() throws {
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 1)
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 4)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 16)
        b.us(0x0028, 0x0103, 0)
        b.ow(0x7FE0, 0x0010, [0, 100, 200, 300])   // no window/rescale tags

        let img = try DICOMReader.read(b.bytes())

        // Full range and the window derived from it when none is stored.
        let (lo, hi) = img.intensityRange()
        #expect(lo == 0 && hi == 300)
        let (c, w) = img.windowDefaults()
        #expect(c == 150 && w == 300)

        // Wide window [0,300]: monotonic ramp, endpoints hit black/white.
        let wide = img.render8bit(windowCenter: 150, windowWidth: 300)
        #expect(wide[0] == 0)        // 0   → black
        #expect(wide[9] == 255)      // 300 → white
        #expect(wide[3] > wide[0] && wide[6] > wide[3] && wide[9] > wide[6])

        // Narrow window centered at 200, width 100 → [150,250]: values below the
        // window clamp to black, the center sits mid-gray. Proves the window remaps.
        let narrow = img.render8bit(windowCenter: 200, windowWidth: 100)
        #expect(narrow[0] == 0)                       // 0   below window → black
        #expect(narrow[3] == 0)                       // 100 below window → black
        #expect(narrow[6] > 100 && narrow[6] < 160)   // 200 at center → ~mid gray
        #expect(narrow[9] == 255)                     // 300 above window → white
    }

    @Test("windowDefaults prefers the stored WindowCenter/WindowWidth")
    func storedWindowDefaults() throws {
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 1)
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 4)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 16)
        b.us(0x0028, 0x0103, 0)
        b.str(0x0028, 0x1050, "DS", "200")    // WindowCenter
        b.str(0x0028, 0x1051, "DS", "100")    // WindowWidth
        b.ow(0x7FE0, 0x0010, [0, 100, 200, 300])

        let img = try DICOMReader.read(b.bytes())
        let (c, w) = img.windowDefaults()
        #expect(c == 200 && w == 100)
        // toRGB8() must apply that stored window — identical to render8bit(200,100).
        #expect(img.toRGB8() == img.render8bit(windowCenter: 200, windowWidth: 100))
    }

    // MARK: - Safety guards (decompression bomb / truncated PixelData)

    /// Builds a 16-bit MONOCHROME2 DICOM with the given geometry and raw samples.
    private func makeImage(rows: Int, cols: Int, samples: [UInt16]) -> [UInt8] {
        var b = DICOMBuilder()
        b.us(0x0028, 0x0010, UInt16(rows))     // Rows
        b.us(0x0028, 0x0011, UInt16(cols))     // Columns
        b.us(0x0028, 0x0100, 16)               // BitsAllocated
        b.us(0x0028, 0x0101, 16)               // BitsStored
        b.us(0x0028, 0x0103, 0)                // PixelRepresentation (unsigned)
        b.ow(0x7FE0, 0x0010, samples)          // PixelData
        return b.bytes()
    }

    @Test("Oversized geometry is rejected (decompression-bomb guard)")
    func imageTooLargeIsRejected() {
        // 65535×65535 ≈ 4.29e9 samples, far above the 268 MP cap. A tiny header
        // must throw, not attempt a multi-gigabyte allocation (OOM trap).
        let bytes = makeImage(rows: 65535, cols: 65535, samples: [0])
        #expect(throws: DICOMError.self) { _ = try DICOMReader.read(bytes) }
    }

    @Test("Short PixelData is rejected, not silently under-filled")
    func truncatedPixelDataIsRejected() {
        // Declares 16×16×2 = 512 bytes of PixelData but supplies only one sample.
        let bytes = makeImage(rows: 16, cols: 16, samples: [1])
        #expect(throws: DICOMError.self) { _ = try DICOMReader.read(bytes) }
    }

    @Test("A correctly-sized image still reads after the guards")
    func wellFormedImageStillReadsAfterGuards() throws {
        // 2×2 16-bit, exactly 4 samples — must decode unaffected.
        let bytes = makeImage(rows: 2, cols: 2, samples: [10, 20, 30, 40])
        let img = try DICOMReader.read(bytes)
        #expect(img.width == 2)
        #expect(img.height == 2)
    }

    // MARK: - Correctness hardening (SQ skip, signed bitsStored, planar config)

    @Test("An undefined-length sequence before the pixel module does not derail parsing")
    func undefinedLengthSequenceIsSkipped() throws {
        // A Referenced Image Sequence (0008,1140) with undefined length sits
        // BEFORE the pixel-module attributes. Before the fix, the parser descended
        // into its items and read garbage for Rows/Columns; now it steps over it.
        var inner = DICOMBuilder()
        inner.us(0x0028, 0x0010, 999)             // a decoy "Rows" inside the sequence
        inner.us(0x0028, 0x0011, 999)             // a decoy "Columns" inside the sequence

        var b = DICOMBuilder()
        b.undefinedLengthSQ(0x0008, 0x1140, inner: inner.elements)   // Referenced Image Sequence
        b.us(0x0028, 0x0002, 1)
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 2)                   // real Rows
        b.us(0x0028, 0x0011, 2)                   // real Columns
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 16)
        b.us(0x0028, 0x0103, 0)
        b.ow(0x7FE0, 0x0010, [0, 100, 200, 300])

        let img = try DICOMReader.read(b.bytes())
        #expect(img.width == 2 && img.height == 2)   // not 999 — sequence was skipped
    }

    @Test("Signed 12-bit-in-16 data is sign-extended from the stored sign bit")
    func signed12BitInerSignExtension() throws {
        // CT-like: 16-bit container, only 12 bits stored, signed. A stored value
        // of 0x0FFF (12-bit −1 in two's complement) must decode to −1, not 4095.
        // intercept 0 / slope 1, so the intensity IS the signed stored value.
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 1)
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 1)                   // Rows
        b.us(0x0028, 0x0011, 2)                   // Columns
        b.us(0x0028, 0x0100, 16)                  // BitsAllocated
        b.us(0x0028, 0x0101, 12)                  // BitsStored
        b.us(0x0028, 0x0102, 11)                  // HighBit
        b.us(0x0028, 0x0103, 1)                   // PixelRepresentation = signed
        b.ow(0x7FE0, 0x0010, [0x0FFF, 0x0001])    // 12-bit −1, then +1

        let img = try DICOMReader.read(b.bytes())
        let (lo, hi) = img.intensityRange()
        #expect(lo == -1, "stored 0x0FFF should sign-extend to −1, got \(lo)")
        #expect(hi == 1)
    }

    @Test("Unsigned 12-bit-in-16 data masks non-significant high bits")
    func unsigned12BitMasking() throws {
        // Unsigned, 12 bits stored. A container value of 0xF001 has dirty high
        // bits; only the low 12 (0x001 = 1) are significant.
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 1)
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 12)
        b.us(0x0028, 0x0102, 11)
        b.us(0x0028, 0x0103, 0)                   // unsigned
        b.ow(0x7FE0, 0x0010, [0xF001, 0x0FFF])    // → 1 and 4095 after masking

        let img = try DICOMReader.read(b.bytes())
        let (lo, hi) = img.intensityRange()
        #expect(lo == 1, "0xF001 should mask to 1, got \(lo)")
        #expect(hi == 4095)
    }

    @Test("Plane-interleaved RGB (PlanarConfiguration 1) is reassembled correctly")
    func planarConfigurationReassembly() throws {
        // 2×1 RGB, plane-interleaved: R-plane [10,11], G-plane [20,21],
        // B-plane [30,31]. Pixel 0 must come out (10,20,30), pixel 1 (11,21,31).
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 3)                   // SamplesPerPixel = 3
        b.str(0x0028, 0x0004, "CS", "RGB")
        b.us(0x0028, 0x0006, 1)                   // PlanarConfiguration = 1 (planar)
        b.us(0x0028, 0x0010, 1)                   // Rows
        b.us(0x0028, 0x0011, 2)                   // Columns
        b.us(0x0028, 0x0100, 8)
        b.us(0x0028, 0x0101, 8)
        b.us(0x0028, 0x0103, 0)
        b.ob(0x7FE0, 0x0010, [10, 11, 20, 21, 30, 31])   // R…R G…G B…B

        let img = try DICOMReader.read(b.bytes())
        let rgb = img.toRGB8()
        #expect(Array(rgb[0..<3]) == [10, 20, 30])
        #expect(Array(rgb[3..<6]) == [11, 21, 31])
    }

    // MARK: - DICOMWindowRenderer (cached interactive window/level)

    @Test("DICOMWindowRenderer matches DICOMImage rendering pixel-exactly")
    func windowRendererMatchesImageRender() throws {
        // 16-bit signed, bitsStored 12, CT-like rescale (intercept −1024), and a
        // sample spread that exercises below-window clamp, in-window ramp, and
        // above-window clamp — the vDSP chain must reproduce the scalar path
        // byte-for-byte across every branch (incl. MONOCHROME1 inversion).
        for photometric in ["MONOCHROME2", "MONOCHROME1"] {
            var b = DICOMBuilder()
            b.us(0x0028, 0x0002, 1)
            b.str(0x0028, 0x0004, "CS", photometric)
            b.us(0x0028, 0x0010, 8)                    // Rows
            b.us(0x0028, 0x0011, 8)                    // Columns
            b.us(0x0028, 0x0100, 16)                   // BitsAllocated
            b.us(0x0028, 0x0101, 12)                   // BitsStored
            b.us(0x0028, 0x0103, 1)                    // signed
            b.str(0x0028, 0x1052, "DS", "-1024")       // RescaleIntercept
            b.str(0x0028, 0x1053, "DS", "1")           // RescaleSlope
            var samples = [UInt16]()
            for i in 0..<64 { samples.append(UInt16(i * 64) & 0x0FFF) }
            b.ow(0x7FE0, 0x0010, samples)

            let img = try DICOMReader.read(b.bytes())
            let renderer = DICOMWindowRenderer(img)

            let (lo, hi) = img.intensityRange()
            let (rlo, rhi) = renderer.intensityRange()
            #expect(lo == rlo && hi == rhi)

            for (c, w) in [(0.0, 100.0), (40.0, 400.0), (-500.0, 2000.0), (1000.0, 1.0)] {
                #expect(renderer.render8bit(windowCenter: c, windowWidth: w)
                        == img.render8bit(windowCenter: c, windowWidth: w),
                        "\(photometric) 8-bit window (\(c), \(w)) differs")
                #expect(renderer.render12bit(windowCenter: c, windowWidth: w)
                        == img.render12bit(windowCenter: c, windowWidth: w),
                        "\(photometric) 12-bit window (\(c), \(w)) differs")
            }
        }
    }

    @Test("Non-finite rescale/window DS values are sanitized, not trapped on")
    func nonFiniteRescaleSanitized() throws {
        // "nan"/"inf" are valid Double(_:) parses, so a hostile DS tag would
        // push NaN through the Modality LUT into UInt8(v*255+0.5) — an
        // uncatchable trap. The reader sanitizes at the parse boundary.
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 1)
        b.str(0x0028, 0x0004, "CS", "MONOCHROME2")
        b.us(0x0028, 0x0010, 2)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 16)
        b.us(0x0028, 0x0101, 12)
        b.us(0x0028, 0x0103, 0)
        b.str(0x0028, 0x1050, "DS", "nan")        // WindowCenter
        b.str(0x0028, 0x1051, "DS", "inf")        // WindowWidth
        b.str(0x0028, 0x1052, "DS", "-inf")       // RescaleIntercept
        b.str(0x0028, 0x1053, "DS", "nan")        // RescaleSlope
        b.ow(0x7FE0, 0x0010, [0, 100, 200, 300])

        let img = try DICOMReader.read(b.bytes())
        #expect(img.rescaleSlope == 1.0 && img.rescaleIntercept == 0.0)
        #expect(img.windowCenter == nil && img.windowWidth == nil)
        _ = img.toRGB8()                                          // must not trap
        _ = DICOMWindowRenderer(img).render8bit(windowCenter: 150, windowWidth: 300)
    }

    @Test("DICOMWindowRenderer matches DICOMImage render12bit on RGB input too")
    func windowRendererRGB12bitMatches() throws {
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 3)
        b.us(0x0028, 0x0006, 0)
        b.str(0x0028, 0x0004, "CS", "RGB")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 8)
        b.us(0x0028, 0x0101, 8)
        b.us(0x0028, 0x0103, 0)
        b.ob(0x7FE0, 0x0010, [10, 20, 30, 40, 50, 60])

        let img = try DICOMReader.read(b.bytes())
        let renderer = DICOMWindowRenderer(img)
        #expect(renderer.render12bit(windowCenter: 30, windowWidth: 60)
                == img.render12bit(windowCenter: 30, windowWidth: 60))
    }

    @Test("DICOMWindowRenderer passes 8-bit RGB through window-independently")
    func windowRendererRGBPassthrough() throws {
        var b = DICOMBuilder()
        b.us(0x0028, 0x0002, 3)                   // SamplesPerPixel = 3
        b.us(0x0028, 0x0006, 0)                   // PlanarConfiguration = 0
        b.str(0x0028, 0x0004, "CS", "RGB")
        b.us(0x0028, 0x0010, 1)
        b.us(0x0028, 0x0011, 2)
        b.us(0x0028, 0x0100, 8)
        b.us(0x0028, 0x0101, 8)
        b.us(0x0028, 0x0103, 0)
        b.ob(0x7FE0, 0x0010, [10, 20, 30, 40, 50, 60])

        let img = try DICOMReader.read(b.bytes())
        let renderer = DICOMWindowRenderer(img)
        #expect(renderer.render8bit(windowCenter: 1, windowWidth: 2) == img.toRGB8())
        #expect(renderer.render8bit(windowCenter: 99, windowWidth: 7) == img.toRGB8())
    }
}
