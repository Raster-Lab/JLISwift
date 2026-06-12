// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
@testable import JLIDICOM
@testable import JLISwift

@Suite("DICOM writer")
struct DICOMWriterTests {

    private func le16(_ vals: [UInt16]) -> [UInt8] {
        var d = [UInt8](); for v in vals { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }; return d
    }

    @Test("Native 16-bit grayscale round-trips through writer → reader")
    func native16RoundTrip() throws {
        let samples: [UInt16] = [0, 100, 2000, 4095]
        let module = DICOMWriter.PixelModule(
            rows: 2, columns: 2, bitsAllocated: 16, bitsStored: 12, highBit: 11,
            pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2",
            rescaleSlope: 1, rescaleIntercept: -1024, windowCenter: 40, windowWidth: 400,
            modality: "CT")
        let file = try DICOMWriter.write(pixelData: le16(samples), module: module)

        let img = try DICOMReader.read(file)
        #expect(img.width == 2 && img.height == 2)
        #expect(img.bitsAllocated == 16 && img.bitsStored == 12)
        #expect(img.modality == "CT")
        #expect(img.rescaleIntercept == -1024 && img.rescaleSlope == 1)
        #expect(img.windowCenter == 40 && img.windowWidth == 400)
        #expect(img.pixelData == le16(samples))   // pixel bytes preserved exactly
    }

    @Test("Native signed 16-bit round-trips and sign-extends on read")
    func nativeSigned16RoundTrip() throws {
        // Signed 12-bit-in-16: stored 0x0FFF must read back as −1 (slope 1, intercept 0).
        let module = DICOMWriter.PixelModule(
            rows: 1, columns: 2, bitsAllocated: 16, bitsStored: 12, highBit: 11,
            pixelRepresentation: 1, photometricInterpretation: "MONOCHROME2", modality: "CT")
        let file = try DICOMWriter.write(pixelData: le16([0x0FFF, 0x0001]), module: module)

        let img = try DICOMReader.read(file)
        #expect(img.pixelRepresentation == 1)
        let (lo, hi) = img.intensityRange()
        #expect(lo == -1 && hi == 1)
    }

    @Test("Native 8-bit RGB round-trips with pixels preserved")
    func native8RGBRoundTrip() throws {
        // 2×1 interleaved RGB.
        let px: [UInt8] = [10, 20, 30, 40, 50, 60]
        let module = DICOMWriter.PixelModule(
            rows: 1, columns: 2, bitsAllocated: 8, bitsStored: 8, highBit: 7,
            samplesPerPixel: 3, photometricInterpretation: "RGB")
        let file = try DICOMWriter.write(pixelData: px, module: module)

        let img = try DICOMReader.read(file)
        #expect(img.samplesPerPixel == 3)
        #expect(img.pixelData == px)
        #expect(Array(img.toRGB8()[0..<6]) == px)
    }

    @Test("Writer rejects a pixel buffer that doesn't match the geometry")
    func writerRejectsSizeMismatch() {
        let module = DICOMWriter.PixelModule(
            rows: 4, columns: 4, bitsAllocated: 16, bitsStored: 16, highBit: 15)
        #expect(throws: DICOMWriter.WriteError.self) {
            _ = try DICOMWriter.write(pixelData: [1, 2, 3, 4], module: module)   // far too short
        }
    }

    @Test("Writer rejects an invalid pixel module")
    func writerRejectsInvalidModule() {
        let module = DICOMWriter.PixelModule(
            rows: 2, columns: 2, bitsAllocated: 12, bitsStored: 12, highBit: 11)   // 12 not allowed
        #expect(throws: DICOMWriter.WriteError.self) {
            _ = try DICOMWriter.write(pixelData: [UInt8](repeating: 0, count: 8), module: module)
        }
    }

    // MARK: - Encapsulation: codec ↔ container join (the "two good halves")

    @Test("Lossless JPEG encapsulated in DICOM round-trips bit-exactly end to end")
    func encapsulatedLosslessRoundTrip() throws {
        // Real grayscale gradient, 8×8, 16-bit (12-bit valued).
        let w = 8, h = 8
        var samples = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { samples[y * w + x] = UInt16((x * 256 + y * 13) & 0x0FFF) } }
        var bytes = [UInt8](); for s in samples { bytes.append(UInt8(s & 0xFF)); bytes.append(UInt8(s >> 8)) }

        // 1) Encode losslessly with the JLISwift codec.
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint16,
                               colorModel: .grayscale, data: bytes)
        var cfg = JLIEncoderConfiguration(lossless: true)
        cfg.losslessPrecision = 12
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)

        // 2) Wrap the JPEG stream as an encapsulated DICOM (JPEG Lossless SV1).
        let module = DICOMWriter.PixelModule(
            rows: h, columns: w, bitsAllocated: 16, bitsStored: 12, highBit: 11,
            photometricInterpretation: "MONOCHROME2", modality: "OT")
        let file = try DICOMWriter.writeEncapsulatedJPEG(
            jpegStream: jpeg, module: module,
            transferSyntax: DICOMWriter.jpegLosslessSV1)

        // 3) Read the DICOM back; the reader extracts the compressed stream.
        let dicom = try DICOMReader.read(file)
        #expect(dicom.isEncapsulated == true)
        #expect(dicom.width == w && dicom.height == h)
        #expect(dicom.transferSyntax == DICOMWriter.jpegLosslessSV1)

        // 4) JPEG-decode the extracted stream and verify bit-exact reconstruction.
        let decoded = try JLIDecoder().decode(from: dicom.pixelData)
        #expect(decoded.data == bytes, "encapsulated lossless DICOM must reconstruct pixels exactly")
    }

    @Test("A multi-fragment encapsulated stream is concatenated by the reader")
    func multiFragmentConcatenation() throws {
        // Build a real lossless JPEG, split it across TWO fragments, hand-frame an
        // encapsulated DICOM, and confirm the reader rejoins them so the codec can
        // still decode the original stream bit-exactly.
        let w = 8, h = 8
        var bytes = [UInt8](); for i in 0..<(w * h) { bytes.append(UInt8(i & 0xFF)); bytes.append(0) }
        let img = try JLIImage(width: w, height: h, pixelFormat: .uint16,
                               colorModel: .grayscale, data: bytes)
        var cfg = JLIEncoderConfiguration(lossless: true); cfg.losslessPrecision = 12
        let jpeg = try JLIEncoder().encode(img, configuration: cfg)

        // Build the file meta + dataset, then an encapsulated PixelData with an
        // empty Basic Offset Table and two even-length fragments. The two fragment
        // payloads concatenated (without padding) must equal the original stream,
        // so we split on an even boundary and the halves carry no odd padding.
        let half = (jpeg.count / 2) & ~1
        let f1 = Array(jpeg[0..<half]); let f2 = Array(jpeg[half...])
        #expect((f1.count % 2 == 0) && (f2.count % 2 == 0))   // no padding alters bytes

        var meta = [UInt8]()
        func mtag(_ b: inout [UInt8], _ g: UInt16, _ e: UInt16) {
            b += [UInt8(g & 0xFF), UInt8(g >> 8), UInt8(e & 0xFF), UInt8(e >> 8)]
        }
        func ui(_ b: inout [UInt8], _ g: UInt16, _ e: UInt16, _ s: String) {
            var v = Array(s.utf8); if v.count % 2 != 0 { v.append(0) }
            mtag(&b, g, e); b += Array("UI".utf8); b += [UInt8(v.count & 0xFF), UInt8(v.count >> 8)]; b += v
        }
        ui(&meta, 0x0002, 0x0010, DICOMWriter.jpegLosslessSV1)   // Transfer Syntax UID

        var ds = [UInt8]()
        // Minimal pixel module (Explicit VR LE) — enough for the reader.
        func us(_ b: inout [UInt8], _ g: UInt16, _ e: UInt16, _ v: UInt16) {
            mtag(&b, g, e); b += Array("US".utf8); b += [2, 0, UInt8(v & 0xFF), UInt8(v >> 8)]
        }
        us(&ds, 0x0028, 0x0002, 1)                 // SamplesPerPixel
        mtag(&ds, 0x0028, 0x0004); ds += Array("CS".utf8); ds += [12, 0]; ds += Array("MONOCHROME2\0".utf8)
        us(&ds, 0x0028, 0x0010, UInt16(h))         // Rows
        us(&ds, 0x0028, 0x0011, UInt16(w))         // Columns
        us(&ds, 0x0028, 0x0100, 16)                // BitsAllocated
        us(&ds, 0x0028, 0x0101, 12)                // BitsStored
        us(&ds, 0x0028, 0x0102, 11)                // HighBit
        us(&ds, 0x0028, 0x0103, 0)                 // PixelRepresentation
        // Encapsulated PixelData (OB, undefined length).
        func u32(_ b: inout [UInt8], _ v: Int) {
            let u = UInt32(v); b += [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 24) & 0xFF)]
        }
        mtag(&ds, 0x7FE0, 0x0010); ds += Array("OB".utf8); ds += [0, 0]; u32(&ds, 0xFFFFFFFF)
        mtag(&ds, 0xFFFE, 0xE000); u32(&ds, 0)                 // empty BOT
        mtag(&ds, 0xFFFE, 0xE000); u32(&ds, f1.count); ds += f1
        mtag(&ds, 0xFFFE, 0xE000); u32(&ds, f2.count); ds += f2
        mtag(&ds, 0xFFFE, 0xE0DD); u32(&ds, 0)                 // Sequence Delimitation

        var file = [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)
        // File Meta Group Length.
        mtag(&file, 0x0002, 0x0000); file += Array("UL".utf8); file += [4, 0]; u32(&file, meta.count)
        file += meta; file += ds

        let dicom = try DICOMReader.read(file)
        #expect(dicom.isEncapsulated == true)
        #expect(dicom.pixelData == jpeg, "two fragments must rejoin into the original stream")
        let decoded = try JLIDecoder().decode(from: dicom.pixelData)
        #expect(decoded.data == bytes)
    }

    // MARK: - Multi-frame (WS-M2)

    /// Distinct content per frame so a frame-mapping bug is visible.
    private func framePixels(_ w: Int, _ h: Int, frame: Int) -> [UInt8] {
        var d = [UInt8]()
        for i in 0..<(w * h) { let v = UInt16((i * 7 + frame * 211) & 0x0FFF); d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        return d
    }

    @Test("Encapsulated multi-frame: each frame round-trips bit-exactly via the BOT")
    func encapsulatedMultiFrame() throws {
        let w = 8, h = 8, frames = 5
        var sources = [[UInt8]]()
        var jpegs = [[UInt8]]()
        for f in 0..<frames {
            let src = framePixels(w, h, frame: f)
            sources.append(src)
            let img = try JLIImage(width: w, height: h, pixelFormat: .uint16, colorModel: .grayscale, data: src)
            var cfg = JLIEncoderConfiguration(lossless: true); cfg.losslessPrecision = 12
            jpegs.append(try JLIEncoder().encode(img, configuration: cfg))
        }
        let module = DICOMWriter.PixelModule(rows: h, columns: w, bitsAllocated: 16,
                                             bitsStored: 12, highBit: 11)
        let file = try DICOMWriter.writeEncapsulatedFrames(
            jpegFrames: jpegs, module: module, transferSyntax: DICOMWriter.jpegLosslessSV1)

        let dicom = try DICOMReader.read(file)
        #expect(dicom.isEncapsulated)
        #expect(dicom.numberOfFrames == frames)
        #expect(dicom.encapsulatedFrameStreams.count == frames)
        // Frame 0 is exposed as pixelData; every frame decodes to its own pixels.
        for f in 0..<frames {
            let stream = try #require(dicom.frame(f))
            let dec = try JLIDecoder().decode(from: stream)
            #expect(dec.data == sources[f], "frame \(f) not bit-exact")
        }
        #expect(dicom.frame(frames) == nil, "out-of-range frame must be nil")
    }

    @Test("Native multi-frame: frame 0 exposed, all frames recoverable")
    func nativeMultiFrame() throws {
        let w = 6, h = 4, frames = 4
        var all = [UInt8]()
        var sources = [[UInt8]]()
        for f in 0..<frames { let s = framePixels(w, h, frame: f); sources.append(s); all += s }
        let module = DICOMWriter.PixelModule(rows: h, columns: w, bitsAllocated: 16,
                                             bitsStored: 12, highBit: 11, numberOfFrames: frames)
        let file = try DICOMWriter.write(pixelData: all, module: module)

        let dicom = try DICOMReader.read(file)
        #expect(dicom.numberOfFrames == frames)
        #expect(dicom.isEncapsulated == false)
        // pixelData is bounded to frame 0 (not the whole multi-frame blob).
        #expect(dicom.pixelData == sources[0], "native pixelData must be frame 0 only")
        for f in 0..<frames {
            #expect(dicom.frame(f) == sources[f], "native frame \(f) wrong")
        }
        #expect(dicom.frame(frames) == nil)
    }

    @Test("A lying NumberOfFrames is clamped to the native data actually present")
    func lyingFrameCountClamped() throws {
        // Write a valid 2-frame native file, then re-read it after overwriting the
        // NumberOfFrames value in place to claim 9 frames — the reader must clamp
        // the exposed frame count to the 2 frames the buffer actually holds.
        let w = 4, h = 4, frames = 2
        var all = [UInt8]()
        for f in 0..<frames { all += framePixels(w, h, frame: f) }
        let module = DICOMWriter.PixelModule(rows: h, columns: w, bitsAllocated: 16,
                                             bitsStored: 12, highBit: 11, numberOfFrames: frames)
        var file = try DICOMWriter.write(pixelData: all, module: module)

        // Find the IS "2" value of NumberOfFrames (0028,0008) and bump it to "9".
        // Tag bytes little-endian: 28 00 08 00, then VR "IS", then 2-byte length.
        var i = 132
        while i + 8 < file.count {
            if file[i] == 0x28 && file[i+1] == 0x00 && file[i+2] == 0x08 && file[i+3] == 0x00
                && file[i+4] == 0x49 && file[i+5] == 0x53 {     // "IS"
                let len = Int(file[i+6]) | (Int(file[i+7]) << 8)
                if len >= 1 { file[i + 8] = 0x39 }              // ASCII '9'
                break
            }
            i += 1
        }

        let dicom = try DICOMReader.read(file)
        #expect(dicom.numberOfFrames == frames, "frame count must clamp to the 2 frames present, not 9")
        #expect(dicom.frame(0) == framePixels(w, h, frame: 0))
        #expect(dicom.frame(1) == framePixels(w, h, frame: 1))
        #expect(dicom.frame(2) == nil)
    }

    @Test("decodeFramesConcurrently equals the serial per-frame decode, in order")
    func concurrentFrameDecodeMatchesSerial() throws {
        // Encapsulated cine: every frame is an independent lossless JPEG, so the
        // concurrent decode must produce exactly the serial result, frame order
        // preserved. Run 3× as a race detector.
        let w = 16, h = 16, frames = 12
        var jpegs = [[UInt8]]()
        var sources = [[UInt8]]()
        for f in 0..<frames {
            let src = framePixels(w, h, frame: f)
            sources.append(src)
            let img = try JLIImage(width: w, height: h, pixelFormat: .uint16,
                                   colorModel: .grayscale, data: src)
            var cfg = JLIEncoderConfiguration(lossless: true); cfg.losslessPrecision = 12
            jpegs.append(try JLIEncoder().encode(img, configuration: cfg))
        }
        let module = DICOMWriter.PixelModule(rows: h, columns: w, bitsAllocated: 16,
                                             bitsStored: 12, highBit: 11)
        let file = try DICOMWriter.writeEncapsulatedFrames(
            jpegFrames: jpegs, module: module, transferSyntax: DICOMWriter.jpegLosslessSV1)
        let dicom = try DICOMReader.read(file)

        let serial: [[UInt8]] = try (0..<frames).map {
            try JLIDecoder().decode(from: try #require(dicom.frame($0))).data
        }
        for _ in 0..<3 {
            let parallel = try dicom.decodeFramesConcurrently { try JLIDecoder().decode(from: $0).data }
            #expect(parallel == serial, "concurrent decode differs from serial")
        }
        #expect(serial == sources, "decoded frames must be bit-exact")

        // Native multi-frame: payloads are raw slices; identity passthrough must
        // come back in frame order.
        var all = [UInt8]()
        for f in 0..<4 { all += framePixels(w, h, frame: f) }
        let nativeModule = DICOMWriter.PixelModule(rows: h, columns: w, bitsAllocated: 16,
                                                   bitsStored: 12, highBit: 11, numberOfFrames: 4)
        let nativeDicom = try DICOMReader.read(try DICOMWriter.write(pixelData: all, module: nativeModule))
        let nativeFrames = try nativeDicom.decodeFramesConcurrently { $0 }
        #expect(nativeFrames == (0..<4).map { framePixels(w, h, frame: $0) })

        // Error propagation: a throwing decode surfaces, not crashes.
        #expect(throws: DICOMError.self) {
            _ = try dicom.decodeFramesConcurrently { _ -> [UInt8] in throw DICOMError.invalidPixelData }
        }
    }
}
