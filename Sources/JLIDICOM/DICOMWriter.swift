// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Writes a minimal but conformant DICOM Part-10 file (Explicit VR Little
/// Endian) from raw pixel data + the pixel-module attributes. This is the
/// counterpart to ``DICOMReader``: `DICOMReader.read(DICOMWriter.write(...))`
/// round-trips the geometry, bit depth, signedness, photometric interpretation
/// and pixel bytes exactly.
///
/// Scope: native (uncompressed) Explicit VR Little Endian for the standard
/// pixel module. Encapsulated/compressed pixel data is produced by
/// ``DICOMWriter/writeEncapsulatedJPEG(...)`` instead. A handful of identifying
/// UIDs (SOP Instance, Study/Series) can be supplied; sensible placeholders are
/// generated when omitted so the file is structurally valid.
public enum DICOMWriter {

    /// The pixel-module description for a native (uncompressed) image.
    public struct PixelModule: Sendable {
        public var rows: Int
        public var columns: Int
        public var bitsAllocated: Int          // 8 or 16
        public var bitsStored: Int             // ≤ bitsAllocated
        public var highBit: Int                // normally bitsStored − 1
        public var pixelRepresentation: Int    // 0 unsigned, 1 signed
        public var samplesPerPixel: Int        // 1 (mono) or 3 (RGB)
        public var planarConfiguration: Int    // 0 interleaved, 1 planar (color only)
        public var photometricInterpretation: String
        public var rescaleSlope: Double?
        public var rescaleIntercept: Double?
        public var windowCenter: Double?
        public var windowWidth: Double?
        public var modality: String?
        public var numberOfFrames: Int        // ≥ 1; emitted as (0028,0008) when > 1

        public init(
            rows: Int, columns: Int,
            bitsAllocated: Int, bitsStored: Int, highBit: Int,
            pixelRepresentation: Int = 0,
            samplesPerPixel: Int = 1, planarConfiguration: Int = 0,
            photometricInterpretation: String = "MONOCHROME2",
            rescaleSlope: Double? = nil, rescaleIntercept: Double? = nil,
            windowCenter: Double? = nil, windowWidth: Double? = nil,
            modality: String? = nil, numberOfFrames: Int = 1
        ) {
            self.rows = rows; self.columns = columns
            self.bitsAllocated = bitsAllocated; self.bitsStored = bitsStored; self.highBit = highBit
            self.pixelRepresentation = pixelRepresentation
            self.samplesPerPixel = samplesPerPixel; self.planarConfiguration = planarConfiguration
            self.photometricInterpretation = photometricInterpretation
            self.rescaleSlope = rescaleSlope; self.rescaleIntercept = rescaleIntercept
            self.windowCenter = windowCenter; self.windowWidth = windowWidth
            self.modality = modality; self.numberOfFrames = max(1, numberOfFrames)
        }
    }

    public enum WriteError: Error, CustomStringConvertible {
        case invalidPixelModule(String)
        case pixelDataSizeMismatch(expected: Int, actual: Int)

        public var description: String {
            switch self {
            case .invalidPixelModule(let m): return "invalid pixel module: \(m)"
            case .pixelDataSizeMismatch(let e, let a):
                return "pixel data size mismatch: expected \(e) bytes, got \(a)"
            }
        }
    }

    /// Secondary Capture SOP Class — the right generic class for pixel data we
    /// synthesise rather than acquire from a modality.
    static let secondaryCaptureSOPClass = "1.2.840.10008.5.1.4.1.1.7"
    static let explicitVRLittleEndian   = "1.2.840.10008.1.2.1"
    static let jpegLosslessSV1          = "1.2.840.10008.1.2.4.70"
    static let jpegBaseline             = "1.2.840.10008.1.2.4.50"

    /// Writes a native (uncompressed) Explicit-VR-LE DICOM file.
    ///
    /// - Parameters:
    ///   - pixelData: raw pixel bytes, little-endian for 16-bit, exactly
    ///     `rows*columns*samplesPerPixel*ceil(bitsAllocated/8)` long.
    ///   - module: the pixel-module attributes.
    ///   - sopInstanceUID / studyUID / seriesUID: identifiers; generated when nil.
    public static func write(
        pixelData: [UInt8], module: PixelModule,
        sopInstanceUID: String? = nil, studyUID: String? = nil, seriesUID: String? = nil
    ) throws -> [UInt8] {
        try validate(module: module, pixelByteCount: pixelData.count)

        let sop = sopInstanceUID ?? generatedUID()
        let study = studyUID ?? generatedUID()
        let series = seriesUID ?? generatedUID()

        // File Meta Information (group 0002) — always Explicit VR LE.
        var meta = Dataset()
        meta.ui(0x0002, 0x0002, secondaryCaptureSOPClass)        // Media Storage SOP Class UID
        meta.ui(0x0002, 0x0003, sop)                             // Media Storage SOP Instance UID
        meta.ui(0x0002, 0x0010, explicitVRLittleEndian)          // Transfer Syntax UID
        meta.ui(0x0002, 0x0012, generatedUID())                  // Implementation Class UID

        var ds = Dataset()
        if let m = module.modality { ds.cs(0x0008, 0x0060, m) }
        ds.ui(0x0008, 0x0016, secondaryCaptureSOPClass)          // SOP Class UID
        ds.ui(0x0008, 0x0018, sop)                               // SOP Instance UID
        ds.ui(0x0020, 0x000D, study)                             // Study Instance UID
        ds.ui(0x0020, 0x000E, series)                            // Series Instance UID
        appendPixelModule(into: &ds, module: module)
        ds.pixelData(pixelData)

        return assemble(meta: meta, dataset: ds)
    }

    /// Writes an Explicit-VR-LE DICOM file whose PixelData is an *encapsulated*
    /// JPEG stream (single frame), tagging the transfer syntax so a reader knows
    /// to JPEG-decode it. Use `jpegLosslessSV1` for SOF3 lossless streams
    /// (diagnostic) or `jpegBaseline` for baseline lossy.
    public static func writeEncapsulatedJPEG(
        jpegStream: [UInt8], module: PixelModule, transferSyntax: String,
        sopInstanceUID: String? = nil, studyUID: String? = nil, seriesUID: String? = nil
    ) throws -> [UInt8] {
        try writeEncapsulatedFrames(jpegFrames: [jpegStream], module: module,
                                    transferSyntax: transferSyntax,
                                    sopInstanceUID: sopInstanceUID, studyUID: studyUID, seriesUID: seriesUID)
    }

    /// Writes an encapsulated DICOM with one JPEG stream per frame (a Basic Offset
    /// Table maps frames → fragments). `module.numberOfFrames` is set to the frame
    /// count. Each frame is one fragment.
    public static func writeEncapsulatedFrames(
        jpegFrames: [[UInt8]], module: PixelModule, transferSyntax: String,
        sopInstanceUID: String? = nil, studyUID: String? = nil, seriesUID: String? = nil
    ) throws -> [UInt8] {
        guard !jpegFrames.isEmpty else { throw WriteError.invalidPixelModule("no frames") }
        var m = module
        m.numberOfFrames = jpegFrames.count
        try validate(module: m, pixelByteCount: nil)             // pixel bytes are compressed

        let sop = sopInstanceUID ?? generatedUID()
        var meta = Dataset()
        meta.ui(0x0002, 0x0002, secondaryCaptureSOPClass)
        meta.ui(0x0002, 0x0003, sop)
        meta.ui(0x0002, 0x0010, transferSyntax)
        meta.ui(0x0002, 0x0012, generatedUID())

        var ds = Dataset()
        if let mod = m.modality { ds.cs(0x0008, 0x0060, mod) }
        ds.ui(0x0008, 0x0016, secondaryCaptureSOPClass)
        ds.ui(0x0008, 0x0018, sop)
        ds.ui(0x0020, 0x000D, studyUID ?? generatedUID())
        ds.ui(0x0020, 0x000E, seriesUID ?? generatedUID())
        appendPixelModule(into: &ds, module: m)
        ds.encapsulatedPixelData(jpegFrames)

        return assemble(meta: meta, dataset: ds)
    }

    // MARK: - Validation

    private static func validate(module m: PixelModule, pixelByteCount: Int?) throws {
        guard m.rows > 0, m.columns > 0 else {
            throw WriteError.invalidPixelModule("rows/columns must be positive")
        }
        guard m.bitsAllocated == 8 || m.bitsAllocated == 16 else {
            throw WriteError.invalidPixelModule("bitsAllocated must be 8 or 16")
        }
        guard m.bitsStored >= 1, m.bitsStored <= m.bitsAllocated else {
            throw WriteError.invalidPixelModule("bitsStored must be in 1...bitsAllocated")
        }
        guard m.samplesPerPixel == 1 || m.samplesPerPixel == 3 else {
            throw WriteError.invalidPixelModule("samplesPerPixel must be 1 or 3")
        }
        if let count = pixelByteCount {
            // Native buffer must hold exactly `numberOfFrames` full frames.
            let expected = m.rows * m.columns * m.samplesPerPixel * ((m.bitsAllocated + 7) / 8) * m.numberOfFrames
            guard count == expected else {
                throw WriteError.pixelDataSizeMismatch(expected: expected, actual: count)
            }
        }
    }

    private static func appendPixelModule(into ds: inout Dataset, module m: PixelModule) {
        ds.us(0x0028, 0x0002, UInt16(m.samplesPerPixel))
        ds.cs(0x0028, 0x0004, m.photometricInterpretation)
        if m.samplesPerPixel == 3 { ds.us(0x0028, 0x0006, UInt16(m.planarConfiguration)) }
        if m.numberOfFrames > 1 { ds.integerString(0x0028, 0x0008, m.numberOfFrames) }
        ds.us(0x0028, 0x0010, UInt16(m.rows))
        ds.us(0x0028, 0x0011, UInt16(m.columns))
        ds.us(0x0028, 0x0100, UInt16(m.bitsAllocated))
        ds.us(0x0028, 0x0101, UInt16(m.bitsStored))
        ds.us(0x0028, 0x0102, UInt16(m.highBit))
        ds.us(0x0028, 0x0103, UInt16(m.pixelRepresentation))
        if let s = m.rescaleSlope { ds.ds(0x0028, 0x1053, s) }
        if let i = m.rescaleIntercept { ds.ds(0x0028, 0x1052, i) }
        if let c = m.windowCenter { ds.ds(0x0028, 0x1050, c) }
        if let w = m.windowWidth { ds.ds(0x0028, 0x1051, w) }
    }

    // MARK: - File assembly

    private static func assemble(meta: Dataset, dataset: Dataset) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 128)              // preamble
        // One up-front reservation so the (pixel-payload-sized) dataset append
        // is a single copy rather than repeated growth reallocations.
        out.reserveCapacity(128 + 4 + 16 + meta.bytes.count + dataset.bytes.count)
        out += Array("DICM".utf8)
        // File Meta Information Group Length (0002,0000) UL = byte length of the
        // rest of group 0002, which must precede the meta elements.
        var groupLen = Dataset()
        groupLen.ul(0x0002, 0x0000, UInt32(meta.bytes.count))
        out += groupLen.bytes
        out += meta.bytes
        out += dataset.bytes
        return out
    }

    // MARK: - UID generation

    /// A syntactically-valid (if non-registered) UID under the DICOM example
    /// root 1.2.826.0.1.3680043.* with a deterministic-free numeric suffix built
    /// from a counter — adequate for files we synthesise. Not globally unique;
    /// callers that need registered UIDs should pass their own.
    private static let counter = UIDCounter()
    static func generatedUID() -> String {
        "1.2.826.0.1.3680043.2.1143.\(counter.next())"
    }

    /// Thread-safe monotonic counter for placeholder UID suffixes.
    final class UIDCounter: @unchecked Sendable {
        private var value: UInt64 = 1
        private let lock = NSLock()
        func next() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            value &+= 1
            return value
        }
    }
}

/// Builds an Explicit-VR-Little-Endian element stream.
private struct Dataset {
    var bytes: [UInt8] = []

    private mutating func tag(_ g: UInt16, _ e: UInt16) {
        bytes.append(UInt8(g & 0xFF)); bytes.append(UInt8(g >> 8))
        bytes.append(UInt8(e & 0xFF)); bytes.append(UInt8(e >> 8))
    }
    private mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    private mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8((v >> 24) & 0xFF))
    }

    /// Short-form element: 2-byte VR + 2-byte length. Value padded to even length.
    private mutating func short(_ g: UInt16, _ e: UInt16, _ vr: String, _ value: [UInt8]) {
        var v = value
        if v.count % 2 != 0 { v.append(vr == "UI" ? 0x00 : 0x20) }   // UI pads NUL, text pads space
        tag(g, e); bytes += Array(vr.utf8); u16(UInt16(v.count)); bytes += v
    }
    /// Long-form element (OB/OW/etc): VR + 2 reserved + 4-byte length.
    private mutating func long(_ g: UInt16, _ e: UInt16, _ vr: String, _ value: [UInt8]) {
        bytes.reserveCapacity(bytes.count + 12 + value.count)
        tag(g, e); bytes += Array(vr.utf8); u16(0); u32(UInt32(value.count)); bytes += value
    }

    mutating func us(_ g: UInt16, _ e: UInt16, _ v: UInt16) { short(g, e, "US", [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func ul(_ g: UInt16, _ e: UInt16, _ v: UInt32) {
        short(g, e, "UL", [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    mutating func ui(_ g: UInt16, _ e: UInt16, _ s: String) { short(g, e, "UI", Array(s.utf8)) }
    mutating func cs(_ g: UInt16, _ e: UInt16, _ s: String) { short(g, e, "CS", Array(s.utf8)) }
    mutating func ds(_ g: UInt16, _ e: UInt16, _ v: Double) {
        // Decimal String, max 16 chars; trim a trailing ".0" for integers.
        var s = String(v)
        if s.hasSuffix(".0") { s.removeLast(2) }
        short(g, e, "DS", Array(s.utf8))
    }
    mutating func integerString(_ g: UInt16, _ e: UInt16, _ v: Int) { short(g, e, "IS", Array(String(v).utf8)) }

    /// Native PixelData (OW) — 16-bit or byte samples carried verbatim. For
    /// multi-frame, pass all frames concatenated in frame order.
    mutating func pixelData(_ data: [UInt8]) { long(0x7FE0, 0x0010, "OW", data) }

    /// Encapsulated PixelData (OB, undefined length): a Basic Offset Table item
    /// then one fragment per frame, closed by the Sequence Delimitation Item
    /// (DICOM PS3.5 §A.4). Single-frame is one fragment with an empty BOT;
    /// multi-frame writes a populated BOT (offset of each frame's fragment item
    /// relative to the first fragment item) + one fragment per frame.
    mutating func encapsulatedPixelData(_ frames: [[UInt8]]) {
        // Even-padded fragment lengths (per the standard) are computed inline —
        // no re-materialized padded copies of every frame — and the whole
        // structure is reserved up front so each compressed byte is appended once.
        @inline(__always) func paddedCount(_ f: [UInt8]) -> Int { f.count + (f.count & 1) }
        let totalPayload = frames.reduce(0) { $0 + paddedCount($1) }
        bytes.reserveCapacity(bytes.count + 12 + 8 + frames.count * 12 + totalPayload + 8)

        tag(0x7FE0, 0x0010); bytes += Array("OB".utf8); u16(0); u32(0xFFFFFFFF)   // undefined length
        if frames.count <= 1 {
            tag(0xFFFE, 0xE000); u32(0)                                          // empty Basic Offset Table
        } else {
            // Basic Offset Table: 4 bytes per frame, offset of each fragment's
            // item header relative to the start of the first fragment item.
            tag(0xFFFE, 0xE000); u32(UInt32(frames.count * 4))
            var offset: UInt32 = 0
            for f in frames { u32(offset); offset += UInt32(8 + paddedCount(f)) } // 8 = item tag+length
        }
        for f in frames {
            tag(0xFFFE, 0xE000); u32(UInt32(paddedCount(f)))                      // one fragment per frame
            bytes += f
            if f.count % 2 != 0 { bytes.append(0x00) }                            // even-length pad
        }
        tag(0xFFFE, 0xE0DD); u32(0)                                             // Sequence Delimitation
    }
}
