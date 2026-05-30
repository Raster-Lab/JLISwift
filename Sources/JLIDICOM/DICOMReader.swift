// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Result of parsing a DICOM file into something usable for JPEG work.
///
/// Most clinical modalities (CT, MR, DX, MG) store 16-bit grayscale with a
/// window/level pair. This struct keeps the raw pixels at their native bit
/// depth plus enough metadata to render them as 8- or 12-bit for the codec.
public struct DICOMImage: Sendable {
    public let width: Int
    public let height: Int
    /// 1 for monochrome, 3 for RGB.
    public let samplesPerPixel: Int
    /// 8 or 16 (we ignore the rare 12-bit packed case).
    public let bitsAllocated: Int
    /// Effective dynamic range — `bitsStored ≤ bitsAllocated`.
    public let bitsStored: Int
    /// 0 = unsigned, 1 = signed two's-complement.
    public let pixelRepresentation: Int
    /// High bit (DICOM tag (0028,0102)); the position of the most-significant
    /// stored bit. Normally `bitsStored − 1`; used to locate the sign bit when
    /// sign-extending signed data narrower than its container (e.g. 12-bit CT).
    public let highBit: Int
    /// Planar configuration (DICOM tag (0028,0006)) for multi-sample (color)
    /// data: `0` = pixel-interleaved (R₀G₀B₀R₁G₁B₁…), `1` = plane-interleaved
    /// (R₀R₁…G₀G₁…B₀B₁…). Ignored for single-sample grayscale.
    public let planarConfiguration: Int
    /// `MONOCHROME1` (zero = white, inverted), `MONOCHROME2` (zero = black,
    /// the usual case), `RGB`, `YBR_FULL_422`, etc.
    public let photometric: String
    /// Modality (DICOM tag (0008,0060)): `CT`, `MR`, `DX`, `MG`, … or empty when
    /// absent. CT stores Hounsfield units, so named window presets (bone/lung/…)
    /// only make clinical sense there.
    public let modality: String
    /// Window center (DICOM tag (0028,1050)) if present. Used to render
    /// signed/wide-range pixels into 8-bit.
    public let windowCenter: Double?
    /// Window width (DICOM tag (0028,1051)) if present.
    public let windowWidth: Double?
    /// Modality-LUT rescale slope (0028,1053); `1` when absent.
    public let rescaleSlope: Double
    /// Modality-LUT rescale intercept (0028,1052); `0` when absent. CT stores
    /// raw values that become Hounsfield units via `raw·slope + intercept`, and
    /// window center/width are specified in those rescaled units — so this must
    /// be applied before windowing or CT renders as a blown-out white frame.
    public let rescaleIntercept: Double
    /// Raw pixel bytes exactly as they appeared in (7FE0,0010). For an
    /// encapsulated (compressed) image this holds the extracted compressed stream
    /// of the first frame fragment (see ``isEncapsulated``), which the caller
    /// JPEG-decodes; the render helpers below assume *native* (uncompressed) data.
    public let pixelData: [UInt8]
    /// Transfer Syntax UID — recorded so we can skip files we can't decode.
    public let transferSyntax: String
    /// True when ``pixelData`` is a compressed (encapsulated) JPEG stream rather
    /// than native samples. The caller decodes it with the matching codec.
    public var isEncapsulated: Bool = false

    /// Full range of decoded intensities after the Modality LUT — the real-world
    /// min/max (e.g. Hounsfield for CT). Handy as the bounds for an interactive
    /// window/level control. Returns `(0, 255)` for already-RGB photographic DICOM,
    /// where windowing does not apply.
    public func intensityRange() -> (lo: Double, hi: Double) {
        if samplesPerPixel == 3 && bitsAllocated == 8 { return (0, 255) }
        let intensities = decodeIntensities()
        var lo = Double.infinity, hi = -Double.infinity
        for v in intensities {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        if !lo.isFinite || !hi.isFinite { return (0, 255) }
        if lo == hi { return (lo - 1, hi + 1) }
        return (lo, hi)
    }

    /// The window/level to show by default: the file's (WindowCenter, WindowWidth)
    /// when present, otherwise centered on the full intensity range. Both values are
    /// in real-world (post-rescale) units.
    public func windowDefaults() -> (center: Double, width: Double) {
        if let wc = windowCenter, let ww = windowWidth, ww > 0 {
            return (wc, ww)
        }
        let (lo, hi) = intensityRange()
        return ((lo + hi) / 2, max(1, hi - lo))
    }

    /// Renders the image as 8-bit interleaved RGB (gray replicated to 3 channels)
    /// using the given window/level (real-world units): `[center − width/2, center +
    /// width/2]` maps to `[0, 255]`. `MONOCHROME1` is inverted (DICOM spec — 0 =
    /// white). Already-RGB 8-bit photographic DICOM ignores the window and is copied
    /// through unchanged.
    public func render8bit(windowCenter center: Double, windowWidth width: Double) -> [UInt8] {
        let pixelCount = self.width * self.height * samplesPerPixel
        if samplesPerPixel == 3 && bitsAllocated == 8 {
            let px = self.width * self.height
            var out = [UInt8](repeating: 0, count: px * 3)
            let n = min(pixelCount, pixelData.count)
            // De-interleave to pixel-order (R/Y, G/Cb, B/Cr) honoring planar config.
            if planarConfiguration == 1 {
                // Plane-interleaved (C0…C0 C1…C1 C2…C2) → pixel-interleaved.
                for c in 0..<3 {
                    let base = c * px
                    for i in 0..<px where base + i < n {
                        out[i * 3 + c] = pixelData[base + i]
                    }
                }
            } else {
                for i in 0..<n { out[i] = pixelData[i] }
            }
            // YBR (YCbCr) photometric interpretations carry luma/chroma, not RGB —
            // convert in place with the full-range BT.601 inverse. YBR_FULL_422 is
            // the same color math at full resolution here, because an encapsulated
            // JPEG is already chroma-upsampled by the time we see its samples.
            if Self.isYBR(photometric) {
                for i in 0..<px {
                    let (r, g, b) = Self.ybrFullToRGB(
                        y: out[i * 3], cb: out[i * 3 + 1], cr: out[i * 3 + 2])
                    out[i * 3] = r; out[i * 3 + 1] = g; out[i * 3 + 2] = b
                }
            }
            return out
        }
        let intensities = decodeIntensities()
        let low = center - width / 2
        let span = max(1e-9, width)
        let invert = (photometric == "MONOCHROME1")
        var rgb = [UInt8](repeating: 0, count: self.width * self.height * 3)
        for i in 0..<min(self.width * self.height, intensities.count) {
            var v = (intensities[i] - low) / span
            if v < 0 { v = 0 } else if v > 1 { v = 1 }
            if invert { v = 1 - v }
            let g = UInt8(v * 255.0 + 0.5)
            rgb[i * 3]     = g
            rgb[i * 3 + 1] = g
            rgb[i * 3 + 2] = g
        }
        return rgb
    }

    /// Renders the image as 8-bit interleaved RGB using the file's default window
    /// (or auto min/max when none is stored). Convenience over ``render8bit``.
    public func toRGB8() -> [UInt8] {
        let (c, w) = windowDefaults()
        return render8bit(windowCenter: c, windowWidth: w)
    }

    /// Renders the image as 12-bit grayscale (samples 0–4095) using the given
    /// window/level — the 12-bit counterpart to ``render8bit(windowCenter:windowWidth:)``,
    /// so the two views show the same clinical content at 16× the tonal resolution.
    /// `MONOCHROME1` is inverted as in the 8-bit path.
    public func render12bit(windowCenter center: Double, windowWidth width: Double) -> [UInt16] {
        let intensities = decodeIntensities()
        let low = center - width / 2
        let span = max(1e-9, width)
        let invert = (photometric == "MONOCHROME1")
        var gray = [UInt16](repeating: 0, count: self.width * self.height)
        for i in 0..<min(gray.count, intensities.count) {
            var v = (intensities[i] - low) / span
            if v < 0 { v = 0 } else if v > 1 { v = 1 }
            if invert { v = 1 - v }
            gray[i] = UInt16(v * 4095.0 + 0.5)
        }
        return gray
    }

    /// Renders the image as 12-bit grayscale using the file's default window.
    /// Convenience over ``render12bit``.
    public func toGray12() -> [UInt16] {
        let (c, w) = windowDefaults()
        return render12bit(windowCenter: c, windowWidth: w)
    }

    /// Native intensities as Double, honoring `bitsAllocated`, `bitsStored`/
    /// `highBit`, and `pixelRepresentation`. Stored values are masked to
    /// `bitsStored` significant bits (DICOM permits non-significant high bits in
    /// the container) and, when signed, sign-extended from the stored sign bit —
    /// so signed data narrower than its container (e.g. 12-bit CT in a 16-bit
    /// word) is recovered correctly rather than read at the full container width.
    private func decodeIntensities() -> [Double] {
        let pixelCount = width * height
        var out = [Double](repeating: 0, count: pixelCount)
        let signed = pixelRepresentation == 1
        // Effective stored width: bitsStored if sane, else the full container.
        let stored = (bitsStored >= 1 && bitsStored <= bitsAllocated) ? bitsStored : bitsAllocated
        let mask: UInt32 = stored >= 32 ? 0xFFFF_FFFF : (UInt32(1) << UInt32(stored)) - 1
        let signBit: UInt32 = UInt32(1) << UInt32(stored - 1)
        // Two's-complement extension term applied when the sign bit is set.
        let signExtend = ~mask

        @inline(__always)
        func value(_ raw: UInt32) -> Double {
            let m = raw & mask
            if signed && (m & signBit) != 0 {
                return Double(Int32(bitPattern: m | signExtend))
            }
            return Double(m)
        }

        if bitsAllocated == 8 {
            let n = min(pixelCount, pixelData.count)
            for i in 0..<n { out[i] = value(UInt32(pixelData[i])) }
        } else {
            let n = min(pixelCount, pixelData.count / 2)
            pixelData.withUnsafeBufferPointer { buf in
                let p = buf.baseAddress!
                for i in 0..<n {
                    let lo = UInt32(p[i * 2])
                    let hi = UInt32(p[i * 2 + 1])
                    out[i] = value((hi << 8) | lo)
                }
            }
        }
        // Modality LUT: stored value → real-world value (e.g. Hounsfield). Identity
        // when slope/intercept are absent, so 8-bit photographic DICOM is unchanged.
        if rescaleSlope != 1.0 || rescaleIntercept != 0.0 {
            for i in 0..<out.count { out[i] = out[i] * rescaleSlope + rescaleIntercept }
        }
        return out
    }

    /// True for the YCbCr-family photometric interpretations whose samples are
    /// luma/chroma, not RGB, and so need a color transform before display:
    /// `YBR_FULL` and `YBR_FULL_422` (full-range). (`YBR_ICT`/`YBR_RCT` are
    /// JPEG-2000-internal and not produced by this reader; `YBR_PARTIAL_*` —
    /// video-range — is rare in practice and intentionally not auto-converted.)
    static func isYBR(_ photometric: String) -> Bool {
        photometric == "YBR_FULL" || photometric == "YBR_FULL_422"
    }

    /// Full-range (DICOM YBR_FULL) YCbCr → RGB, the inverse of the JFIF/BT.601
    /// forward transform, with 8-bit chroma centered at 128. Matches the
    /// convention an encapsulated JPEG decode produces.
    @inline(__always)
    static func ybrFullToRGB(y: UInt8, cb: UInt8, cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let Y = Double(y), Cb = Double(cb) - 128.0, Cr = Double(cr) - 128.0
        let r = Y + 1.402 * Cr
        let g = Y - 0.344136 * Cb - 0.714136 * Cr
        let b = Y + 1.772 * Cb
        @inline(__always) func clamp(_ v: Double) -> UInt8 {
            v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v + 0.5))
        }
        return (clamp(r), clamp(g), clamp(b))
    }
}

public enum DICOMError: Error, CustomStringConvertible {
    case notDICOM
    case truncated
    case unsupportedTransferSyntax(String)
    case missingPixelData
    case invalidGeometry
    /// Declared geometry (Rows×Columns×SamplesPerPixel) exceeds the
    /// decompression-bomb limit ``DICOMReader/maxDecodablePixels``.
    case imageTooLarge(pixels: Int, limit: Int)
    /// PixelData is shorter than the declared geometry requires; decoding
    /// would silently under-fill the image.
    case truncatedPixelData(expected: Int, actual: Int)
    /// Encapsulated PixelData framing is malformed (bad item tags / no fragment).
    case invalidPixelData

    public var description: String {
        switch self {
        case .notDICOM: return "not a DICOM file (missing DICM magic)"
        case .truncated: return "DICOM file truncated"
        case .unsupportedTransferSyntax(let ts):
            return "unsupported transfer syntax: \(ts) (only uncompressed Implicit/Explicit VR LE)"
        case .missingPixelData: return "missing PixelData element (7FE0,0010)"
        case .invalidGeometry: return "invalid Rows/Columns/Bits"
        case .imageTooLarge(let pixels, let limit):
            return "image too large: \(pixels) samples exceeds \(limit)-sample limit"
        case .truncatedPixelData(let expected, let actual):
            return "truncated PixelData: expected \(expected) bytes, got \(actual)"
        case .invalidPixelData: return "malformed encapsulated PixelData framing"
        }
    }
}

/// Minimal DICOM parser — handles the two uncompressed Little Endian transfer
/// syntaxes (Implicit VR `1.2.840.10008.1.2` and Explicit VR `1.2.840.10008.1.2.1`)
/// natively, and extracts the compressed stream from the JPEG-family encapsulated
/// syntaxes (caller decodes it with the matching codec). Other compressed/RLE
/// syntaxes throw.
public enum DICOMReader {

    /// Absolute upper bound on total pixel samples (Rows × Columns ×
    /// SamplesPerPixel) accepted before allocating pixel buffers. A
    /// decompression-bomb / DoS guard mirroring JLISwift's
    /// `JLIDecoder.maxDecodablePixels` (a different module, so the value is
    /// duplicated intentionally): a tiny crafted header must not be able to
    /// force a multi-gigabyte allocation (an uncatchable OOM trap).
    /// 268,435,456 (2^28 ≈ 268 MP) exceeds any diagnostic image (mammography
    /// ~24 MP) while blocking the absurd worst case.
    public static let maxDecodablePixels = 1 << 28

    /// Group/element pair packed into a UInt32 (group << 16 | element).
    typealias Tag = UInt32

    @inline(__always)
    static func tag(_ group: UInt16, _ element: UInt16) -> Tag {
        (UInt32(group) << 16) | UInt32(element)
    }

    static let tagRows                  = tag(0x0028, 0x0010)
    static let tagColumns               = tag(0x0028, 0x0011)
    static let tagBitsAllocated         = tag(0x0028, 0x0100)
    static let tagBitsStored            = tag(0x0028, 0x0101)
    static let tagPixelRepresentation   = tag(0x0028, 0x0103)
    static let tagSamplesPerPixel       = tag(0x0028, 0x0002)
    static let tagPhotometric           = tag(0x0028, 0x0004)
    static let tagModality              = tag(0x0008, 0x0060)
    static let tagWindowCenter          = tag(0x0028, 0x1050)
    static let tagWindowWidth           = tag(0x0028, 0x1051)
    static let tagRescaleIntercept      = tag(0x0028, 0x1052)
    static let tagRescaleSlope          = tag(0x0028, 0x1053)
    /// Encapsulated (compressed) transfer syntaxes whose PixelData is a JPEG
    /// stream the caller decodes with the matching codec. We surface the stream
    /// and the syntax; we do not decode it here (the container layer is codec-
    /// agnostic). These cover the JPEG families the JLISwift codec can decode:
    /// baseline (.50), extended (.51), and lossless processes 14 / 14-SV1
    /// (.57 / .70).
    static let encapsulatedTransferSyntaxes: Set<String> = [
        "1.2.840.10008.1.2.4.50",   // JPEG Baseline (Process 1)
        "1.2.840.10008.1.2.4.51",   // JPEG Extended (Process 2 & 4)
        "1.2.840.10008.1.2.4.57",   // JPEG Lossless (Process 14)
        "1.2.840.10008.1.2.4.70",   // JPEG Lossless, First-Order Prediction (Process 14 SV1)
    ]

    static let tagHighBit               = tag(0x0028, 0x0102)
    static let tagPlanarConfiguration   = tag(0x0028, 0x0006)
    static let tagPixelData             = tag(0x7FE0, 0x0010)
    static let tagTransferSyntax        = tag(0x0002, 0x0010)
    static let tagItem                  = tag(0xFFFE, 0xE000)
    static let tagItemDelim             = tag(0xFFFE, 0xE00D)
    static let tagSequenceDelim         = tag(0xFFFE, 0xE0DD)

    /// Convenience: read and parse a DICOM file at `url`.
    public static func read(contentsOf url: URL) throws -> DICOMImage {
        try read([UInt8](Data(contentsOf: url)))
    }

    public static func read(_ data: [UInt8]) throws -> DICOMImage {
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
            let e = try readExplicitVR(data, at: c)
            if e.group != 0x0002 {
                datasetStart = c
                break
            }
            if tag(e.group, e.element) == tagTransferSyntax {
                transferSyntax = readUIString(data, range: e.valueRange)
            }
            c = e.next
            datasetStart = e.next
        }

        // Encapsulated (compressed) transfer syntaxes carry a JPEG stream in an
        // undefined-length PixelData. We extract the stream and flag it so the
        // caller decodes it with the matching codec; the dataset framing is always
        // Explicit VR LE for these. Native syntaxes are decoded inline as before.
        let encapsulated = encapsulatedTransferSyntaxes.contains(transferSyntax)
        let isImplicit: Bool
        switch transferSyntax {
        case "1.2.840.10008.1.2":   isImplicit = true   // Implicit VR Little Endian
        case "1.2.840.10008.1.2.1": isImplicit = false  // Explicit VR Little Endian
        default:
            guard encapsulated else { throw DICOMError.unsupportedTransferSyntax(transferSyntax) }
            isImplicit = false                          // encapsulated datasets are Explicit VR LE
        }

        var rows = 0, cols = 0, bitsAllocated = 0, bitsStored = 0
        var highBit = -1, planarConfiguration = 0
        var pixelRep = 0, samplesPerPixel = 1
        var photometric = "MONOCHROME2"
        var modality = ""
        var windowCenter: Double? = nil
        var windowWidth: Double? = nil
        var rescaleSlope: Double? = nil
        var rescaleIntercept: Double? = nil
        var pixelData: [UInt8] = []

        var p = datasetStart
        while p < data.count {
            let parsed = isImplicit ? try readImplicitVR(data, at: p)
                                    : try readExplicitVR(data, at: p)
            let t = tag(parsed.group, parsed.element)

            // Skip sequences (SQ) wholesale so their nested items are not parsed
            // as top-level pixel-module attributes — a nested/undefined-length SQ
            // before group 0028 would otherwise derail Rows/Columns/PixelData on
            // real clinical files. An explicit-VR SQ is stepped over by its `next`
            // pointer already (defined length) or by scanning to the sequence
            // delimiter (undefined length); the same applies to an implicit-VR
            // element with undefined length, which can only be a sequence here
            // (encapsulated PixelData is excluded — these are uncompressed syntaxes).
            if parsed.vr == "SQ" || (parsed.undefinedLength && t != tagPixelData) {
                p = parsed.undefinedLength
                    ? try skipUntilDelimiter(data, after: parsed.next,
                                             isImplicit: isImplicit, delimiter: 0xE0DD)
                    : parsed.next
                continue
            }

            switch t {
            case tagRows:                rows = Int(readUInt16(data, range: parsed.valueRange))
            case tagColumns:             cols = Int(readUInt16(data, range: parsed.valueRange))
            case tagBitsAllocated:       bitsAllocated = Int(readUInt16(data, range: parsed.valueRange))
            case tagBitsStored:          bitsStored = Int(readUInt16(data, range: parsed.valueRange))
            case tagHighBit:             highBit = Int(readUInt16(data, range: parsed.valueRange))
            case tagPixelRepresentation: pixelRep = Int(readUInt16(data, range: parsed.valueRange))
            case tagSamplesPerPixel:     samplesPerPixel = Int(readUInt16(data, range: parsed.valueRange))
            case tagPlanarConfiguration: planarConfiguration = Int(readUInt16(data, range: parsed.valueRange))
            case tagPhotometric:         photometric = readString(data, range: parsed.valueRange)
            case tagModality:            modality = readString(data, range: parsed.valueRange)
            case tagWindowCenter:        windowCenter = readDecimalString(data, range: parsed.valueRange)
            case tagWindowWidth:         windowWidth = readDecimalString(data, range: parsed.valueRange)
            case tagRescaleIntercept:    rescaleIntercept = readDecimalString(data, range: parsed.valueRange)
            case tagRescaleSlope:        rescaleSlope = readDecimalString(data, range: parsed.valueRange)
            case tagPixelData:
                if parsed.undefinedLength {
                    // Encapsulated PixelData: an (empty) Basic Offset Table item
                    // followed by one-or-more fragment items, closed by the
                    // Sequence Delimitation Item. Concatenate the fragments into
                    // the compressed stream (we stop at the delimiter / EOF below).
                    pixelData = try readEncapsulatedFragments(data, after: parsed.next)
                } else {
                    pixelData = Array(data[parsed.valueRange])
                }
            default: break
            }

            p = parsed.next
            if pixelData.isEmpty == false && t == tagPixelData { break }
        }

        guard rows > 0, cols > 0, bitsAllocated > 0 else { throw DICOMError.invalidGeometry }
        // Reject absurd per-dimension values before any width*height work —
        // Rows/Columns are 16-bit fields, so beyond 65535 is corrupt, not large.
        guard rows <= 0xFFFF, cols <= 0xFFFF else { throw DICOMError.invalidGeometry }
        // Decompression-bomb guard: cap total samples before allocating any
        // pixel/intensity buffer. Int math is safe given the bounds above.
        let totalSamples = rows * cols * samplesPerPixel
        guard totalSamples <= DICOMReader.maxDecodablePixels else {
            throw DICOMError.imageTooLarge(pixels: totalSamples, limit: DICOMReader.maxDecodablePixels)
        }
        guard !pixelData.isEmpty else { throw DICOMError.missingPixelData }
        // Truncated-PixelData guard applies only to *native* samples — an
        // encapsulated stream is compressed, so its byte count bears no fixed
        // relation to the declared geometry.
        if !encapsulated {
            let expectedBytes = totalSamples * ((bitsAllocated + 7) / 8)
            guard pixelData.count >= expectedBytes else {
                throw DICOMError.truncatedPixelData(expected: expectedBytes, actual: pixelData.count)
            }
        }

        let effectiveStored = bitsStored == 0 ? bitsAllocated : bitsStored
        var image = DICOMImage(
            width: cols, height: rows,
            samplesPerPixel: samplesPerPixel,
            bitsAllocated: bitsAllocated,
            bitsStored: effectiveStored,
            pixelRepresentation: pixelRep,
            highBit: highBit >= 0 ? highBit : effectiveStored - 1,
            planarConfiguration: planarConfiguration,
            photometric: photometric.trimmingCharacters(in: .whitespacesAndNewlines),
            modality: modality.trimmingCharacters(in: .whitespacesAndNewlines),
            windowCenter: windowCenter, windowWidth: windowWidth,
            rescaleSlope: rescaleSlope ?? 1.0,
            rescaleIntercept: rescaleIntercept ?? 0.0,
            pixelData: pixelData,
            transferSyntax: transferSyntax
        )
        image.isEncapsulated = encapsulated
        return image
    }

    // MARK: - Element readers

    /// A parsed DICOM element header. `undefinedLength` is true when the length
    /// field was the 0xFFFFFFFF sentinel (a sequence or encapsulated pixel data
    /// whose extent is bounded by a delimiter, not a byte count).
    typealias Element = (
        group: UInt16, element: UInt16, vr: String?,
        valueRange: Range<Int>, next: Int, undefinedLength: Bool
    )

    private static func readExplicitVR(_ data: [UInt8], at offset: Int) throws -> Element {
        guard offset + 8 <= data.count else { throw DICOMError.truncated }
        let group   = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        let element = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
        if group == 0xFFFE {
            let length = readUInt32(data, offset + 4)
            let valStart = offset + 8
            if length == 0xFFFFFFFF {
                return (group, element, nil, valStart..<valStart, valStart, true)
            }
            let valEnd = valStart + Int(length)
            return (group, element, nil, valStart..<valEnd, valEnd, false)
        }

        let vr = String(bytes: [data[offset + 4], data[offset + 5]], encoding: .ascii) ?? "  "

        let bigLengthVRs: Set<String> = ["OB", "OW", "OF", "OD", "SQ", "UN", "UT"]
        if bigLengthVRs.contains(vr) {
            guard offset + 12 <= data.count else { throw DICOMError.truncated }
            let length = readUInt32(data, offset + 8)
            let valStart = offset + 12
            if length == 0xFFFFFFFF {
                return (group, element, vr, valStart..<valStart, valStart, true)
            }
            let valEnd = valStart + Int(length)
            guard valEnd <= data.count else { throw DICOMError.truncated }
            return (group, element, vr, valStart..<valEnd, valEnd, false)
        } else {
            let length = UInt16(data[offset + 6]) | (UInt16(data[offset + 7]) << 8)
            let valStart = offset + 8
            let valEnd = valStart + Int(length)
            guard valEnd <= data.count else { throw DICOMError.truncated }
            return (group, element, vr, valStart..<valEnd, valEnd, false)
        }
    }

    private static func readImplicitVR(_ data: [UInt8], at offset: Int) throws -> Element {
        guard offset + 8 <= data.count else { throw DICOMError.truncated }
        let group   = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        let element = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
        let length = readUInt32(data, offset + 4)
        let valStart = offset + 8
        if length == 0xFFFFFFFF {
            return (group, element, nil, valStart..<valStart, valStart, true)
        }
        let valEnd = valStart + Int(length)
        guard valEnd <= data.count else { throw DICOMError.truncated }
        return (group, element, nil, valStart..<valEnd, valEnd, false)
    }

    /// Steps past an undefined-length sequence or item starting just after its
    /// header, scanning forward until the matching delimiter element
    /// (FFFE,`delimiter` — E0DD for a sequence, E00D for an item). Item headers
    /// (FFFE,E000) are always 8-byte tag+length regardless of explicit/implicit
    /// VR; an item with a defined length is skipped by its byte count, and an
    /// item with undefined length is descended into recursively. All other
    /// (non-FFFE) elements are parsed with the active VR rules so their lengths
    /// are interpreted correctly. The scan is bounded by the buffer so malformed
    /// input throws/terminates rather than looping forever.
    private static func skipUntilDelimiter(
        _ data: [UInt8], after start: Int, isImplicit: Bool, delimiter: UInt16
    ) throws -> Int {
        var q = start
        while q + 8 <= data.count {
            let group   = UInt16(data[q]) | (UInt16(data[q + 1]) << 8)
            let element = UInt16(data[q + 2]) | (UInt16(data[q + 3]) << 8)
            if group == 0xFFFE {
                let length = readUInt32(data, q + 4)
                q += 8
                if element == delimiter { return q }            // matching delimiter — done
                if element == 0xE000 {                          // Item
                    if length == 0xFFFFFFFF {                    // undefined-length item: recurse
                        q = try skipUntilDelimiter(data, after: q, isImplicit: isImplicit,
                                                   delimiter: 0xE00D)
                    } else {
                        q += Int(length)                        // defined-length item: skip bytes
                    }
                }
                // Other FFFE elements (e.g. E00D when we sought E0DD) are zero-length
                // markers already stepped over by the 8-byte header advance.
                continue
            }
            // A normal element inside the sequence/item — parse with the active VR.
            let e = isImplicit ? try readImplicitVR(data, at: q) : try readExplicitVR(data, at: q)
            if e.vr == "SQ" || e.undefinedLength {
                q = e.undefinedLength
                    ? try skipUntilDelimiter(data, after: e.next, isImplicit: isImplicit,
                                             delimiter: 0xE0DD)
                    : e.next
            } else {
                q = e.next
            }
        }
        return data.count
    }

    /// Reads an encapsulated PixelData value (DICOM PS3.5 §A.4) starting just
    /// after the PixelData header: a Basic Offset Table item (FFFE,E000) we skip,
    /// then one-or-more fragment items concatenated into the compressed stream,
    /// terminated by the Sequence Delimitation Item (FFFE,E0DD). Single-frame is
    /// the common case; multiple fragments of one frame are concatenated. Bounds-
    /// checked so malformed input throws rather than over-reads.
    private static func readEncapsulatedFragments(_ data: [UInt8], after start: Int) throws -> [UInt8] {
        var q = start
        var stream = [UInt8]()
        var sawBasicOffsetTable = false
        while q + 8 <= data.count {
            let group   = UInt16(data[q]) | (UInt16(data[q + 1]) << 8)
            let element = UInt16(data[q + 2]) | (UInt16(data[q + 3]) << 8)
            let length = readUInt32(data, q + 4)
            q += 8
            guard group == 0xFFFE else { throw DICOMError.invalidPixelData }
            if element == 0xE0DD { break }                  // Sequence Delimitation Item — done
            guard element == 0xE000 else { throw DICOMError.invalidPixelData }   // expect Item
            guard length != 0xFFFFFFFF else { throw DICOMError.invalidPixelData } // items are defined-length
            let end = q + Int(length)
            guard end <= data.count else { throw DICOMError.truncated }
            if !sawBasicOffsetTable {
                sawBasicOffsetTable = true                  // first item is the (often empty) BOT — skip
            } else {
                stream += data[q..<end]                     // a fragment — append to the frame stream
            }
            q = end
        }
        guard !stream.isEmpty else { throw DICOMError.missingPixelData }
        return stream
    }

    // MARK: - Value readers

    private static func readUInt16(_ data: [UInt8], range: Range<Int>) -> UInt16 {
        guard range.count >= 2 else { return 0 }
        return UInt16(data[range.lowerBound]) | (UInt16(data[range.lowerBound + 1]) << 8)
    }

    /// Little-endian UInt32 at an absolute byte offset (caller guarantees 4 bytes).
    @inline(__always)
    private static func readUInt32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readString(_ data: [UInt8], range: Range<Int>) -> String {
        let bytes = Array(data[range])
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readUIString(_ data: [UInt8], range: Range<Int>) -> String {
        var bytes = Array(data[range])
        while let last = bytes.last, last == 0x00 || last == 0x20 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readDecimalString(_ data: [UInt8], range: Range<Int>) -> Double? {
        let s = readString(data, range: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let first = s.split(separator: "\\").first.map(String.init) ?? s
        return Double(first.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
