// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Accelerate

/// The jpegli-compatible JPEG decoder.
///
/// `JLIDecoder` decompresses JPEG data, automatically detecting advanced features
/// such as jpegli 10+ bit precision and XYB color space encoding.
///
/// Supports baseline sequential JPEG (SOF0) with standard Huffman coding and all
/// chroma subsampling modes. Progressive JPEG (SOF2) parsing is supported but
/// full progressive decoding is planned for a future milestone.
///
/// ## Usage
///
/// ```swift
/// let decoder = JLIDecoder()
/// let info = try decoder.inspect(data: jpegBytes)
/// let image = try decoder.decode(from: jpegBytes)
/// ```
public struct JLIDecoder: Sendable {
    /// Creates a new decoder instance.
    public init() {}

    /// Inspects JPEG data and returns metadata without fully decoding the image.
    ///
    /// Use this to detect whether a JPEG uses advanced jpegli features (10+ bit,
    /// XYB color space) before deciding on a decode configuration.
    ///
    /// - Parameter data: The JPEG bitstream bytes.
    /// - Returns: A ``JLIJPEGInfo`` describing the JPEG's properties.
    /// - Throws: ``JLIError`` if the data is not valid JPEG.
    public func inspect(data: [UInt8]) throws -> JLIJPEGInfo {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw JLIError.invalidJPEGData
        }
        var reader = MarkerReader(data: data)
        return try reader.readInfo()
    }

    /// Decodes JPEG data into a ``JLIImage``.
    ///
    /// The decoder automatically detects jpegli-specific features:
    /// - **10+ bit precision**: Outputs to a 16-bit buffer unless overridden.
    /// - **XYB color space**: Applies the correct inverse transform.
    ///
    /// - Parameters:
    ///   - data: The JPEG bitstream bytes.
    ///   - configuration: Decoder settings controlling output format.
    /// - Returns: The decoded image.
    /// - Throws: ``JLIError`` if decoding fails.
    public func decode(
        from data: [UInt8],
        configuration: JLIDecoderConfiguration = .default
    ) throws -> JLIImage {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw JLIError.invalidJPEGData
        }

        // Step 1: Parse JPEG markers
        var markerReader = MarkerReader(data: data)
        let parsed = try markerReader.parse()
        let frame = parsed.frameInfo

        guard !parsed.scans.isEmpty else {
            throw JLIError.decodingFailed("No scan data found in JPEG")
        }

        // Lossless (SOF3) is predictive, not DCT — fully separate path.
        if frame.isLossless {
            return try decodeLossless(frame: frame, scans: parsed.scans, configuration: configuration)
        }

        // Step 2: Prepare quantization tables (convert from zigzag to natural order)
        let quantTables = parsed.quantTables.map { zigzagTable -> [Int] in
            var natural = [Int](repeating: 0, count: 64)
            for i in 0..<64 {
                natural[Quantization.zigzagOrder[i]] = zigzagTable[i]
            }
            return natural
        }

        // Reject structurally-invalid frames before any size math or indexing.
        try validateDecodable(frame, quantTableCount: quantTables.count)

        // Reduced-scale (thumbnail) decode. 1 = full; 8 = 1/8 (DC-only).
        let scale = configuration.scale
        guard scale == 1 || scale == 8 else {
            throw JLIError.unsupportedJPEGFeature("decode scale \(scale) (only 1 and 8 supported)")
        }

        // Step 3: Prepare Huffman tables (use standard tables as fallback)
        let dcTables = prepareDCTables(parsed.huffmanDCTables)
        let acTables = prepareACTables(parsed.huffmanACTables)

        // Step 4: Determine MCU structure
        let components = frame.components
        let numComponents = components.count
        let hMaxSampling = components.map(\.horizontalSampling).max() ?? 1
        let vMaxSampling = components.map(\.verticalSampling).max() ?? 1
        let mcuW = hMaxSampling * 8
        let mcuH = vMaxSampling * 8
        let mcuCountH = (frame.width + mcuW - 1) / mcuW
        let mcuCountV = (frame.height + mcuH - 1) / mcuH

        // Step 5: Allocate one flat zigzag-coefficient buffer per component.
        // Block `b` of component `c` lives at `componentZigzag[c][b*64 ..< (b+1)*64]`.
        var componentZigzag = [[Int32]]()
        var componentBlocksPerRow = [Int]()
        var componentDimensions = [(blocksH: Int, blocksV: Int)]()
        for comp in components {
            let blocksH = mcuCountH * comp.horizontalSampling
            let blocksV = mcuCountV * comp.verticalSampling
            componentBlocksPerRow.append(blocksH)
            componentDimensions.append((blocksH, blocksV))
            componentZigzag.append([Int32](repeating: 0, count: blocksH * blocksV * 64))
        }

        // Step 6: Decode entropy data into the flat per-component buffers.
        // Progressive (SOF2) uses multiple scans with spectral selection and
        // successive approximation; baseline/extended-sequential uses one scan.
        if frame.isProgressive {
            // Non-interleaved (AC) scans address each component's own data-unit
            // grid: ceil(compW/8) × ceil(compH/8), where compW/H = the component's
            // dimensions after subsampling. Smaller than the MCU-padded grid for
            // images that aren't a whole number of MCUs.
            let realW = components.map { comp -> Int in
                let compW = (frame.width * comp.horizontalSampling + hMaxSampling - 1) / hMaxSampling
                return (compW + 7) / 8
            }
            let realH = components.map { comp -> Int in
                let compH = (frame.height * comp.verticalSampling + vMaxSampling - 1) / vMaxSampling
                return (compH + 7) / 8
            }
            var prog = ProgressiveDecoder(
                components: components,
                mcuCountH: mcuCountH, mcuCountV: mcuCountV,
                blocksPerRow: componentBlocksPerRow,
                blocksPerCol: componentDimensions.map { $0.blocksV },
                realBlocksW: realW, realBlocksH: realH,
                restartInterval: parsed.restartInterval
            )
            try prog.decode(scans: parsed.scans)
            componentZigzag = prog.coeffs
        } else {
            let scan = parsed.scans[0]
            var bitReader = BitReader(data: scan.entropyData)
            var prevDC = [Int32](repeating: 0, count: numComponents)
            var acBuf = [Int32](repeating: 0, count: 64)

            let restartInterval = parsed.restartInterval
            var mcuCount = 0
            var restartIndex = 0

            for mcuY in 0..<mcuCountV {
                for mcuX in 0..<mcuCountH {
                    // Every `restartInterval` MCUs, skip the RST0–RST7 marker
                    // (cycled) and reset DC predictors.
                    if restartInterval > 0 && mcuCount > 0
                        && mcuCount % restartInterval == 0 {
                        try bitReader.skipRestartMarker(expectedIndex: restartIndex)
                        restartIndex = (restartIndex + 1) & 7
                        for i in 0..<numComponents { prevDC[i] = 0 }
                    }
                    mcuCount += 1

                    for compIdx in 0..<numComponents {
                        let comp = components[compIdx]
                        let scanComp = scan.header.components.first { $0.componentSelector == comp.id }
                        let dcTableId = scanComp?.dcTableId ?? 0
                        let acTableId = scanComp?.acTableId ?? 0
                        let dcTable = dcTables[dcTableId] ?? StandardHuffmanTables.dcLuminance
                        let acTable = acTables[acTableId] ?? StandardHuffmanTables.acLuminance
                        let blocksPerRow = componentBlocksPerRow[compIdx]

                        for by in 0..<comp.verticalSampling {
                            for bx in 0..<comp.horizontalSampling {
                                let blockX = mcuX * comp.horizontalSampling + bx
                                let blockY = mcuY * comp.verticalSampling + by
                                let blockIndex = blockY * blocksPerRow + blockX
                                let dst = blockIndex * 64

                                let dcDiff = try HuffmanDecoder.decodeDC(
                                    from: &bitReader, table: dcTable
                                )
                                prevDC[compIdx] += dcDiff

                                try HuffmanDecoder.decodeAC(
                                    from: &bitReader, table: acTable, into: &acBuf
                                )
                                acBuf[0] = prevDC[compIdx]

                                for i in 0..<64 {
                                    componentZigzag[compIdx][dst + i] = acBuf[i]
                                }
                            }
                        }
                    }
                }
            }
        }

        // Step 7: Per component — batched inverse-zigzag + dequantize + IDCT +
        // level-shift up, then write each block into its plane.
        var componentPlanes = [(data: [Float], width: Int, height: Int)]()
        let maxBlockCount = componentDimensions.map { $0.blocksH * $0.blocksV }.max() ?? 0
        var natural = [Int32](repeating: 0, count: maxBlockCount * 64)
        var dctBuf = [Float](repeating: 0, count: maxBlockCount * 64)
        var pixelsBuf = [Float](repeating: 0, count: maxBlockCount * 64)
        var idctScratch = [Float](repeating: 0, count: maxBlockCount * 64)

        for compIdx in 0..<numComponents {
            let comp = components[compIdx]
            let blocksH = componentDimensions[compIdx].blocksH
            let blocksV = componentDimensions[compIdx].blocksV
            let blockCount = blocksH * blocksV
            let planeWidth = blocksH * 8
            let planeHeight = blocksV * 8
            let qtF = quantTables[comp.quantTableIndex].map { Float($0) }

            let compWidth = (frame.width * comp.horizontalSampling + hMaxSampling - 1) / hMaxSampling
            let compHeight = (frame.height * comp.verticalSampling + vMaxSampling - 1) / vMaxSampling

            // 1/8 DC-only path: each 8×8 block reduces to one pixel — its average,
            // which for the normalized DCT is (1/8)·dequant(DC) + level shift. No
            // inverse DCT; output plane is the block grid, trimmed to ceil(comp/8).
            if scale == 8 {
                let center = Float(1 << (frame.precision - 1))
                let maxV = Float((1 << frame.precision) - 1)
                let dcStep = Float(quantTables[comp.quantTableIndex][0])  // DC quant (natural order)
                var small = [Float](repeating: 0, count: blocksH * blocksV)
                componentZigzag[compIdx].withUnsafeBufferPointer { src in
                    for b in 0..<blockCount {
                        let dc = Float(src[b * 64]) * dcStep
                        small[b] = min(max(dc * (1.0 / 8.0) + center, 0), maxV)
                    }
                }
                let cwS = (compWidth + 7) / 8
                let chS = (compHeight + 7) / 8
                if blocksH != cwS || blocksV != chS {
                    var trimmed = [Float](repeating: 0, count: cwS * chS)
                    for y in 0..<chS {
                        for x in 0..<cwS { trimmed[y * cwS + x] = small[y * blocksH + x] }
                    }
                    componentPlanes.append((trimmed, cwS, chS))
                } else {
                    componentPlanes.append((small, blocksH, blocksV))
                }
                continue
            }

            // Inverse zigzag every block: out[block*64 + zigzagOrder[i]] = in[block*64 + i].
            let zigzag = Quantization.zigzagOrder
            componentZigzag[compIdx].withUnsafeBufferPointer { srcBuf in
                natural.withUnsafeMutableBufferPointer { dstBuf in
                    let src = srcBuf.baseAddress!
                    let dst = dstBuf.baseAddress!
                    for b in 0..<blockCount {
                        let base = b * 64
                        for i in 0..<64 { dst[base + zigzag[i]] = src[base + i] }
                    }
                }
            }

            AccelerateDSP.dequantizeBatch(
                natural, table: qtF, into: &dctBuf, blockCount: blockCount
            )
            AccelerateDSP.inverseDCTBatch(
                dctBuf, into: &pixelsBuf, scratch: &idctScratch, blockCount: blockCount
            )

            // Level shift +2^(P-1) + clamp [0, 2^P-1] over the whole batched
            // buffer. 128/255 for 8-bit, 2048/4095 for 12-bit.
            var center = Float(1 << (frame.precision - 1))
            var lo: Float = 0.0, hi = Float((1 << frame.precision) - 1)
            let n = vDSP_Length(blockCount * 64)
            vDSP_vsadd(pixelsBuf, 1, &center, &pixelsBuf, 1, n)
            vDSP_vclip(pixelsBuf, 1, &lo, &hi, &pixelsBuf, 1, n)

            var plane = [Float](repeating: 0, count: planeWidth * planeHeight)
            pixelsBuf.withUnsafeBufferPointer { srcBuf in
                plane.withUnsafeMutableBufferPointer { dstBuf in
                    let src = srcBuf.baseAddress!
                    let dst = dstBuf.baseAddress!
                    for b in 0..<blockCount {
                        let blockX = b % blocksH
                        let blockY = b / blocksH
                        let startX = blockX * 8
                        let startY = blockY * 8
                        let blockBase = b * 64
                        for y in 0..<8 {
                            let py = startY + y
                            if py >= planeHeight { break }
                            let rowBase = py * planeWidth
                            let srcRow = blockBase + y * 8
                            for x in 0..<8 {
                                let px = startX + x
                                if px >= planeWidth { break }
                                dst[rowBase + px] = src[srcRow + x]
                            }
                        }
                    }
                }
            }

            // Trim to actual component dimensions (computed at the loop top).
            if planeWidth != compWidth || planeHeight != compHeight {
                var trimmed = [Float](repeating: 0, count: compWidth * compHeight)
                for y in 0..<compHeight {
                    for x in 0..<compWidth {
                        trimmed[y * compWidth + x] = plane[y * planeWidth + x]
                    }
                }
                componentPlanes.append((trimmed, compWidth, compHeight))
            } else {
                componentPlanes.append((plane, planeWidth, planeHeight))
            }
        }

        // Step 8: Chroma upsample and color convert. Output dimensions are the
        // image dimensions reduced by `scale` (= full dims when scale == 1).
        let outW = (frame.width + scale - 1) / scale
        let outH = (frame.height + scale - 1) / scale
        let outputData: [UInt8]
        let outputColorModel: JLIColorModel
        // 12-bit (grayscale or color) decodes to a uint16 buffer (little-endian
        // samples); 8-bit stays uint8.
        let isExtendedPrecision = frame.precision > 8

        if numComponents == 1 {
            // Grayscale
            let plane = componentPlanes[0]
            if isExtendedPrecision {
                var bytes = [UInt8](repeating: 0, count: plane.data.count * 2)
                for i in 0..<plane.data.count {
                    let v = UInt16(clamping: Int(plane.data[i].rounded()))
                    bytes[i * 2] = UInt8(v & 0xFF)
                    bytes[i * 2 + 1] = UInt8(v >> 8)
                }
                outputData = bytes
            } else {
                outputData = plane.data.map { UInt8(clamping: Int($0.rounded())) }
            }
            outputColorModel = configuration.outputColorModel ?? .grayscale
        } else {
            // YCbCr → RGB
            let yPlane = componentPlanes[0]

            // Upsample Cb and Cr to full resolution
            let cbUp = ChromaSampling.upsample(
                componentPlanes[1].data,
                width: componentPlanes[1].width,
                height: componentPlanes[1].height,
                targetWidth: outW, targetHeight: outH
            )
            let crUp = ChromaSampling.upsample(
                componentPlanes[2].data,
                width: componentPlanes[2].width,
                height: componentPlanes[2].height,
                targetWidth: outW, targetHeight: outH
            )

            // Trim Y plane if padded
            let yTrimmed: [Float]
            if yPlane.width != outW || yPlane.height != outH {
                var trimmed = [Float](repeating: 0, count: outW * outH)
                for y in 0..<outH {
                    for x in 0..<outW {
                        trimmed[y * outW + x] = yPlane.data[y * yPlane.width + x]
                    }
                }
                yTrimmed = trimmed
            } else {
                yTrimmed = yPlane.data
            }

            if isExtendedPrecision {
                // 12-bit color → little-endian UInt16 RGB. Planes are already
                // reconstructed in 0...2^P-1 with chroma centered at 2^(P-1).
                outputData = ColorConversion.imageYCbCr16ToRGB(
                    y: yTrimmed, cb: cbUp, cr: crUp,
                    width: outW, height: outH,
                    center: Float(1 << (frame.precision - 1)),
                    maxValue: Float((1 << frame.precision) - 1)
                )
            } else {
                outputData = ColorConversion.imageYCbCrToRGB(
                    y: yTrimmed, cb: cbUp, cr: crUp,
                    width: outW, height: outH
                )
            }
            outputColorModel = configuration.outputColorModel ?? .rgb
        }

        let outputPixelFormat = configuration.outputPixelFormat
            ?? (isExtendedPrecision ? .uint16 : .uint8)

        return try JLIImage(
            width: outW,
            height: outH,
            pixelFormat: outputPixelFormat,
            colorModel: outputColorModel,
            data: outputData
        )
    }

    // MARK: - Lossless (SOF3) decode

    /// Decodes a lossless (SOF3) JPEG by spatial prediction (ITU-T T.81 Annex H):
    /// each sample is predicted from already-decoded neighbours (selector 1–7 in
    /// the SOS `spectralStart`), and the Huffman-coded difference (DC mechanism,
    /// SSSS=16 ⇒ −32768 special case) is added back. Grayscale only for now.
    private func decodeLossless(
        frame: JPEGFrameInfo, scans: [JPEGScanData], configuration: JLIDecoderConfiguration
    ) throws -> JLIImage {
        let precision = frame.precision
        guard (2...16).contains(precision) else {
            throw JLIError.unsupportedJPEGFeature("lossless precision \(precision)")
        }
        let w = frame.width, h = frame.height
        guard w >= 1, h >= 1, w <= 65535, h <= 65535 else {
            throw JLIError.decodingFailed("invalid lossless dimensions \(w)×\(h)")
        }
        guard frame.components.count == 1 else {
            throw JLIError.unsupportedJPEGFeature("lossless color (only grayscale supported)")
        }
        guard let scan = scans.first else { throw JLIError.decodingFailed("no lossless scan") }
        let predictor = scan.header.spectralStart       // 1–7
        let pt = scan.header.successiveApproxLow         // point transform
        guard (1...7).contains(predictor) else {
            throw JLIError.decodingFailed("invalid lossless predictor \(predictor)")
        }
        let dcTables = prepareDCTables(scan.dcTables)
        let table = dcTables[scan.header.components.first?.dcTableId ?? 0]
            ?? StandardHuffmanTables.dcLuminance

        var reader = BitReader(data: scan.entropyData)
        var samples = [Int32](repeating: 0, count: w * h)
        let half = Int32(1 << (precision - 1 - pt))   // predictor for the very first sample
        let mask: Int32 = 0xFFFF                       // T.81: differences are modulo 2^16

        for y in 0..<h {
            let row = y * w
            let prevRow = row - w
            for x in 0..<w {
                let px: Int32
                if x == 0 {
                    px = y == 0 ? half : samples[prevRow]          // Rb (or initial)
                } else if y == 0 {
                    px = samples[row + x - 1]                       // Ra
                } else {
                    let ra = samples[row + x - 1]
                    let rb = samples[prevRow + x]
                    let rc = samples[prevRow + x - 1]
                    switch predictor {
                    case 1: px = ra
                    case 2: px = rb
                    case 3: px = rc
                    case 4: px = ra + rb - rc
                    case 5: px = ra + ((rb - rc) >> 1)
                    case 6: px = rb + ((ra - rc) >> 1)
                    default: px = (ra + rb) >> 1                    // 7
                    }
                }
                // Huffman-coded difference category, then the difference itself.
                let cat = Int(try HuffmanDecoder.decodeSymbol(from: &reader, table: table))
                let diff: Int32
                if cat == 0 { diff = 0 }
                else if cat == 16 { diff = -32768 }                // T.81 lossless special case
                else { diff = try HuffmanDecoder.decodeValue(from: &reader, category: cat) }
                samples[row + x] = (px + (diff << pt)) & mask
            }
        }

        let model = configuration.outputColorModel ?? .grayscale
        if precision <= 8 {
            let bytes = samples.map { UInt8(clamping: Int($0)) }
            return try JLIImage(width: w, height: h,
                                pixelFormat: configuration.outputPixelFormat ?? .uint8,
                                colorModel: model, data: bytes)
        }
        var bytes = [UInt8](repeating: 0, count: samples.count * 2)
        for i in 0..<samples.count {
            let v = UInt16(clamping: Int(samples[i]))
            bytes[i * 2] = UInt8(v & 0xFF); bytes[i * 2 + 1] = UInt8(v >> 8)
        }
        return try JLIImage(width: w, height: h,
                            pixelFormat: configuration.outputPixelFormat ?? .uint16,
                            colorModel: model, data: bytes)
    }

    // MARK: - Private Helpers

    /// DC Huffman tables keyed by table id, with standard tables filled in for
    /// ids 0/1. Keyed (not positional) so a scan referencing any 4-bit table id
    /// (0–15) resolves with a fallback instead of indexing past a fixed array.
    private func prepareDCTables(_ parsed: [Int: HuffmanTable]) -> [Int: HuffmanTable] {
        var tables = parsed
        if tables[0] == nil { tables[0] = StandardHuffmanTables.dcLuminance }
        if tables[1] == nil { tables[1] = StandardHuffmanTables.dcChrominance }
        return tables
    }

    /// AC Huffman tables keyed by table id, with standard tables filled in for
    /// ids 0/1. See ``prepareDCTables(_:)``.
    private func prepareACTables(_ parsed: [Int: HuffmanTable]) -> [Int: HuffmanTable] {
        var tables = parsed
        if tables[0] == nil { tables[0] = StandardHuffmanTables.acLuminance }
        if tables[1] == nil { tables[1] = StandardHuffmanTables.acChrominance }
        return tables
    }

    /// Rejects structurally-invalid frames that the decode pipeline cannot
    /// handle without trapping — malformed input (e.g. JPEG-in-DICOM from an
    /// untrusted source) must fail with a thrown ``JLIError``, never a crash.
    private func validateDecodable(_ frame: JPEGFrameInfo, quantTableCount: Int) throws {
        // Precision drives the level shift `1 << (precision-1)`, which traps for
        // precision 0; we only decode 8-bit (color/gray) and 12-bit (gray).
        guard frame.precision == 8 || frame.precision == 12 else {
            throw JLIError.unsupportedJPEGFeature(
                "sample precision \(frame.precision) (only 8 and 12 supported)")
        }
        // Dimensions: positive and within the 16-bit SOF field range. Zero width
        // or height would divide by zero when computing the MCU grid.
        guard frame.width >= 1, frame.height >= 1,
              frame.width <= 65535, frame.height <= 65535 else {
            throw JLIError.decodingFailed("invalid image dimensions \(frame.width)×\(frame.height)")
        }
        // Only grayscale (1) and YCbCr (3) layouts are decodable; the color path
        // assumes exactly three planes (Y, Cb, Cr).
        guard frame.components.count == 1 || frame.components.count == 3 else {
            throw JLIError.unsupportedJPEGFeature(
                "\(frame.components.count)-component JPEG (only 1 or 3 supported)")
        }
        for comp in frame.components {
            // Sampling factors are 1–4 per T.81; a zero factor zeroes the max and
            // divides by zero in the MCU-grid math.
            guard (1...4).contains(comp.horizontalSampling),
                  (1...4).contains(comp.verticalSampling) else {
                throw JLIError.decodingFailed("invalid sampling factor for component \(comp.id)")
            }
            // The component must reference a quant table that was actually defined.
            guard comp.quantTableIndex >= 0, comp.quantTableIndex < quantTableCount else {
                throw JLIError.decodingFailed(
                    "component \(comp.id) references undefined quant table \(comp.quantTableIndex)")
            }
        }
    }
}
