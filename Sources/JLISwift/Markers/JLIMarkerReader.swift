// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// JPEG marker reader and parser for the decoder pipeline.
///
/// Parses JPEG marker segments to extract frame information, quantization tables,
/// Huffman tables, and entropy-coded scan data.

// MARK: - Parsed JPEG Data Structures

/// Information about a single JPEG component from the SOF marker.
struct JPEGComponentInfo: Sendable {
    let id: UInt8
    let horizontalSampling: Int
    let verticalSampling: Int
    let quantTableIndex: Int
}

/// Frame header information from the SOF marker.
struct JPEGFrameInfo: Sendable {
    let precision: Int
    let width: Int
    let height: Int
    let components: [JPEGComponentInfo]
    let isProgressive: Bool
}

/// Scan header information from the SOS marker.
struct JPEGScanHeader: Sendable {
    let components: [(componentSelector: UInt8, dcTableId: Int, acTableId: Int)]
    let spectralStart: Int
    let spectralEnd: Int
    let successiveApproxHigh: Int
    let successiveApproxLow: Int
}

/// A single scan's data extracted from the JPEG stream.
struct JPEGScanData: Sendable {
    let header: JPEGScanHeader
    let entropyData: [UInt8]
}

/// Fully parsed JPEG data ready for decoding.
struct ParsedJPEG: Sendable {
    let frameInfo: JPEGFrameInfo
    let quantTables: [[Int]]
    let huffmanDCTables: [Int: HuffmanTable]
    let huffmanACTables: [Int: HuffmanTable]
    let scans: [JPEGScanData]
}

// MARK: - Marker Reader

/// Reads and parses JPEG marker segments from a byte buffer.
struct MarkerReader {
    private let data: [UInt8]
    private var offset: Int = 0

    init(data: [UInt8]) {
        self.data = data
    }

    /// Reads JPEG info without full decode.
    mutating func readInfo() throws -> JLIJPEGInfo {
        try validateSOI()

        var frameInfo: JPEGFrameInfo?

        while offset < data.count - 1 {
            guard let marker = try nextMarker() else { break }

            switch marker {
            case JPEGMarker.sof0, JPEGMarker.sof2:
                frameInfo = try readSOF(progressive: marker == JPEGMarker.sof2)

            case JPEGMarker.eoi:
                break

            case JPEGMarker.sos:
                // Skip scan data for info-only parsing
                break

            default:
                try skipSegment()
            }

            if frameInfo != nil {
                break  // We have what we need
            }
        }

        guard let frame = frameInfo else {
            throw JLIError.invalidJPEGData
        }

        let subsampling = detectChromaSubsampling(frame.components)

        return JLIJPEGInfo(
            width: frame.width,
            height: frame.height,
            componentCount: frame.components.count,
            bitsPerComponent: frame.precision,
            isProgressive: frame.isProgressive,
            isXYB: false,
            isExtendedPrecision: frame.precision > 8,
            chromaSubsampling: subsampling
        )
    }

    /// Fully parses the JPEG stream, extracting all tables and scan data.
    mutating func parse() throws -> ParsedJPEG {
        try validateSOI()

        var frameInfo: JPEGFrameInfo?
        var quantTables = [[Int]](repeating: [Int](repeating: 0, count: 64), count: 4)
        var huffDC = [Int: HuffmanTable]()
        var huffAC = [Int: HuffmanTable]()
        var scans: [JPEGScanData] = []

        while offset < data.count - 1 {
            guard let marker = try nextMarker() else { break }

            switch marker {
            case JPEGMarker.sof0, JPEGMarker.sof2:
                frameInfo = try readSOF(progressive: marker == JPEGMarker.sof2)

            case JPEGMarker.dqt:
                let tables = try readDQT()
                for (id, values) in tables {
                    quantTables[id] = values
                }

            case JPEGMarker.dht:
                let tables = try readDHT()
                for (tableClass, tableId, table) in tables {
                    if tableClass == 0 {
                        huffDC[tableId] = table
                    } else {
                        huffAC[tableId] = table
                    }
                }

            case JPEGMarker.sos:
                let scanHeader = try readSOS()
                let entropyData = try readEntropyData()
                scans.append(JPEGScanData(header: scanHeader, entropyData: entropyData))

            case JPEGMarker.eoi:
                break

            default:
                try skipSegment()
            }
        }

        guard let frame = frameInfo else {
            throw JLIError.invalidJPEGData
        }

        return ParsedJPEG(
            frameInfo: frame,
            quantTables: quantTables,
            huffmanDCTables: huffDC,
            huffmanACTables: huffAC,
            scans: scans
        )
    }

    // MARK: - Private Parsing Methods

    private mutating func validateSOI() throws {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw JLIError.invalidJPEGData
        }
        offset = 2
    }

    /// Reads the next marker byte, skipping padding 0xFF bytes.
    private mutating func nextMarker() throws -> UInt8? {
        while offset < data.count {
            if data[offset] == 0xFF {
                offset += 1
                // Skip padding 0xFF bytes
                while offset < data.count && data[offset] == 0xFF {
                    offset += 1
                }
                if offset < data.count && data[offset] != 0x00 {
                    let marker = data[offset]
                    offset += 1
                    return marker
                }
            } else {
                offset += 1
            }
        }
        return nil
    }

    /// Reads the segment length and skips past the segment data.
    private mutating func skipSegment() throws {
        let length = try readUInt16()
        let skip = Int(length) - 2
        guard skip >= 0, offset + skip <= data.count else {
            throw JLIError.decodingFailed("Invalid segment length")
        }
        offset += skip
    }

    /// Reads a SOF (Start of Frame) marker.
    private mutating func readSOF(progressive: Bool) throws -> JPEGFrameInfo {
        let length = try readUInt16()
        let endOffset = offset + Int(length) - 2

        let precision = Int(try readByte())
        let height = Int(try readUInt16())
        let width = Int(try readUInt16())
        let numComponents = Int(try readByte())

        var components = [JPEGComponentInfo]()
        for _ in 0..<numComponents {
            let id = try readByte()
            let sampling = try readByte()
            let quantId = try readByte()
            components.append(JPEGComponentInfo(
                id: id,
                horizontalSampling: Int(sampling >> 4),
                verticalSampling: Int(sampling & 0x0F),
                quantTableIndex: Int(quantId)
            ))
        }

        offset = endOffset
        return JPEGFrameInfo(
            precision: precision,
            width: width,
            height: height,
            components: components,
            isProgressive: progressive
        )
    }

    /// Reads a DQT (Define Quantization Table) marker.
    private mutating func readDQT() throws -> [(id: Int, values: [Int])] {
        let length = Int(try readUInt16())
        let endOffset = offset + length - 2
        var tables = [(id: Int, values: [Int])]()

        while offset < endOffset {
            let info = try readByte()
            let precision = Int(info >> 4)
            let tableId = Int(info & 0x0F)

            var values = [Int](repeating: 0, count: 64)
            for i in 0..<64 {
                if precision == 0 {
                    values[i] = Int(try readByte())
                } else {
                    values[i] = Int(try readUInt16())
                }
            }
            tables.append((id: tableId, values: values))
        }

        return tables
    }

    /// Reads a DHT (Define Huffman Table) marker.
    private mutating func readDHT() throws -> [(tableClass: Int, tableId: Int, table: HuffmanTable)] {
        let length = Int(try readUInt16())
        let endOffset = offset + length - 2
        var tables = [(tableClass: Int, tableId: Int, table: HuffmanTable)]()

        while offset < endOffset {
            let info = try readByte()
            let tableClass = Int(info >> 4)
            let tableId = Int(info & 0x0F)

            var bits = [UInt8](repeating: 0, count: 16)
            var totalValues = 0
            for i in 0..<16 {
                bits[i] = try readByte()
                totalValues += Int(bits[i])
            }

            var values = [UInt8]()
            for _ in 0..<totalValues {
                values.append(try readByte())
            }

            let table = HuffmanTable(bits: bits, values: values)
            tables.append((tableClass: tableClass, tableId: tableId, table: table))
        }

        return tables
    }

    /// Reads a SOS (Start of Scan) marker header.
    private mutating func readSOS() throws -> JPEGScanHeader {
        _ = try readUInt16()  // length

        let numComponents = Int(try readByte())
        var components = [(componentSelector: UInt8, dcTableId: Int, acTableId: Int)]()

        for _ in 0..<numComponents {
            let selector = try readByte()
            let tableIds = try readByte()
            components.append((
                componentSelector: selector,
                dcTableId: Int(tableIds >> 4),
                acTableId: Int(tableIds & 0x0F)
            ))
        }

        let spectralStart = Int(try readByte())
        let spectralEnd = Int(try readByte())
        let successive = try readByte()

        return JPEGScanHeader(
            components: components,
            spectralStart: spectralStart,
            spectralEnd: spectralEnd,
            successiveApproxHigh: Int(successive >> 4),
            successiveApproxLow: Int(successive & 0x0F)
        )
    }

    /// Reads entropy-coded data until the next marker (handling byte stuffing).
    private mutating func readEntropyData() throws -> [UInt8] {
        var entropyData = [UInt8]()

        while offset < data.count {
            let byte = data[offset]
            offset += 1

            if byte == 0xFF {
                guard offset < data.count else { break }
                let next = data[offset]
                if next == 0x00 {
                    // Byte stuffing — 0xFF is data
                    entropyData.append(0xFF)
                    offset += 1
                } else if next >= 0xD0 && next <= 0xD7 {
                    // Restart marker — skip it
                    entropyData.append(0xFF)
                    entropyData.append(next)
                    offset += 1
                } else {
                    // Real marker found — back up so nextMarker() can find it
                    offset -= 1  // Back to the 0xFF
                    break
                }
            } else {
                entropyData.append(byte)
            }
        }

        return entropyData
    }

    // MARK: - Byte Reading Primitives

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw JLIError.decodingFailed("Unexpected end of JPEG data")
        }
        let byte = data[offset]
        offset += 1
        return byte
    }

    private mutating func readUInt16() throws -> UInt16 {
        let high = try readByte()
        let low = try readByte()
        return (UInt16(high) << 8) | UInt16(low)
    }

    // MARK: - Helpers

    private func detectChromaSubsampling(_ components: [JPEGComponentInfo]) -> JLIChromaSubsampling {
        guard components.count >= 3 else {
            return components.count == 1 ? .yuv400 : .yuv444
        }

        let lumH = components[0].horizontalSampling
        let lumV = components[0].verticalSampling
        let chromH = components[1].horizontalSampling
        let chromV = components[1].verticalSampling

        if lumH == chromH && lumV == chromV {
            return .yuv444
        } else if lumH == 2 && lumV == 1 && chromH == 1 && chromV == 1 {
            return .yuv422
        } else if lumH == 2 && lumV == 2 && chromH == 1 && chromV == 1 {
            return .yuv420
        } else {
            return .yuv444
        }
    }
}
