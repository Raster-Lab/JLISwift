// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Huffman table, encoding, and decoding for JPEG entropy coding.

// MARK: - Huffman Table

/// A compiled Huffman table for encoding or decoding.
struct HuffmanTable {
    /// Number of codes at each bit length (1–16).
    let bits: [UInt8]
    /// The code and bit length for each symbol (for encoding).
    /// Index is the symbol value; value is (code, bitLength).
    let encodingTable: [(code: UInt16, length: UInt8)]

    /// For decoding: maximum code value at each bit length (1–16).
    let maxCode: [Int32]
    /// For decoding: minimum code value at each bit length.
    let minCode: [Int32]
    /// For decoding: index into values array for each bit length.
    let valPtr: [Int]
    /// Ordered symbol values.
    let values: [UInt8]

    /// Builds a Huffman table from JPEG-standard bits and values arrays.
    ///
    /// - Parameters:
    ///   - bits: 16-element array, where `bits[i]` is the number of codes of length `i+1`.
    ///   - values: Symbol values in order of increasing code length.
    init(bits: [UInt8], values: [UInt8]) {
        self.bits = bits
        self.values = values
        var encoding = [(code: UInt16, length: UInt8)](repeating: (0, 0), count: 256)

        var maxC = [Int32](repeating: -1, count: 17)
        var minC = [Int32](repeating: -1, count: 17)
        var vPtr = [Int](repeating: 0, count: 17)

        var code: UInt16 = 0
        var valueIndex = 0

        for bitLength in 1...16 {
            let count = Int(bits[bitLength - 1])
            if count > 0 {
                vPtr[bitLength] = valueIndex
                minC[bitLength] = Int32(code)
                for _ in 0..<count {
                    let symbol = values[valueIndex]
                    encoding[Int(symbol)] = (code, UInt8(bitLength))
                    valueIndex += 1
                    code += 1
                }
                maxC[bitLength] = Int32(code - 1)
            }
            code <<= 1
        }

        self.encodingTable = encoding
        self.maxCode = maxC
        self.minCode = minC
        self.valPtr = vPtr
    }
}

// MARK: - Standard JPEG Huffman Tables (ITU-T T.81 Annex K)

/// Standard Huffman table definitions from the JPEG specification.
enum StandardHuffmanTables {
    /// DC luminance table (Table K.3).
    static let dcLuminance = HuffmanTable(
        bits: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
        values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    )

    /// DC chrominance table (Table K.4).
    static let dcChrominance = HuffmanTable(
        bits: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
        values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    )

    /// AC luminance table (Table K.5).
    static let acLuminance = HuffmanTable(
        bits: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D],
        values: [
            0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
            0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
            0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
            0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
            0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16,
            0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
            0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
            0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
            0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
            0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
            0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
            0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
            0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
            0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
            0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
            0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4,
            0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
            0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
            0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
            0xF9, 0xFA
        ]
    )

    /// AC chrominance table (Table K.6).
    static let acChrominance = HuffmanTable(
        bits: [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77],
        values: [
            0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
            0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
            0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
            0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
            0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34,
            0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
            0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
            0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
            0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
            0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
            0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
            0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
            0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
            0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
            0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
            0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
            0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2,
            0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
            0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
            0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
            0xF9, 0xFA
        ]
    )
}

// MARK: - Huffman Encoding

/// Huffman entropy encoder for JPEG data.
enum HuffmanEncoder {

    /// Returns the category (number of bits) needed to represent a value.
    ///
    /// Category 0 = value 0, category 1 = -1..1, category 2 = -3..-2, 2..3, etc.
    static func category(for value: Int32) -> Int {
        if value == 0 { return 0 }
        var absVal = abs(Int(value))
        var cat = 0
        while absVal > 0 {
            cat += 1
            absVal >>= 1
        }
        return cat
    }

    /// Returns the additional bits to encode after the Huffman category code.
    ///
    /// For positive values: the value itself. For negative: `value + (1 << category) - 1`.
    static func additionalBits(for value: Int32, category cat: Int) -> UInt32 {
        if cat == 0 { return 0 }
        if value >= 0 {
            return UInt32(value)
        } else {
            return UInt32(Int(value) + (1 << cat) - 1)
        }
    }

    /// Encodes a DC coefficient difference using the given Huffman table.
    static func encodeDC(_ diff: Int32, table: HuffmanTable, writer: inout BitWriter) {
        let cat = category(for: diff)
        let entry = table.encodingTable[cat]
        writer.writeBits(UInt32(entry.code), count: Int(entry.length))
        if cat > 0 {
            writer.writeBits(additionalBits(for: diff, category: cat), count: cat)
        }
    }

    /// Encodes the 63 AC coefficients of a block (in zigzag order, starting from index 1).
    static func encodeAC(_ zigzag: [Int32], table: HuffmanTable, writer: inout BitWriter) {
        var zeroRun = 0

        for i in 1..<64 {
            let value = zigzag[i]
            if value == 0 {
                zeroRun += 1
            } else {
                // Emit ZRL (zero run length) symbols for runs > 15
                while zeroRun > 15 {
                    let entry = table.encodingTable[0xF0]  // ZRL symbol
                    writer.writeBits(UInt32(entry.code), count: Int(entry.length))
                    zeroRun -= 16
                }
                let cat = category(for: value)
                let symbol = (zeroRun << 4) | cat
                let entry = table.encodingTable[symbol]
                writer.writeBits(UInt32(entry.code), count: Int(entry.length))
                writer.writeBits(additionalBits(for: value, category: cat), count: cat)
                zeroRun = 0
            }
        }

        // EOB (End of Block) if the last coefficient(s) were zero
        if zeroRun > 0 {
            let entry = table.encodingTable[0x00]  // EOB symbol
            writer.writeBits(UInt32(entry.code), count: Int(entry.length))
        }
    }
}

// MARK: - Huffman Decoding

/// Huffman entropy decoder for JPEG data.
enum HuffmanDecoder {

    /// Decodes a single Huffman symbol from the bit stream.
    static func decodeSymbol(from reader: inout BitReader, table: HuffmanTable) throws -> UInt8 {
        var code: Int32 = 0

        for bitLength in 1...16 {
            let bit = try reader.readBit()
            code = (code << 1) | Int32(bit)

            if table.maxCode[bitLength] >= 0 && code <= table.maxCode[bitLength] {
                let index = table.valPtr[bitLength] + Int(code - table.minCode[bitLength])
                return table.values[index]
            }
        }

        throw JLIError.decodingFailed("Invalid Huffman code")
    }

    /// Decodes a signed value from additional bits after a Huffman category.
    static func decodeValue(from reader: inout BitReader, category cat: Int) throws -> Int32 {
        guard cat > 0 else { return 0 }

        let bits = try reader.readBits(cat)
        // If MSB is 0, the value is negative
        if bits < (1 << (cat - 1)) {
            return Int32(bits) - Int32((1 << cat) - 1)
        } else {
            return Int32(bits)
        }
    }

    /// Decodes a DC coefficient from the bit stream.
    static func decodeDC(from reader: inout BitReader, table: HuffmanTable) throws -> Int32 {
        let cat = Int(try decodeSymbol(from: &reader, table: table))
        return try decodeValue(from: &reader, category: cat)
    }

    /// Decodes the 63 AC coefficients of a block from the bit stream.
    ///
    /// Returns 64 coefficients in zigzag order (index 0 is left empty for DC).
    static func decodeAC(from reader: inout BitReader, table: HuffmanTable) throws -> [Int32] {
        var coefficients = [Int32](repeating: 0, count: 64)
        var index = 1

        while index < 64 {
            let symbol = try decodeSymbol(from: &reader, table: table)

            if symbol == 0x00 {
                // EOB — remaining coefficients are zero
                break
            }

            if symbol == 0xF0 {
                // ZRL — skip 16 zeros
                index += 16
                continue
            }

            let zeroRun = Int(symbol >> 4)
            let cat = Int(symbol & 0x0F)
            index += zeroRun

            guard index < 64 else { break }

            coefficients[index] = try decodeValue(from: &reader, category: cat)
            index += 1
        }

        return coefficients
    }
}
