// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

@Suite("Huffman – Bit Streams, Tables, Encoding and Decoding")
struct HuffmanTests {

    // MARK: - BitWriter / BitReader

    @Test("BitWriter writes single byte correctly")
    func bitWriterSingleByte() {
        var writer = BitWriter()
        writer.writeBits(0xAB, count: 8)
        writer.flush()
        #expect(writer.data.first == 0xAB)
    }

    @Test("BitWriter handles byte stuffing for 0xFF")
    func bitWriterByteStuffing() {
        var writer = BitWriter()
        writer.writeBits(0xFF, count: 8)
        writer.flush()
        // 0xFF data byte should be followed by 0x00 (byte stuffing)
        #expect(writer.data.count >= 2)
        #expect(writer.data[0] == 0xFF)
        #expect(writer.data[1] == 0x00)
    }

    @Test("BitReader reads written bits correctly")
    func bitReaderWriterRoundTrip() throws {
        var writer = BitWriter()
        writer.writeBits(0b10110, count: 5)
        writer.writeBits(0b011, count: 3)
        writer.flush()

        // Written: 10110 011 = 0xB3
        var reader = BitReader(data: writer.data)
        let val1 = try reader.readBits(5)
        let val2 = try reader.readBits(3)
        #expect(val1 == 0b10110)
        #expect(val2 == 0b011)
    }

    @Test("BitReader single bit reads")
    func bitReaderSingleBits() throws {
        let data: [UInt8] = [0b11001010]
        var reader = BitReader(data: data)
        #expect(try reader.readBit() == 1)
        #expect(try reader.readBit() == 1)
        #expect(try reader.readBit() == 0)
        #expect(try reader.readBit() == 0)
        #expect(try reader.readBit() == 1)
        #expect(try reader.readBit() == 0)
        #expect(try reader.readBit() == 1)
        #expect(try reader.readBit() == 0)
    }

    @Test("BitReader throws on end of data")
    func bitReaderThrowsOnEOF() {
        var reader = BitReader(data: [0x42])
        // Read all 8 bits
        _ = try? reader.readBits(8)
        // Next read should fail
        #expect(throws: JLIError.self) {
            try reader.readBits(1)
        }
    }

    // MARK: - HuffmanTable

    @Test("Standard DC luminance table has 12 symbols")
    func dcLuminanceTableSize() {
        let table = StandardHuffmanTables.dcLuminance
        #expect(table.values.count == 12)
    }

    @Test("Standard DC chrominance table has 12 symbols")
    func dcChrominanceTableSize() {
        let table = StandardHuffmanTables.dcChrominance
        #expect(table.values.count == 12)
    }

    @Test("Standard AC luminance table has 162 symbols")
    func acLuminanceTableSize() {
        let table = StandardHuffmanTables.acLuminance
        #expect(table.values.count == 162)
    }

    @Test("Standard AC chrominance table has 162 symbols")
    func acChrominanceTableSize() {
        let table = StandardHuffmanTables.acChrominance
        #expect(table.values.count == 162)
    }

    @Test("HuffmanTable stores bits array")
    func huffmanTableStoresBits() {
        let table = StandardHuffmanTables.dcLuminance
        #expect(table.bits.count == 16)
    }

    // MARK: - Huffman Encoding / Decoding

    @Test("Category function returns correct values")
    func categoryFunction() {
        #expect(HuffmanEncoder.category(for: 0) == 0)
        #expect(HuffmanEncoder.category(for: 1) == 1)
        #expect(HuffmanEncoder.category(for: -1) == 1)
        #expect(HuffmanEncoder.category(for: 2) == 2)
        #expect(HuffmanEncoder.category(for: -3) == 2)
        #expect(HuffmanEncoder.category(for: 7) == 3)
        #expect(HuffmanEncoder.category(for: -7) == 3)
        #expect(HuffmanEncoder.category(for: 8) == 4)
    }

    @Test("Additional bits encoding for positive values")
    func additionalBitsPositive() {
        #expect(HuffmanEncoder.additionalBits(for: 1, category: 1) == 1)
        #expect(HuffmanEncoder.additionalBits(for: 3, category: 2) == 3)
        #expect(HuffmanEncoder.additionalBits(for: 7, category: 3) == 7)
    }

    @Test("Additional bits encoding for negative values")
    func additionalBitsNegative() {
        #expect(HuffmanEncoder.additionalBits(for: -1, category: 1) == 0)
        #expect(HuffmanEncoder.additionalBits(for: -2, category: 2) == 1)
        #expect(HuffmanEncoder.additionalBits(for: -3, category: 2) == 0)
    }

    @Test("DC encode then decode round-trips")
    func dcEncodeDecodeRoundTrip() throws {
        let testValues: [Int32] = [0, 1, -1, 5, -5, 100, -100, 255, -255]
        let dcTable = StandardHuffmanTables.dcLuminance

        for value in testValues {
            var writer = BitWriter()
            HuffmanEncoder.encodeDC(value, table: dcTable, writer: &writer)
            writer.flush()

            var reader = BitReader(data: writer.data)
            let decoded = try HuffmanDecoder.decodeDC(from: &reader, table: dcTable)
            #expect(decoded == value, "DC round-trip failed for \(value)")
        }
    }

    @Test("AC encode then decode round-trips for simple block")
    func acEncodeDecodeRoundTrip() throws {
        // Simple zigzag array: DC at 0, a few non-zero AC, rest zeros
        var zigzag = [Int32](repeating: 0, count: 64)
        zigzag[0] = 42   // DC (not used by AC encoder, but kept for context)
        zigzag[1] = 5
        zigzag[2] = -3
        zigzag[5] = 1    // 2 zeros before this
        // Rest are zeros → will emit EOB

        let acTable = StandardHuffmanTables.acLuminance

        var writer = BitWriter()
        HuffmanEncoder.encodeAC(zigzag, table: acTable, writer: &writer)
        writer.flush()

        var reader = BitReader(data: writer.data)
        let decoded = try HuffmanDecoder.decodeAC(from: &reader, table: acTable)

        // Compare AC coefficients (indices 1-63)
        for i in 1..<64 {
            #expect(decoded[i] == zigzag[i], "AC mismatch at index \(i)")
        }
    }
}
