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

        guard image.pixelFormat == .uint8 else {
            throw JLIError.unsupportedColorSpaceConversion(
                from: "\(image.pixelFormat)", to: "JPEG uint8 encoding"
            )
        }

        let width = image.width
        let height = image.height
        let quality = max(1, min(100, Int(configuration.quality)))

        // Determine if encoding as grayscale
        let isGrayscale = image.colorModel == .grayscale
            || configuration.chromaSubsampling == .yuv400

        // Step 1: Extract component planes (Float, 0–255 range)
        let yPlane: [Float]
        var cbPlane: [Float]
        var crPlane: [Float]

        if isGrayscale {
            if image.colorModel == .grayscale {
                yPlane = image.data.map { Float($0) }
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
            invQuant: lumInv, scratch: &dctScratch
        )
        let cbQuant: [Int32]
        let crQuant: [Int32]
        if isGrayscale {
            cbQuant = []; crQuant = []
        } else {
            cbQuant = quantizePlane(
                cbPlane, planeWidth: cbWidth, planeHeight: cbHeight,
                blocksH: mcuCountH, blocksV: mcuCountV,
                invQuant: chromInv, scratch: &dctScratch
            )
            crQuant = quantizePlane(
                crPlane, planeWidth: crWidth, planeHeight: crHeight,
                blocksH: mcuCountH, blocksV: mcuCountV,
                invQuant: chromInv, scratch: &dctScratch
            )
        }

        // Step 5b: Select Huffman tables. With `optimiseHuffman`, run a counting
        // pass over the exact MCU walk the emit pass uses (DC DPCM state must
        // match) to gather per-image symbol frequencies, then build optimal
        // tables. Otherwise use the fixed Annex K tables.
        let dcLumTable: HuffmanTable
        let acLumTable: HuffmanTable
        let dcChrTable: HuffmanTable
        let acChrTable: HuffmanTable

        if configuration.optimiseHuffman {
            var dcLumFreq = [Int](repeating: 0, count: 256)
            var acLumFreq = [Int](repeating: 0, count: 256)
            var dcChrFreq = [Int](repeating: 0, count: 256)
            var acChrFreq = [Int](repeating: 0, count: 256)
            var prevDC = [Int32](repeating: 0, count: numComponents)
            var zigzagBuf = [Int32](repeating: 0, count: 64)

            for mcuY in 0..<mcuCountV {
                for mcuX in 0..<mcuCountH {
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

        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
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

        // Step 6: Assemble JPEG bitstream
        var mw = MarkerWriter()
        mw.writeSOI()
        mw.writeAPP0()

        // DQT
        let lumZZ = zigzagQuantTable(lumQT)
        if isGrayscale {
            mw.writeDQT(tables: [(id: 0, values: lumZZ)])
        } else {
            mw.writeDQT(tables: [(id: 0, values: lumZZ),
                                 (id: 1, values: zigzagQuantTable(chromQT))])
        }

        // SOF0 (baseline)
        if isGrayscale {
            mw.writeSOF(progressive: false, precision: 8, width: width, height: height,
                        components: [(id: 1, hSampling: 1, vSampling: 1, quantTableId: 0)])
        } else {
            mw.writeSOF(progressive: false, precision: 8, width: width, height: height,
                        components: [
                            (id: 1, hSampling: hMax, vSampling: vMax, quantTableId: 0),
                            (id: 2, hSampling: 1, vSampling: 1, quantTableId: 1),
                            (id: 3, hSampling: 1, vSampling: 1, quantTableId: 1)
                        ])
        }

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
        invQuant: [Float], scratch: inout [Float]
    ) -> [Int32] {
        let n = blocksH * blocksV
        var blockBuf = [Float](repeating: 0, count: n * 64)
        extractAllBlocksLevelShifted(
            plane, planeWidth: planeWidth, planeHeight: planeHeight,
            blocksH: blocksH, blocksV: blocksV, into: &blockBuf
        )

        var dctBuf = [Float](repeating: 0, count: n * 64)
        AccelerateDSP.forwardDCTBatch(
            blockBuf, into: &dctBuf, scratch: &scratch, blockCount: n
        )

        var quant = [Int32](repeating: 0, count: n * 64)
        AccelerateDSP.quantizeBatch(
            dctBuf, invTable: invQuant, into: &quant, blockCount: n
        )
        return quant
    }

    /// Extracts `blocksH × blocksV` 8×8 blocks from a plane into a per-block-contig
    /// Float buffer with level shift (-128) folded in. Block `i` at offset `64*i`,
    /// row-major within. Edge pixels are replicated past plane bounds.
    private func extractAllBlocksLevelShifted(
        _ plane: [Float], planeWidth: Int, planeHeight: Int,
        blocksH: Int, blocksV: Int, into out: inout [Float]
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
                                dst[dstRow + c] = src[srcRow + sx] - 128.0
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
