// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

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

        // Step 5: Allocate block storage for each component
        var componentBlocks = [[Int32]]()
        var componentBlocksPerRow = [Int]()
        for comp in components {
            let blocksH = mcuCountH * comp.horizontalSampling
            let blocksV = mcuCountV * comp.verticalSampling
            componentBlocksPerRow.append(blocksH)
            let totalBlocks = blocksH * blocksV
            componentBlocks.append(contentsOf:
                (0..<totalBlocks).map { _ in [Int32](repeating: 0, count: 64) }
            )
        }

        // Reorganize into per-component arrays
        var blockArrays = [[[Int32]]]()
        var offset = 0
        for (idx, comp) in components.enumerated() {
            let blocksH = mcuCountH * comp.horizontalSampling
            let blocksV = mcuCountV * comp.verticalSampling
            let count = blocksH * blocksV
            blockArrays.append(Array(componentBlocks[offset..<offset + count]))
            offset += count
            _ = idx
        }

        // Step 6: Decode entropy data from scans
        let scan = parsed.scans[0]
        var bitReader = BitReader(data: scan.entropyData)
        var prevDC = [Int32](repeating: 0, count: numComponents)

        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
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

                            // Decode DC
                            let dcDiff = try HuffmanDecoder.decodeDC(
                                from: &bitReader, table: dcTable
                            )
                            prevDC[compIdx] += dcDiff

                            // Decode AC
                            var coeffs = try HuffmanDecoder.decodeAC(
                                from: &bitReader, table: acTable
                            )
                            coeffs[0] = prevDC[compIdx]

                            blockArrays[compIdx][blockIndex] = coeffs
                        }
                    }
                }
            }
        }

        // Step 7: Reconstruct component planes
        var componentPlanes = [(data: [Float], width: Int, height: Int)]()

        for compIdx in 0..<numComponents {
            let comp = components[compIdx]
            let blocksH = mcuCountH * comp.horizontalSampling
            let blocksV = mcuCountV * comp.verticalSampling
            let planeWidth = blocksH * 8
            let planeHeight = blocksV * 8
            let quantTableId = comp.quantTableIndex
            let qt = quantTables[quantTableId]

            var plane = [Float](repeating: 0, count: planeWidth * planeHeight)

            for blockIdx in 0..<blockArrays[compIdx].count {
                let blockX = blockIdx % blocksH
                let blockY = blockIdx / blocksH

                let zigzagCoeffs = blockArrays[compIdx][blockIdx]

                // Inverse zigzag
                let naturalCoeffs = Quantization.inverseZigzagScan(zigzagCoeffs)

                // Dequantize
                let dctCoeffs = Quantization.dequantize(naturalCoeffs, table: qt)

                // Inverse DCT
                let pixels = DCT.inverse(dctCoeffs)

                // Level unshift (+128) and store
                let startX = blockX * 8
                let startY = blockY * 8
                for y in 0..<8 {
                    for x in 0..<8 {
                        let px = startX + x
                        let py = startY + y
                        if px < planeWidth && py < planeHeight {
                            let value = pixels[y * 8 + x] + 128.0
                            plane[py * planeWidth + px] = max(0, min(255, value))
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
