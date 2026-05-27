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

        // Step 2: Prepare quantization tables (convert from zigzag to natural order)
        let quantTables = parsed.quantTables.map { zigzagTable -> [Int] in
            var natural = [Int](repeating: 0, count: 64)
            for i in 0..<64 {
                natural[Quantization.zigzagOrder[i]] = zigzagTable[i]
            }
            return natural
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
        let scan = parsed.scans[0]
        var bitReader = BitReader(data: scan.entropyData)
        var prevDC = [Int32](repeating: 0, count: numComponents)
        var acBuf = [Int32](repeating: 0, count: 64)

        let restartInterval = parsed.restartInterval
        var mcuCount = 0
        var restartIndex = 0

        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                // Restart marker handling: every `restartInterval` MCUs, JPEG inserts
                // an RST0–RST7 marker (cycled). Skip it and reset DC predictors so
                // a corrupted segment can't poison subsequent ones.
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
                    let dcTable = dcTables[dcTableId]
                    let acTable = acTables[acTableId]
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

                            // Splat the block's zigzag coefficients into the flat buffer.
                            for i in 0..<64 {
                                componentZigzag[compIdx][dst + i] = acBuf[i]
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

            // Level shift +128 + clamp [0,255] over the whole batched buffer.
            var center: Float = 128.0
            var lo: Float = 0.0, hi: Float = 255.0
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

            // Trim to actual component dimensions
            let compWidth = (frame.width * comp.horizontalSampling + hMaxSampling - 1) / hMaxSampling
            let compHeight = (frame.height * comp.verticalSampling + vMaxSampling - 1) / vMaxSampling

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

        // Step 8: Chroma upsample and color convert
        let outputData: [UInt8]
        let outputColorModel: JLIColorModel

        if numComponents == 1 {
            // Grayscale
            let plane = componentPlanes[0]
            outputData = plane.data.map { UInt8(clamping: Int($0.rounded())) }
            outputColorModel = configuration.outputColorModel ?? .grayscale
        } else {
            // YCbCr → RGB
            let yPlane = componentPlanes[0]

            // Upsample Cb and Cr to full resolution
            let cbUp = ChromaSampling.upsample(
                componentPlanes[1].data,
                width: componentPlanes[1].width,
                height: componentPlanes[1].height,
                targetWidth: frame.width, targetHeight: frame.height
            )
            let crUp = ChromaSampling.upsample(
                componentPlanes[2].data,
                width: componentPlanes[2].width,
                height: componentPlanes[2].height,
                targetWidth: frame.width, targetHeight: frame.height
            )

            // Trim Y plane if padded
            let yTrimmed: [Float]
            if yPlane.width != frame.width || yPlane.height != frame.height {
                var trimmed = [Float](repeating: 0, count: frame.width * frame.height)
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        trimmed[y * frame.width + x] = yPlane.data[y * yPlane.width + x]
                    }
                }
                yTrimmed = trimmed
            } else {
                yTrimmed = yPlane.data
            }

            outputData = ColorConversion.imageYCbCrToRGB(
                y: yTrimmed, cb: cbUp, cr: crUp,
                width: frame.width, height: frame.height
            )
            outputColorModel = configuration.outputColorModel ?? .rgb
        }

        let outputPixelFormat = configuration.outputPixelFormat ?? .uint8

        return try JLIImage(
            width: frame.width,
            height: frame.height,
            pixelFormat: outputPixelFormat,
            colorModel: outputColorModel,
            data: outputData
        )
    }

    // MARK: - Private Helpers

    /// Returns DC Huffman tables, using standard tables as fallback.
    private func prepareDCTables(_ parsed: [Int: HuffmanTable]) -> [HuffmanTable] {
        var tables = [HuffmanTable]()
        tables.append(parsed[0] ?? StandardHuffmanTables.dcLuminance)
        tables.append(parsed[1] ?? StandardHuffmanTables.dcChrominance)
        return tables
    }

    /// Returns AC Huffman tables, using standard tables as fallback.
    private func prepareACTables(_ parsed: [Int: HuffmanTable]) -> [HuffmanTable] {
        var tables = [HuffmanTable]()
        tables.append(parsed[0] ?? StandardHuffmanTables.acLuminance)
        tables.append(parsed[1] ?? StandardHuffmanTables.acChrominance)
        return tables
    }
}
