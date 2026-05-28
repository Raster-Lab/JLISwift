// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Accelerate

/// The jpegli-compatible JPEG encoder.
///
/// `JLIEncoder` compresses image data into JPEG format using the jpegli algorithm,
/// providing up to 35% better compression ratios compared to traditional JPEG encoders
/// while maintaining full backward compatibility.
///
/// The encoder supports baseline sequential JPEG with all standard chroma subsampling
/// modes (4:4:4, 4:2:2, 4:2:0, 4:0:0). Floating-point DCT precision is used throughout
/// the pipeline, matching the jpegli approach for higher fidelity.
///
/// ## Usage
///
/// ```swift
/// let encoder = JLIEncoder()
/// let jpegData = try encoder.encode(image, configuration: .default)
/// ```
public struct JLIEncoder: Sendable {
    /// Creates a new encoder instance.
    public init() {}

    /// Rate-distortion λ is `rdoLambdaK · meanACQuant²`. Tying λ to the
    /// quantization step (R-D theory: λ ∝ Q²) keeps truncation gentle at high
    /// quality (small Q, where surviving coefficients are perceptually real) and
    /// firmer at low quality (large Q). Tuned on the DICOM corpus so bytes drop
    /// without raising butteraugli at either end of the quality range.
    static let rdoLambdaK = 0.004

    /// Blocks with more than this many nonzero AC coefficients skip the O(m²)
    /// trellis DP (they're high-entropy — little to gain from dropping, and the
    /// runtime cost is steep). Bounds worst-case encode time on noisy content.
    static let trellisMaxNonzeros = 32

    /// Trellis magnitude reduction (q→q∓1) is only considered for zigzag
    /// positions ≥ this — reducing the lowest AC frequencies costs visible
    /// quality (butteraugli) for negligible rate; HF reduction is near-free.
    static let trellisReduceMinZigzag = 6

    /// Encodes an image to JPEG data using the jpegli algorithm.
    ///
    /// - Parameters:
    ///   - image: The source image to encode. Must use `.uint8` pixel format.
    ///   - configuration: Encoder settings controlling quality, color space, and features.
    /// - Returns: The encoded JPEG data as a byte array.
    /// - Throws: ``JLIError`` if encoding fails or the input is invalid.
    public func encode(
        _ image: JLIImage,
        configuration: JLIEncoderConfiguration = .default
    ) throws -> [UInt8] {
        try validateConfiguration(configuration)

        let width = image.width
        let height = image.height
        // The distance parameter (jpegli/JPEG-XL convention) overrides quality
        // when set: it's mapped to an effective IJG quality that scales the
        // standard quant tables.
        let effectiveQuality: Double
        if let distance = configuration.distance {
            effectiveQuality = Quantization.qualityForDistance(distance)
        } else {
            effectiveQuality = configuration.quality
        }
        let quality = max(1, min(100, Int(effectiveQuality.rounded())))

        // Sample precision: 8-bit for uint8, 12-bit for uint16 (JPEG supports 8
        // or 12). 12-bit is currently grayscale-only — the color path still
        // assumes 0–255 BT.601 ranges. Level shift is 2^(P-1): 128 or 2048.
        let precision: Int
        switch image.pixelFormat {
        case .uint8:
            precision = 8
        case .uint16:
            precision = 12
        case .float32:
            throw JLIError.unsupportedColorSpaceConversion(
                from: "\(image.pixelFormat)", to: "JPEG encoding"
            )
        }
        let levelShift = Float(1 << (precision - 1))

        // Determine if encoding as grayscale
        let isGrayscale = image.colorModel == .grayscale
            || configuration.chromaSubsampling == .yuv400

        // Lossless (SOF3) is a predictive mode — fully separate from the DCT path.
        if configuration.lossless {
            return try encodeLossless(image, configuration: configuration,
                                      precision: precision, isGrayscale: isGrayscale)
        }

        // 12-bit color is supported for RGB/RGBA input. Pre-converted 12-bit
        // YCbCr input isn't — the direct-extract path below assumes 8-bit samples.
        if precision > 8 && !isGrayscale && image.colorModel == .yCbCr {
            throw JLIError.unsupportedColorSpaceConversion(
                from: "12-bit pre-converted YCbCr", to: "JPEG (use RGB/RGBA input for 12-bit color)"
            )
        }

        // 12-bit DC/AC coefficients exceed the categories the fixed Annex K
        // Huffman tables define (0–11), so optimal per-image tables are required.
        let optimiseHuffman = configuration.optimiseHuffman || precision > 8

        // Reads a grayscale sample at pixel index `i`, honoring bit depth.
        // uint16 data is little-endian 2 bytes/sample.
        func graySample(_ data: [UInt8], _ i: Int) -> Float {
            if precision == 8 { return Float(data[i]) }
            return Float(UInt16(data[i * 2]) | (UInt16(data[i * 2 + 1]) << 8))
        }

        // Step 1: Extract component planes (Float, 0–maxSample range)
        let yPlane: [Float]
        var cbPlane: [Float]
        var crPlane: [Float]

        if isGrayscale {
            if image.colorModel == .grayscale {
                let pixelCount = width * height
                var y = [Float](repeating: 0, count: pixelCount)
                for i in 0..<pixelCount { y[i] = graySample(image.data, i) }
                yPlane = y
            } else {
                let planes = ColorConversion.imageRGBToYCbCr(
                    data: image.data, width: width, height: height,
                    componentCount: image.colorModel.componentCount
                )
                yPlane = planes.y
            }
            cbPlane = []
            crPlane = []
        } else {
            guard image.colorModel == .rgb || image.colorModel == .rgba
                || image.colorModel == .yCbCr
            else {
                throw JLIError.unsupportedColorSpaceConversion(
                    from: "\(image.colorModel)", to: "JPEG YCbCr"
                )
            }

            if image.colorModel == .yCbCr {
                // Already in YCbCr — extract planes directly
                let cc = image.colorModel.componentCount
                let pixelCount = width * height
                var y = [Float](repeating: 0, count: pixelCount)
                var cb = [Float](repeating: 0, count: pixelCount)
                var cr = [Float](repeating: 0, count: pixelCount)
                for i in 0..<pixelCount {
                    y[i] = Float(image.data[i * cc])
                    cb[i] = Float(image.data[i * cc + 1])
                    cr[i] = Float(image.data[i * cc + 2])
                }
                yPlane = y; cbPlane = cb; crPlane = cr
            } else if precision == 12 {
                // 12-bit color: little-endian UInt16 RGB(A), chroma centered at
                // the level-shift value (2^(P-1) = 2048).
                let planes = ColorConversion.imageRGB16ToYCbCr(
                    data: image.data, width: width, height: height,
                    componentCount: image.colorModel.componentCount, center: levelShift
                )
                yPlane = planes.y
                cbPlane = planes.cb
                crPlane = planes.cr
            } else {
                let planes = ColorConversion.imageRGBToYCbCr(
                    data: image.data, width: width, height: height,
                    componentCount: image.colorModel.componentCount
                )
                yPlane = planes.y
                cbPlane = planes.cb
                crPlane = planes.cr
            }
        }

        // Step 2: Chroma downsampling
        let subsampling = isGrayscale ? JLIChromaSubsampling.yuv400
            : configuration.chromaSubsampling
        let (hFactor, vFactor) = ChromaSampling.samplingFactors(for: subsampling)

        var cbWidth = width, cbHeight = height
        var crWidth = width, crHeight = height

        if !isGrayscale && (hFactor > 1 || vFactor > 1) {
            let cbDS = ChromaSampling.downsample(
                cbPlane, width: width, height: height,
                horizontally: hFactor > 1, vertically: vFactor > 1
            )
            cbPlane = cbDS.data; cbWidth = cbDS.width; cbHeight = cbDS.height

            let crDS = ChromaSampling.downsample(
                crPlane, width: width, height: height,
                horizontally: hFactor > 1, vertically: vFactor > 1
            )
            crPlane = crDS.data; crWidth = crDS.width; crHeight = crDS.height
        }

        // Step 3: Quantization tables (and reciprocals for vectorized quantization).
        let lumQT = Quantization.scaleTable(
            Quantization.standardLuminanceTable, quality: quality
        )
        let chromQT = Quantization.scaleTable(
            Quantization.standardChrominanceTable, quality: quality
        )
        let lumInv = lumQT.map { 1.0 / Float($0) }
        let chromInv = chromQT.map { 1.0 / Float($0) }

        // Rate-distortion (EOB) optimization, gated by `adaptiveQuantization`.
        // 8-bit only: 12-bit is the medical-precision path where we deliberately
        // keep exact round-to-nearest rather than trade detail for bytes.
        // λ trades DCT-domain squared error (= pixel² by Parseval) against bits,
        // scaled by the mean AC quant step² (see `rdoLambdaK`).
        let useRDO = configuration.adaptiveQuantization && precision == 8
        func meanACSq(_ table: [Int]) -> Double {
            var sum = 0.0
            for i in 1..<64 { sum += Double(table[i]) * Double(table[i]) }
            return sum / 63.0
        }
        let lumRDO = useRDO
            ? RDOContext(quantTable: lumQT, acTable: StandardHuffmanTables.acLuminance,
                         lambda: JLIEncoder.rdoLambdaK * meanACSq(lumQT))
            : nil
        let chrRDO = useRDO
            ? RDOContext(quantTable: chromQT, acTable: StandardHuffmanTables.acChrominance,
                         lambda: JLIEncoder.rdoLambdaK * meanACSq(chromQT))
            : nil

        // Step 4: MCU structure
        let hMax = isGrayscale ? 1 : hFactor
        let vMax = isGrayscale ? 1 : vFactor
        let mcuW = hMax * 8
        let mcuH = vMax * 8
        let mcuCountH = (width + mcuW - 1) / mcuW
        let mcuCountV = (height + mcuH - 1) / mcuH

        // Step 5: Extract → batch-DCT → batch-quantize for each component, then
        // walk MCUs sequentially to emit Huffman bits (DC DPCM forces sequential).
        let numComponents = isGrayscale ? 1 : 3
        let yBlocksPerRow = mcuCountH * hMax
        let yBlocksPerCol = mcuCountV * vMax
        let yBlockCount = yBlocksPerRow * yBlocksPerCol
        let cBlockCount = isGrayscale ? 0 : mcuCountH * mcuCountV

        // Scratch sized for the largest component batch — reused across Y/Cb/Cr.
        let maxBlockCount = max(yBlockCount, cBlockCount)
        var dctScratch = [Float](repeating: 0, count: maxBlockCount * 64)

        let yQuant = quantizePlane(
            yPlane, planeWidth: width, planeHeight: height,
            blocksH: yBlocksPerRow, blocksV: yBlocksPerCol,
            invQuant: lumInv, levelShift: levelShift, scratch: &dctScratch, rdo: lumRDO
        )
        let cbQuant: [Int32]
        let crQuant: [Int32]
        if isGrayscale {
            cbQuant = []; crQuant = []
        } else {
            cbQuant = quantizePlane(
                cbPlane, planeWidth: cbWidth, planeHeight: cbHeight,
                blocksH: mcuCountH, blocksV: mcuCountV,
                invQuant: chromInv, levelShift: levelShift, scratch: &dctScratch, rdo: chrRDO
            )
            crQuant = quantizePlane(
                crPlane, planeWidth: crWidth, planeHeight: crHeight,
                blocksH: mcuCountH, blocksV: mcuCountV,
                invQuant: chromInv, levelShift: levelShift, scratch: &dctScratch, rdo: chrRDO
            )
        }

        // Step 6: Assemble JPEG bitstream. Shared prefix: SOI, APP0, DQT.
        var mw = MarkerWriter()
        mw.writeSOI()
        mw.writeAPP0()
        let lumZZ = zigzagQuantTable(lumQT)
        if isGrayscale {
            mw.writeDQT(tables: [(id: 0, values: lumZZ)])
        } else {
            mw.writeDQT(tables: [(id: 0, values: lumZZ),
                                 (id: 1, values: zigzagQuantTable(chromQT))])
        }

        let sofComponents: [(id: UInt8, hSampling: Int, vSampling: Int, quantTableId: Int)] =
            isGrayscale
            ? [(1, 1, 1, 0)]
            : [(1, hMax, vMax, 0), (2, 1, 1, 1), (3, 1, 1, 1)]

        if configuration.progressive {
            // Progressive (SOF2): DC scan + per-component AC scans, optimal tables.
            mw.writeSOF(progressive: true, precision: precision, width: width, height: height,
                        components: sofComponents)
            let compInfos: [JPEGComponentInfo] = isGrayscale
                ? [JPEGComponentInfo(id: 1, horizontalSampling: 1, verticalSampling: 1, quantTableIndex: 0)]
                : [JPEGComponentInfo(id: 1, horizontalSampling: hMax, verticalSampling: vMax, quantTableIndex: 0),
                   JPEGComponentInfo(id: 2, horizontalSampling: 1, verticalSampling: 1, quantTableIndex: 1),
                   JPEGComponentInfo(id: 3, horizontalSampling: 1, verticalSampling: 1, quantTableIndex: 1)]
            let quantArrays = isGrayscale ? [yQuant] : [yQuant, cbQuant, crQuant]
            let bpr = isGrayscale ? [yBlocksPerRow] : [yBlocksPerRow, mcuCountH, mcuCountH]
            let rW = compInfos.map { (width * $0.horizontalSampling + hMax - 1) / hMax }
                .map { ($0 + 7) / 8 }
            let rH = compInfos.map { (height * $0.verticalSampling + vMax - 1) / vMax }
                .map { ($0 + 7) / 8 }
            let prog = ProgressiveEncoder(
                components: compInfos, isGrayscale: isGrayscale,
                mcuCountH: mcuCountH, mcuCountV: mcuCountV,
                blocksPerRow: bpr, realBlocksW: rW, realBlocksH: rH,
                quant: quantArrays
            )
            for scan in prog.build(mode: configuration.progressiveMode) {
                if !scan.dht.isEmpty { mw.writeDHT(tables: scan.dht) }
                mw.writeSOS(components: scan.sosComponents,
                            spectralStart: scan.ss, spectralEnd: scan.se,
                            successiveApproxHigh: scan.ah, successiveApproxLow: scan.al)
                mw.writeEntropyData(scan.entropy)
            }
            mw.writeEOI()
            return mw.data
        }

        // Baseline path below.
        // Step 5b: Select Huffman tables. With `optimiseHuffman`, run a counting
        // pass over the exact MCU walk the emit pass uses (DC DPCM state must
        // match) to gather per-image symbol frequencies, then build optimal
        // tables. Otherwise use the fixed Annex K tables.
        let dcLumTable: HuffmanTable
        let acLumTable: HuffmanTable
        let dcChrTable: HuffmanTable
        let acChrTable: HuffmanTable

        if optimiseHuffman {
            var dcLumFreq = [Int](repeating: 0, count: 256)
            var acLumFreq = [Int](repeating: 0, count: 256)
            var dcChrFreq = [Int](repeating: 0, count: 256)
            var acChrFreq = [Int](repeating: 0, count: 256)
            var prevDC = [Int32](repeating: 0, count: numComponents)
            var zigzagBuf = [Int32](repeating: 0, count: 64)
            // Restart resets DC predictors mid-scan; the counting pass must reset
            // at the same boundaries as the emit pass, or the optimal Huffman
            // table is built for the wrong DC-diff distribution and may lack codes
            // for the large post-reset diffs the emit pass produces.
            var countMCU = 0

            for mcuY in 0..<mcuCountV {
                for mcuX in 0..<mcuCountH {
                    if configuration.restartInterval > 0 && countMCU > 0
                        && countMCU % configuration.restartInterval == 0 {
                        for i in 0..<numComponents { prevDC[i] = 0 }
                    }
                    countMCU += 1
                    for by in 0..<vMax {
                        for bx in 0..<hMax {
                            let yIdx = (mcuY * vMax + by) * yBlocksPerRow + (mcuX * hMax + bx)
                            prevDC[0] = countBlock(
                                quantized: yQuant, blockIndex: yIdx, prevDC: prevDC[0],
                                zigzagBuf: &zigzagBuf, dcFreq: &dcLumFreq, acFreq: &acLumFreq
                            )
                        }
                    }
                    if !isGrayscale {
                        let cIdx = mcuY * mcuCountH + mcuX
                        prevDC[1] = countBlock(
                            quantized: cbQuant, blockIndex: cIdx, prevDC: prevDC[1],
                            zigzagBuf: &zigzagBuf, dcFreq: &dcChrFreq, acFreq: &acChrFreq
                        )
                        prevDC[2] = countBlock(
                            quantized: crQuant, blockIndex: cIdx, prevDC: prevDC[2],
                            zigzagBuf: &zigzagBuf, dcFreq: &dcChrFreq, acFreq: &acChrFreq
                        )
                    }
                }
            }

            dcLumTable = HuffmanTableBuilder.build(
                frequencies: dcLumFreq, fallback: StandardHuffmanTables.dcLuminance)
            acLumTable = HuffmanTableBuilder.build(
                frequencies: acLumFreq, fallback: StandardHuffmanTables.acLuminance)
            dcChrTable = HuffmanTableBuilder.build(
                frequencies: dcChrFreq, fallback: StandardHuffmanTables.dcChrominance)
            acChrTable = HuffmanTableBuilder.build(
                frequencies: acChrFreq, fallback: StandardHuffmanTables.acChrominance)
        } else {
            dcLumTable = StandardHuffmanTables.dcLuminance
            acLumTable = StandardHuffmanTables.acLuminance
            dcChrTable = StandardHuffmanTables.dcChrominance
            acChrTable = StandardHuffmanTables.acChrominance
        }

        // MCU walk → Huffman bitstream. Sequential because DC coefficients are
        // DPCM-coded against the previous block of the same component. Preallocate
        // the BitWriter buffer to the worst-case raw-RGB size so the inner loop
        // never reallocates.
        var bitWriter = BitWriter(estimatedMaxSize: width * height * 3 + 4096)
        var prevDC = [Int32](repeating: 0, count: numComponents)
        var zigzagBuf = [Int32](repeating: 0, count: 64)
        let restartInterval = configuration.restartInterval
        var mcuCount = 0
        var restartIndex = 0

        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                // Emit RSTn every `restartInterval` MCUs and reset DC predictors —
                // the exact inverse of the decoder's restart handling.
                if restartInterval > 0 && mcuCount > 0 && mcuCount % restartInterval == 0 {
                    bitWriter.emitRestartMarker(restartIndex)
                    restartIndex = (restartIndex + 1) & 7
                    for i in 0..<numComponents { prevDC[i] = 0 }
                }
                mcuCount += 1
                for by in 0..<vMax {
                    for bx in 0..<hMax {
                        let yIdx = (mcuY * vMax + by) * yBlocksPerRow + (mcuX * hMax + bx)
                        prevDC[0] = emitBlock(
                            quantized: yQuant, blockIndex: yIdx, prevDC: prevDC[0],
                            dcTable: dcLumTable, acTable: acLumTable,
                            zigzagBuf: &zigzagBuf, writer: &bitWriter
                        )
                    }
                }

                if !isGrayscale {
                    let cIdx = mcuY * mcuCountH + mcuX
                    prevDC[1] = emitBlock(
                        quantized: cbQuant, blockIndex: cIdx, prevDC: prevDC[1],
                        dcTable: dcChrTable, acTable: acChrTable,
                        zigzagBuf: &zigzagBuf, writer: &bitWriter
                    )
                    prevDC[2] = emitBlock(
                        quantized: crQuant, blockIndex: cIdx, prevDC: prevDC[2],
                        dcTable: dcChrTable, acTable: acChrTable,
                        zigzagBuf: &zigzagBuf, writer: &bitWriter
                    )
                }
            }
        }
        bitWriter.flush()

        // SOF0 (baseline) / SOF1 (12-bit) — precision 8 or 12.
        mw.writeSOF(progressive: false, precision: precision, width: width, height: height,
                    components: sofComponents)

        // DHT — embed whichever tables we actually encoded with (standard or
        // per-image optimal). The decoder reads these back from the DHT markers.
        var dhtTables: [(tableClass: Int, tableId: Int, bits: [UInt8], values: [UInt8])] = [
            (0, 0, dcLumTable.bits, dcLumTable.values),
            (1, 0, acLumTable.bits, acLumTable.values)
        ]
        if !isGrayscale {
            dhtTables.append((0, 1, dcChrTable.bits, dcChrTable.values))
            dhtTables.append((1, 1, acChrTable.bits, acChrTable.values))
        }
        mw.writeDHT(tables: dhtTables)

        // DRI (define restart interval) before the scan, when restart is enabled.
        if restartInterval > 0 {
            mw.writeDRI(interval: restartInterval)
        }

        // SOS + entropy data
        if isGrayscale {
            mw.writeSOS(components: [(selector: 1, dcTableId: 0, acTableId: 0)])
        } else {
            mw.writeSOS(components: [
                (selector: 1, dcTableId: 0, acTableId: 0),
                (selector: 2, dcTableId: 1, acTableId: 1),
                (selector: 3, dcTableId: 1, acTableId: 1)
            ])
        }
        mw.writeEntropyData(bitWriter.data)
        mw.writeEOI()

        return mw.data
    }

    // MARK: - Lossless (SOF3) encode

    /// Encodes a lossless (SOF3) JPEG by spatial prediction (ITU-T T.81 Annex H):
    /// each sample's difference from a neighbour-based predictor (selector 1–7) is
    /// Huffman-coded with the DC mechanism. Bit-for-bit lossless. Grayscale only.
    private func encodeLossless(
        _ image: JLIImage, configuration: JLIEncoderConfiguration,
        precision: Int, isGrayscale: Bool
    ) throws -> [UInt8] {
        guard isGrayscale else {
            throw JLIError.unsupportedColorSpaceConversion(
                from: "\(image.colorModel)", to: "lossless JPEG (grayscale only)")
        }
        let predictor = configuration.losslessPredictor
        guard (1...7).contains(predictor) else {
            throw JLIError.unsupportedJPEGFeature("lossless predictor \(predictor) (1–7)")
        }
        let w = image.width, h = image.height

        // Read samples (8-bit direct, 12-bit little-endian uint16).
        var samples = [Int32](repeating: 0, count: w * h)
        if precision == 8 {
            for i in 0..<(w * h) { samples[i] = Int32(image.data[i]) }
        } else {
            for i in 0..<(w * h) {
                samples[i] = Int32(UInt16(image.data[i * 2]) | (UInt16(image.data[i * 2 + 1]) << 8))
            }
        }

        let half = Int32(1 << (precision - 1))
        func predict(_ x: Int, _ y: Int) -> Int32 {
            if x == 0 { return y == 0 ? half : samples[(y - 1) * w] }          // Rb / initial
            if y == 0 { return samples[y * w + x - 1] }                        // Ra
            let ra = samples[y * w + x - 1]
            let rb = samples[(y - 1) * w + x]
            let rc = samples[(y - 1) * w + x - 1]
            switch predictor {
            case 1: return ra
            case 2: return rb
            case 3: return rc
            case 4: return ra + rb - rc
            case 5: return ra + ((rb - rc) >> 1)
            case 6: return rb + ((ra - rc) >> 1)
            default: return (ra + rb) >> 1                                     // 7
            }
        }
        // Difference modulo 2^16, mapped to signed 16-bit (T.81). Category 16 is
        // the special case for −32768 (no additional bits).
        func diffOf(_ x: Int, _ y: Int) -> Int32 {
            var d = (samples[y * w + x] - predict(x, y)) & 0xFFFF
            if d >= 32768 { d -= 65536 }
            return d
        }

        // Counting pass → optimal DC Huffman table over difference categories.
        var dcFreq = [Int](repeating: 0, count: 256)
        for y in 0..<h {
            for x in 0..<w {
                let d = diffOf(x, y)
                dcFreq[d == -32768 ? 16 : HuffmanEncoder.category(for: d)] += 1
            }
        }
        let table = HuffmanTableBuilder.build(
            frequencies: dcFreq, fallback: StandardHuffmanTables.dcLuminance)

        // Emit pass.
        var mw = MarkerWriter()
        mw.writeSOI()
        mw.writeAPP0()
        mw.writeSOF(progressive: false, precision: precision, width: w, height: h,
                    components: [(1, 1, 1, 0)], lossless: true)
        mw.writeDHT(tables: [(0, 0, table.bits, table.values)])
        mw.writeSOS(components: [(selector: 1, dcTableId: 0, acTableId: 0)],
                    spectralStart: predictor, spectralEnd: 0,
                    successiveApproxHigh: 0, successiveApproxLow: 0)

        var bw = BitWriter(estimatedMaxSize: w * h * 2 + 1024)
        for y in 0..<h {
            for x in 0..<w {
                let d = diffOf(x, y)
                let cat = d == -32768 ? 16 : HuffmanEncoder.category(for: d)
                let e = table.encodingTable[cat]
                bw.writeBits(UInt32(e.code), count: Int(e.length))
                if cat > 0 && cat < 16 {
                    bw.writeBits(HuffmanEncoder.additionalBits(for: d, category: cat), count: cat)
                }
            }
        }
        bw.flush()
        mw.writeEntropyData(bw.data)
        mw.writeEOI()
        return mw.data
    }

    // MARK: - Private Helpers

    /// Validates the encoder configuration, throwing on invalid parameters.
    private func validateConfiguration(_ configuration: JLIEncoderConfiguration) throws {
        guard configuration.quality >= 0.0, configuration.quality <= 100.0 else {
            throw JLIError.invalidQuality(configuration.quality)
        }
        if let distance = configuration.distance {
            guard distance >= 0.0 else {
                throw JLIError.invalidDistance(distance)
            }
        }
    }

    /// Extract every 8×8 block from a component plane → batched forward DCT +
    /// quantize. Returns an Int32 buffer of size `blocksH*blocksV*64` holding
    /// quantized coefficients in natural (non-zigzag) order, per-block-contiguous.
    ///
    /// Level-shift (-128) is folded into the extract pass so we don't pay a
    /// separate read+write sweep over the whole batched buffer. Edge pixels are
    /// replicated when the plane dimensions aren't a multiple of 8.
    private func quantizePlane(
        _ plane: [Float], planeWidth: Int, planeHeight: Int,
        blocksH: Int, blocksV: Int,
        invQuant: [Float], levelShift: Float, scratch: inout [Float],
        rdo: RDOContext? = nil
    ) -> [Int32] {
        let n = blocksH * blocksV
        var blockBuf = [Float](repeating: 0, count: n * 64)
        extractAllBlocksLevelShifted(
            plane, planeWidth: planeWidth, planeHeight: planeHeight,
            blocksH: blocksH, blocksV: blocksV, levelShift: levelShift, into: &blockBuf
        )

        var dctBuf = [Float](repeating: 0, count: n * 64)
        AccelerateDSP.forwardDCTBatch(
            blockBuf, into: &dctBuf, scratch: &scratch, blockCount: n
        )

        var quant = [Int32](repeating: 0, count: n * 64)
        AccelerateDSP.quantizeBatch(
            dctBuf, invTable: invQuant, into: &quant, blockCount: n
        )
        if let rdo = rdo {
            applyTrellisQuantization(dctBuf: dctBuf, quant: &quant, blockCount: n, rdo: rdo)
        }
        return quant
    }

    /// Rate-distortion context for trellis-style quantization. `quantTable` is
    /// the forward quant table (natural order); `acTable` provides the bit-length
    /// rate model; `lambda` trades distortion (DCT coeff², = pixel² by Parseval)
    /// against rate (bits).
    struct RDOContext {
        let quantTable: [Int]
        let acTable: HuffmanTable
        let lambda: Double
    }

    /// Trellis quantization: for each block, a Viterbi DP chooses, for every
    /// nonzero AC coefficient, whether to drop it (→0), reduce its magnitude by
    /// one step (q→q∓1 toward zero), or keep it — minimizing D + λ·R: DCT-domain
    /// squared error (= pixel² by Parseval) against the run-length-coded bits.
    ///
    /// Dropping interior coefficients merges the surrounding zero runs; magnitude
    /// reduction trims a coefficient's size category and additional bits. The EOB
    /// choice falls out as "which kept coefficient is last." Magnitudes are only
    /// ever reduced, never grown, so output stays standard baseline JPEG; the
    /// rate model uses the fixed Annex K table lengths, sidestepping the
    /// chicken-and-egg with optimized Huffman (built afterward).
    ///
    /// State = (candidate, variant ∈ {full q, reduced q∓1}); transitions account
    /// for the inter-coefficient run (incl. ZRL). O(m²) per block in the nonzero
    /// AC count m; high-entropy blocks (m large) skip the DP.
    private func applyTrellisQuantization(
        dctBuf: [Float], quant: inout [Int32], blockCount: Int, rdo: RDOContext
    ) {
        let zz = Quantization.zigzagOrder
        let lambda = rdo.lambda
        let eobLen = Int(rdo.acTable.encodingTable[0x00].length)
        let zrlLen = Int(rdo.acTable.encodingTable[0xF0].length)

        // Bits to emit a nonzero of category `size` after `run` preceding zeros.
        func symbolBits(run: Int, size: Int) -> Int {
            var bits = 0
            var r = run
            while r > 15 { bits += zrlLen; r -= 16 }
            bits += Int(rdo.acTable.encodingTable[(r << 4) | size].length) + size
            return bits
        }

        // Per-block scratch. Each nonzero candidate has up to two "kept" variants
        // (full, reduced); states are flattened as candidate*2 + variant.
        let maxN = JLIEncoder.trellisMaxNonzeros
        var nz = [Int](repeating: 0, count: 64)              // zigzag position
        var dropDist = [Double](repeating: 0, count: 64)     // distortion if zeroed
        var cumDrop = [Double](repeating: 0, count: 65)
        var vCount = [Int](repeating: 0, count: 64)          // 1 or 2 variants
        var vVal = [Int32](repeating: 0, count: 128)         // quantized value
        var vDist = [Double](repeating: 0, count: 128)       // distortion if kept at variant
        var vSize = [Int](repeating: 0, count: 128)          // category
        var dp = [Double](repeating: 0, count: 128)
        var prevState = [Int](repeating: -1, count: 128)     // previous (candidate*2+variant), or -1
        var chosen = [Int](repeating: -1, count: 64)         // backtracked variant per candidate, -1 = dropped

        for b in 0..<blockCount {
            let base = b * 64
            var m = 0
            for z in 1..<64 {
                let q = quant[base + zz[z]]
                if q == 0 { continue }
                let nat = zz[z]
                let c = Double(dctBuf[base + nat])
                let qf = Double(rdo.quantTable[nat])
                nz[m] = z
                dropDist[m] = c * c
                // Variant 0: full magnitude.
                let reconF = Double(q) * qf
                vVal[m * 2] = q
                vDist[m * 2] = (c - reconF) * (c - reconF)
                vSize[m * 2] = HuffmanEncoder.category(for: q)
                // Variant 1: magnitude reduced one step toward zero (if still
                // nonzero). Restricted to higher-frequency positions — reducing
                // the lowest AC frequencies trims perceptually-visible energy
                // (butteraugli regresses), while HF reduction is near-invisible.
                let qr = q > 0 ? q - 1 : q + 1
                if qr != 0 && z >= JLIEncoder.trellisReduceMinZigzag {
                    let reconR = Double(qr) * qf
                    vVal[m * 2 + 1] = qr
                    vDist[m * 2 + 1] = (c - reconR) * (c - reconR)
                    vSize[m * 2 + 1] = HuffmanEncoder.category(for: qr)
                    vCount[m] = 2
                } else {
                    vCount[m] = 1  // |q| == 1: reducing == dropping, already covered
                }
                m += 1
            }
            if m == 0 || m > maxN { continue }

            cumDrop[0] = 0
            for k in 0..<m { cumDrop[k + 1] = cumDrop[k] + dropDist[k] }

            // dp[state] = min (Σ distortion + λ·rate) ending with candidate i kept
            // at variant v as the last-kept-so-far.
            for i in 0..<m {
                for v in 0..<vCount[i] {
                    let s = i * 2 + v
                    let keepBits = lambda * Double(symbolBits(run: nz[i] - 1, size: vSize[s]))
                    var best = cumDrop[i] + keepBits + vDist[s]   // j = -1 (start)
                    var bestPrev = -1
                    for j in 0..<i {
                        let between = cumDrop[i] - cumDrop[j + 1]
                        let run = nz[i] - nz[j] - 1
                        let rate = lambda * Double(symbolBits(run: run, size: vSize[s]))
                        for vj in 0..<vCount[j] {
                            let cost = dp[j * 2 + vj] + between + rate + vDist[s]
                            if cost < best { best = cost; bestPrev = j * 2 + vj }
                        }
                    }
                    dp[s] = best
                    prevState[s] = bestPrev
                }
            }

            // Final: last-kept (i, v) + EOB (unless at position 63), or keep nothing.
            var bestCost = cumDrop[m] + lambda * Double(eobLen)
            var bestState = -1
            for i in 0..<m {
                let afterDrop = cumDrop[m] - cumDrop[i + 1]
                let eobCost = nz[i] < 63 ? lambda * Double(eobLen) : 0.0
                for v in 0..<vCount[i] {
                    let cost = dp[i * 2 + v] + afterDrop + eobCost
                    if cost < bestCost { bestCost = cost; bestState = i * 2 + v }
                }
            }

            // Backtrack chosen variant per candidate (-1 = dropped).
            for k in 0..<m { chosen[k] = -1 }
            var st = bestState
            while st >= 0 {
                chosen[st / 2] = st % 2
                st = prevState[st]
            }
            // Write decided values back (drop → 0, else the variant's value).
            for k in 0..<m {
                let nat = zz[nz[k]]
                quant[base + nat] = chosen[k] < 0 ? 0 : vVal[k * 2 + chosen[k]]
            }
        }
    }

    /// Extracts `blocksH × blocksV` 8×8 blocks from a plane into a per-block-contig
    /// Float buffer with the level shift (`-2^(P-1)`: 128 for 8-bit, 2048 for
    /// 12-bit) folded in. Block `i` at offset `64*i`, row-major within. Edge
    /// pixels are replicated past plane bounds.
    private func extractAllBlocksLevelShifted(
        _ plane: [Float], planeWidth: Int, planeHeight: Int,
        blocksH: Int, blocksV: Int, levelShift: Float, into out: inout [Float]
    ) {
        plane.withUnsafeBufferPointer { srcBuf in
            out.withUnsafeMutableBufferPointer { dstBuf in
                let src = srcBuf.baseAddress!
                let dst = dstBuf.baseAddress!
                for by in 0..<blocksV {
                    let startY = by * 8
                    for bx in 0..<blocksH {
                        let startX = bx * 8
                        let blockBase = (by * blocksH + bx) * 64
                        for r in 0..<8 {
                            let sy = min(startY + r, planeHeight - 1)
                            let srcRow = sy * planeWidth
                            let dstRow = blockBase + r * 8
                            for c in 0..<8 {
                                let sx = min(startX + c, planeWidth - 1)
                                dst[dstRow + c] = src[srcRow + sx] - levelShift
                            }
                        }
                    }
                }
            }
        }
    }

    /// Read one block's quantized coefficients out of the batched buffer, zigzag
    /// directly from there, and emit DC (DPCM against `prevDC`) + AC Huffman codes.
    /// Returns the new DC value for the next block's prediction.
    @inline(__always)
    private func emitBlock(
        quantized: [Int32], blockIndex: Int, prevDC: Int32,
        dcTable: HuffmanTable, acTable: HuffmanTable,
        zigzagBuf: inout [Int32],
        writer: inout BitWriter
    ) -> Int32 {
        Quantization.zigzagScan(quantized, offset: blockIndex * 64, into: &zigzagBuf)

        let dcDiff = zigzagBuf[0] - prevDC
        HuffmanEncoder.encodeDC(dcDiff, table: dcTable, writer: &writer)
        HuffmanEncoder.encodeAC(zigzagBuf, table: acTable, writer: &writer)
        return zigzagBuf[0]
    }

    /// Counting analogue of ``emitBlock`` — gathers DC/AC symbol frequencies for
    /// optimal-table generation. Must walk identically to the emit pass so the
    /// DC DPCM predictor stays in lockstep. Returns the block's DC value.
    @inline(__always)
    private func countBlock(
        quantized: [Int32], blockIndex: Int, prevDC: Int32,
        zigzagBuf: inout [Int32], dcFreq: inout [Int], acFreq: inout [Int]
    ) -> Int32 {
        Quantization.zigzagScan(quantized, offset: blockIndex * 64, into: &zigzagBuf)
        HuffmanEncoder.countDC(zigzagBuf[0] - prevDC, freq: &dcFreq)
        HuffmanEncoder.countAC(zigzagBuf, freq: &acFreq)
        return zigzagBuf[0]
    }

    /// Reorders a quantization table to zigzag order for the DQT marker.
    private func zigzagQuantTable(_ table: [Int]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 {
            result[i] = UInt8(clamping: table[Quantization.zigzagOrder[i]])
        }
        return result
    }
}
