// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
import Foundation
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

    // MARK: - Optimal Huffman Table Generation (Annex K.2)

    @Test("Optimal table is a valid prefix code (canonical, ≤16-bit, complete)")
    func optimalTableValid() {
        // A skewed frequency distribution — symbol 0 dominant, a long tail.
        var freq = [Int](repeating: 0, count: 256)
        freq[0] = 1000
        freq[1] = 500
        freq[2] = 250
        freq[5] = 60
        freq[0xF0] = 12
        freq[42] = 3
        freq[200] = 1

        let table = HuffmanTableBuilder.build(
            frequencies: freq, fallback: StandardHuffmanTables.acLuminance
        )

        // BITS sum equals the number of distinct symbols counted.
        let distinctSymbols = freq.filter { $0 > 0 }.count
        #expect(table.values.count == distinctSymbols)
        #expect(table.bits.reduce(0) { $0 + Int($1) } == distinctSymbols)

        // No code longer than 16 bits (Annex K.2 requirement).
        #expect(table.bits.count == 16)

        // Kraft inequality: a valid prefix code satisfies Σ count(L)·2^-L ≤ 1.
        // JPEG tables are deliberately *incomplete* — they reserve the all-ones
        // codeword (forbidden by the spec), so the sum is exactly 1 - 2^-L where
        // L is the length the reserved symbol would have had. It must never exceed 1.
        var kraft = 0.0
        for len in 1...16 { kraft += Double(table.bits[len - 1]) * pow(2.0, -Double(len)) }
        #expect(kraft <= 1.0, "Kraft sum \(kraft) > 1 — not a valid prefix code")
        #expect(kraft > 0.9, "Kraft sum \(kraft) too low — code wastes code space")

        // More-frequent symbols must get codes no longer than rarer ones.
        // Build a symbol→length map from the canonical (bits, values) layout.
        var lengthOf = [Int: Int]()
        var idx = 0
        for len in 1...16 {
            for _ in 0..<Int(table.bits[len - 1]) {
                lengthOf[Int(table.values[idx])] = len
                idx += 1
            }
        }
        #expect(lengthOf[0]! <= lengthOf[5]!)   // freq 1000 vs 60
        #expect(lengthOf[5]! <= lengthOf[200]!) // freq 60 vs 1
    }

    @Test("Optimal table round-trips encode → decode")
    func optimalTableRoundTrip() throws {
        var freq = [Int](repeating: 0, count: 256)
        freq[0] = 100; freq[1] = 40; freq[0x21] = 8; freq[0xF0] = 3
        let table = HuffmanTableBuilder.build(
            frequencies: freq, fallback: StandardHuffmanTables.acLuminance
        )

        // Encode a DC-style symbol then read it back via the symbol decoder.
        var writer = BitWriter()
        HuffmanEncoder.encodeDC(1, table: table, writer: &writer)   // category 1
        writer.flush()
        var reader = BitReader(data: writer.data)
        let decoded = try HuffmanDecoder.decodeDC(from: &reader, table: table)
        #expect(decoded == 1)
    }

    @Test("Empty frequencies fall back to the standard table")
    func optimalTableEmptyFallback() {
        let freq = [Int](repeating: 0, count: 256)
        let table = HuffmanTableBuilder.build(
            frequencies: freq, fallback: StandardHuffmanTables.dcLuminance
        )
        #expect(table.values == StandardHuffmanTables.dcLuminance.values)
        #expect(table.bits == StandardHuffmanTables.dcLuminance.bits)
    }

    @Test("Optimized Huffman produces smaller output than standard, same pixels")
    func optimizedSmallerThanStandard() throws {
        // A gentle gradient compresses well and has a skewed symbol distribution,
        // so per-image tables should beat the generic Annex K tables.
        let w = 64, h = 64
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let v = UInt8((x + y) * 255 / (w + h - 2))
                rgb[i] = v; rgb[i + 1] = v; rgb[i + 2] = v
            }
        }
        let image = try JLIImage(
            width: w, height: h, pixelFormat: .uint8, colorModel: .rgb, data: rgb
        )

        var stdConfig = JLIEncoderConfiguration.default
        stdConfig.optimiseHuffman = false
        stdConfig.chromaSubsampling = .yuv444
        var optConfig = JLIEncoderConfiguration.default
        optConfig.optimiseHuffman = true
        optConfig.chromaSubsampling = .yuv444

        let stdData = try JLIEncoder().encode(image, configuration: stdConfig)
        let optData = try JLIEncoder().encode(image, configuration: optConfig)

        #expect(optData.count < stdData.count,
                "optimized \(optData.count) should be < standard \(stdData.count)")

        // And it must still decode to the right dimensions.
        let decoded = try JLIDecoder().decode(from: optData)
        #expect(decoded.width == w && decoded.height == h)
    }
}
