// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Result of parsing a DICOM file into something usable for JPEG benchmarking.
///
/// Most clinical modalities (CT, MR, DX, MG) store 16-bit grayscale with a
/// window/level pair. This struct keeps the raw pixels at their native bit
/// depth plus enough metadata to render them as 8-bit for the codec test.
struct DICOMImage {
    let width: Int
    let height: Int
    /// 1 for monochrome, 3 for RGB.
    let samplesPerPixel: Int
    /// 8 or 16 (we ignore the rare 12-bit packed case).
    let bitsAllocated: Int
    /// Effective dynamic range — `bitsStored ≤ bitsAllocated`.
    let bitsStored: Int
    /// 0 = unsigned, 1 = signed two's-complement.
    let pixelRepresentation: Int
    /// `MONOCHROME1` (zero = white, inverted), `MONOCHROME2` (zero = black,
    /// the usual case), `RGB`, `YBR_FULL_422`, etc.
    let photometric: String
    /// Window center (DICOM tag (0028,1050)) if present. Used to render
    /// signed/wide-range pixels into 8-bit for the benchmark.
    let windowCenter: Double?
    /// Window width (DICOM tag (0028,1051)) if present.
    let windowWidth: Double?
    /// Raw pixel bytes exactly as they appeared in (7FE0,0010).
    let pixelData: [UInt8]
    /// Transfer Syntax UID — recorded so we can skip files we can't decode.
    let transferSyntax: String

    /// Renders the image as 8-bit interleaved RGB (gray replicated to 3 channels)
    /// so it fits the existing `Codec` API. Uses window/level when present,
    /// otherwise auto-min/max across the pixel data.
    ///
    /// `MONOCHROME1` is inverted (DICOM spec — 0 = white). For signed
    /// 16-bit pixels we interpret as Int16 first, then map [low, high] → [0, 255].
    func toRGB8() -> [UInt8] {
        let pixelCount = width * height * samplesPerPixel
        if samplesPerPixel == 3 && bitsAllocated == 8 {
            // Already 8-bit RGB — just copy.
            var out = [UInt8](repeating: 0, count: width * height * 3)
            let n = min(pixelCount, pixelData.count)
            for i in 0..<n { out[i] = pixelData[i] }
            return out
        }

        // Decode to a flat Double array so windowing is uniform.
        let intensities = decodeIntensities()
        let (low, high) = windowRange(intensities: intensities)
        let span = max(1e-9, high - low)
        let invert = (photometric == "MONOCHROME1")

        var gray = [UInt8](repeating: 0, count: width * height)
        for i in 0..<min(gray.count, intensities.count) {
            var v = (intensities[i] - low) / span
            if v < 0 { v = 0 } else if v > 1 { v = 1 }
            if invert { v = 1 - v }
            gray[i] = UInt8(v * 255.0 + 0.5)
        }

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<gray.count {
            let g = gray[i]
            rgb[i * 3]     = g
            rgb[i * 3 + 1] = g
            rgb[i * 3 + 2] = g
        }
        return rgb
    }

    /// Renders the image as 12-bit grayscale (samples 0–4095) for the
    /// high-precision bench. Uses the same window/level as ``toRGB8()`` so the
    /// 8-bit and 12-bit views show the same clinical content — just at 16× the
    /// tonal resolution. `MONOCHROME1` is inverted as in the 8-bit path.
    func toGray12() -> [UInt16] {
        let intensities = decodeIntensities()
        let (low, high) = windowRange(intensities: intensities)
        let span = max(1e-9, high - low)
        let invert = (photometric == "MONOCHROME1")
        var gray = [UInt16](repeating: 0, count: width * height)
        for i in 0..<min(gray.count, intensities.count) {
            var v = (intensities[i] - low) / span
            if v < 0 { v = 0 } else if v > 1 { v = 1 }
            if invert { v = 1 - v }
            gray[i] = UInt16(v * 4095.0 + 0.5)
        }
        return gray
    }

    /// Native intensities as Double, honoring `bitsAllocated` + `pixelRepresentation`.
    private func decodeIntensities() -> [Double] {
        let pixelCount = width * height
        var out = [Double](repeating: 0, count: pixelCount)
        let signed = pixelRepresentation == 1

        if bitsAllocated == 8 {
            let n = min(pixelCount, pixelData.count)
            if signed {
                for i in 0..<n { out[i] = Double(Int8(bitPattern: pixelData[i])) }
            } else {
                for i in 0..<n { out[i] = Double(pixelData[i]) }
            }
        } else {
            // 16-bit little-endian.
            let n = min(pixelCount, pixelData.count / 2)
            pixelData.withUnsafeBufferPointer { buf in
                let p = buf.baseAddress!
                for i in 0..<n {
                    let lo = UInt16(p[i * 2])
                    let hi = UInt16(p[i * 2 + 1])
                    let u = (hi << 8) | lo
                    out[i] = signed ? Double(Int16(bitPattern: u)) : Double(u)
                }
            }
        }
        return out
    }

    /// Returns the (low, high) intensity range for windowing. Uses (WindowCenter,
    /// WindowWidth) if the DICOM provided them; otherwise scans the array.
    private func windowRange(intensities: [Double]) -> (Double, Double) {
        if let wc = windowCenter, let ww = windowWidth, ww > 0 {
            return (wc - ww / 2, wc + ww / 2)
        }
        // Fall back to actual min/max.
        var lo = Double.infinity, hi = -Double.infinity
        for v in intensities {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        if lo == hi { return (lo - 1, hi + 1) }
        return (lo, hi)
    }
}

enum DICOMError: Error, CustomStringConvertible {
    case notDICOM
    case truncated
    case unsupportedTransferSyntax(String)
    case missingPixelData
    case invalidGeometry

    var description: String {
        switch self {
        case .notDICOM: return "not a DICOM file (missing DICM magic)"
        case .truncated: return "DICOM file truncated"
        case .unsupportedTransferSyntax(let ts):
            return "unsupported transfer syntax: \(ts) (only uncompressed Implicit/Explicit VR LE)"
        case .missingPixelData: return "missing PixelData element (7FE0,0010)"
        case .invalidGeometry: return "invalid Rows/Columns/Bits"
        }
    }
}

/// Minimal DICOM parser — handles the two uncompressed Little Endian transfer
/// syntaxes (Implicit VR `1.2.840.10008.1.2` and Explicit VR `1.2.840.10008.1.2.1`).
/// These cover essentially all uncompressed clinical CT/MR/DX/MG. Compressed
/// syntaxes (JPEG/JPEG-LS/J2K embedded in DICOM, RLE) throw — the bench corpus
/// loader catches and skips those files.
enum DICOMReader {

    /// Group/element pair packed into a UInt32 (group << 16 | element).
    typealias Tag = UInt32

    @inline(__always)
    static func tag(_ group: UInt16, _ element: UInt16) -> Tag {
        (UInt32(group) << 16) | UInt32(element)
    }

    // The handful of tags we actually look up.
    static let tagRows                  = tag(0x0028, 0x0010)
    static let tagColumns               = tag(0x0028, 0x0011)
    static let tagBitsAllocated         = tag(0x0028, 0x0100)
    static let tagBitsStored            = tag(0x0028, 0x0101)
    static let tagPixelRepresentation   = tag(0x0028, 0x0103)
    static let tagSamplesPerPixel       = tag(0x0028, 0x0002)
    static let tagPhotometric           = tag(0x0028, 0x0004)
    static let tagWindowCenter          = tag(0x0028, 0x1050)
    static let tagWindowWidth           = tag(0x0028, 0x1051)
    static let tagPixelData             = tag(0x7FE0, 0x0010)
    static let tagTransferSyntax        = tag(0x0002, 0x0010)
    static let tagItem                  = tag(0xFFFE, 0xE000)
    static let tagSequenceDelim         = tag(0xFFFE, 0xE0DD)

    static func read(_ data: [UInt8]) throws -> DICOMImage {
        guard data.count >= 132 else { throw DICOMError.truncated }
        // DICM magic at byte 128 (after 128-byte preamble).
        guard data[128] == 0x44, data[129] == 0x49,
              data[130] == 0x43, data[131] == 0x4D else {
            throw DICOMError.notDICOM
        }

        // File Meta Information group (0002) is always Explicit VR Little Endian
        // regardless of the dataset's declared Transfer Syntax. Walk it once to
        // find the Transfer Syntax UID and the start of the dataset proper.
        var transferSyntax = ""
        var datasetStart = 132
        var c = 132
        while c < data.count {
            let (group, element, _, valueRange, next) = try readExplicitVR(data, at: c)
            if group != 0x0002 {
                datasetStart = c
                break
            }
            if tag(group, element) == tagTransferSyntax {
                transferSyntax = readUIString(data, range: valueRange)
            }
            c = next
            datasetStart = next
        }

        // Validate transfer syntax. We accept only the two uncompressed LE syntaxes.
        let isImplicit: Bool
        switch transferSyntax {
        case "1.2.840.10008.1.2":   isImplicit = true   // Implicit VR Little Endian
        case "1.2.840.10008.1.2.1": isImplicit = false  // Explicit VR Little Endian
        default:
            throw DICOMError.unsupportedTransferSyntax(transferSyntax)
        }

        // Walk the dataset, collecting just the tags we care about.
        var rows = 0, cols = 0, bitsAllocated = 0, bitsStored = 0
        var pixelRep = 0, samplesPerPixel = 1
        var photometric = "MONOCHROME2"
        var windowCenter: Double? = nil
        var windowWidth: Double? = nil
        var pixelData: [UInt8] = []

        var p = datasetStart
        while p < data.count {
            let parsed: (group: UInt16, element: UInt16, vr: String?, valueRange: Range<Int>, next: Int)
            if isImplicit {
                parsed = try readImplicitVR(data, at: p)
            } else {
                let r = try readExplicitVR(data, at: p)
                parsed = (r.group, r.element, r.vr, r.valueRange, r.next)
            }
            let t = tag(parsed.group, parsed.element)

            switch t {
            case tagRows:                rows = Int(readUInt16(data, range: parsed.valueRange))
            case tagColumns:             cols = Int(readUInt16(data, range: parsed.valueRange))
            case tagBitsAllocated:       bitsAllocated = Int(readUInt16(data, range: parsed.valueRange))
            case tagBitsStored:          bitsStored = Int(readUInt16(data, range: parsed.valueRange))
            case tagPixelRepresentation: pixelRep = Int(readUInt16(data, range: parsed.valueRange))
            case tagSamplesPerPixel:     samplesPerPixel = Int(readUInt16(data, range: parsed.valueRange))
            case tagPhotometric:         photometric = readString(data, range: parsed.valueRange)
            case tagWindowCenter:        windowCenter = readDecimalString(data, range: parsed.valueRange)
            case tagWindowWidth:         windowWidth = readDecimalString(data, range: parsed.valueRange)
            case tagPixelData:
                // For uncompressed transfer syntaxes the pixel data is a single
                // contiguous chunk in the value field.
                pixelData = Array(data[parsed.valueRange])
            default: break
            }

            p = parsed.next
            if pixelData.isEmpty == false && t == tagPixelData { break }
        }

        guard rows > 0, cols > 0, bitsAllocated > 0 else { throw DICOMError.invalidGeometry }
        guard !pixelData.isEmpty else { throw DICOMError.missingPixelData }

        return DICOMImage(
            width: cols, height: rows,
            samplesPerPixel: samplesPerPixel,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored == 0 ? bitsAllocated : bitsStored,
            pixelRepresentation: pixelRep,
            photometric: photometric.trimmingCharacters(in: .whitespacesAndNewlines),
            windowCenter: windowCenter, windowWidth: windowWidth,
            pixelData: pixelData,
            transferSyntax: transferSyntax
        )
    }

    // MARK: - Element readers

    /// Explicit VR Little Endian element header. Returns the tag, the (possibly nil)
    /// VR string, the byte range of the value field, and the cursor advance.
    private static func readExplicitVR(
        _ data: [UInt8], at offset: Int
    ) throws -> (group: UInt16, element: UInt16, vr: String?, valueRange: Range<Int>, next: Int) {
        guard offset + 8 <= data.count else { throw DICOMError.truncated }
        let group   = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        let element = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
        // Item/SequenceDelim use Implicit-style 4-byte length even in Explicit VR.
        if group == 0xFFFE {
            let length = UInt32(data[offset + 4])
                | (UInt32(data[offset + 5]) << 8)
                | (UInt32(data[offset + 6]) << 16)
                | (UInt32(data[offset + 7]) << 24)
            let valStart = offset + 8
            let valEnd = length == 0xFFFFFFFF ? valStart : valStart + Int(length)
            return (group, element, nil, valStart..<valEnd, valEnd)
        }

        let vr = String(bytes: [data[offset + 4], data[offset + 5]], encoding: .ascii) ?? "  "

        // OB/OW/OF/OD/SQ/UN/UT use a 2-byte reserved field then 4-byte length.
        let bigLengthVRs: Set<String> = ["OB", "OW", "OF", "OD", "SQ", "UN", "UT"]
        if bigLengthVRs.contains(vr) {
            guard offset + 12 <= data.count else { throw DICOMError.truncated }
            let length = UInt32(data[offset + 8])
                | (UInt32(data[offset + 9]) << 8)
                | (UInt32(data[offset + 10]) << 16)
                | (UInt32(data[offset + 11]) << 24)
            let valStart = offset + 12
            if length == 0xFFFFFFFF {
                // Undefined length (sequence/encapsulated PixelData). For uncompressed
                // syntaxes we only see this on SQ — bail to the next element via item walk.
                // We treat the value range as empty and skip — calling code uses tag to
                // decide whether it matters.
                return (group, element, vr, valStart..<valStart, valStart)
            }
            let valEnd = valStart + Int(length)
            guard valEnd <= data.count else { throw DICOMError.truncated }
            return (group, element, vr, valStart..<valEnd, valEnd)
        } else {
            // 2-byte length follows VR.
            let length = UInt16(data[offset + 6]) | (UInt16(data[offset + 7]) << 8)
            let valStart = offset + 8
            let valEnd = valStart + Int(length)
            guard valEnd <= data.count else { throw DICOMError.truncated }
            return (group, element, vr, valStart..<valEnd, valEnd)
        }
    }

    /// Implicit VR Little Endian element header.
    private static func readImplicitVR(
        _ data: [UInt8], at offset: Int
    ) throws -> (group: UInt16, element: UInt16, vr: String?, valueRange: Range<Int>, next: Int) {
        guard offset + 8 <= data.count else { throw DICOMError.truncated }
        let group   = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        let element = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
        let length = UInt32(data[offset + 4])
            | (UInt32(data[offset + 5]) << 8)
            | (UInt32(data[offset + 6]) << 16)
            | (UInt32(data[offset + 7]) << 24)
        let valStart = offset + 8
        if length == 0xFFFFFFFF {
            // Undefined length — treat as empty value and continue at valStart so
            // the next element is parsed at the items. Our test corpus shouldn't
            // hit this for uncompressed pixel data.
            return (group, element, nil, valStart..<valStart, valStart)
        }
        let valEnd = valStart + Int(length)
        guard valEnd <= data.count else { throw DICOMError.truncated }
        return (group, element, nil, valStart..<valEnd, valEnd)
    }

    private static func readTag(_ data: [UInt8], at offset: Int) -> Tag {
        let group = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
        let element = UInt32(data[offset + 2]) | (UInt32(data[offset + 3]) << 8)
        return (group << 16) | element
    }

    // MARK: - Value readers

    private static func readUInt16(_ data: [UInt8], range: Range<Int>) -> UInt16 {
        guard range.count >= 2 else { return 0 }
        return UInt16(data[range.lowerBound]) | (UInt16(data[range.lowerBound + 1]) << 8)
    }

    private static func readString(_ data: [UInt8], range: Range<Int>) -> String {
        let bytes = Array(data[range])
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readUIString(_ data: [UInt8], range: Range<Int>) -> String {
        // UI = Unique Identifier — ASCII digits and dots, may be padded with 0x00.
        var bytes = Array(data[range])
        while let last = bytes.last, last == 0x00 || last == 0x20 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readDecimalString(_ data: [UInt8], range: Range<Int>) -> Double? {
        let s = readString(data, range: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Multi-value strings use "\" as separator (e.g. "40\80"). Take the first.
        let first = s.split(separator: "\\").first.map(String.init) ?? s
        return Double(first.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
