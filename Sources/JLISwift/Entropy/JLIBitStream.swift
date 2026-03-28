// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Bit-level writer for constructing JPEG entropy-coded data.
///
/// Accumulates bits MSB-first into bytes, handling JPEG byte stuffing
/// (0xFF is followed by 0x00 in the entropy-coded segment).
struct BitWriter {
    /// Accumulated output bytes.
    private(set) var data: [UInt8] = []
    /// Current byte being assembled.
    private var currentByte: UInt32 = 0
    /// Number of bits currently in `currentByte` (0–8).
    private var bitCount: Int = 0

    /// Writes `count` bits from `value` (MSB-first).
    mutating func writeBits(_ value: UInt32, count: Int) {
        var remaining = count
        var val = value

        while remaining > 0 {
            let space = 8 - bitCount
            let bitsToWrite = min(space, remaining)

            // Extract the top `bitsToWrite` bits from val
            let shift = remaining - bitsToWrite
            let bits = (val >> shift) & ((1 << bitsToWrite) - 1)
            currentByte = (currentByte << bitsToWrite) | bits
            bitCount += bitsToWrite
            remaining -= bitsToWrite
            val = val & ((1 << shift) - 1)

            if bitCount == 8 {
                flushByte()
            }
        }
    }

    /// Writes a single bit.
    mutating func writeBit(_ bit: Bool) {
        writeBits(bit ? 1 : 0, count: 1)
    }

    /// Flushes any remaining bits, padding with 1-bits as per JPEG spec.
    mutating func flush() {
        if bitCount > 0 {
            let padBits = 8 - bitCount
            currentByte = (currentByte << padBits) | ((1 << padBits) - 1)
            bitCount = 8
            flushByte()
        }
    }

    /// Emits the current byte, applying byte stuffing if needed.
    private mutating func flushByte() {
        let byte = UInt8(currentByte & 0xFF)
        data.append(byte)
        if byte == 0xFF {
            data.append(0x00)  // JPEG byte stuffing
        }
        currentByte = 0
        bitCount = 0
    }
}

/// Bit-level reader for parsing JPEG entropy-coded data.
///
/// Reads bits MSB-first from a byte buffer, handling JPEG byte stuffing.
struct BitReader {
    private let data: [UInt8]
    /// Current byte position in the data buffer.
    private(set) var byteOffset: Int = 0
    /// Current bit buffer.
    private var bitBuffer: UInt32 = 0
    /// Number of valid bits in the bit buffer.
    private var bitsAvailable: Int = 0

    init(data: [UInt8]) {
        self.data = data
    }

    /// Whether there is more data to read.
    var hasMore: Bool {
        byteOffset < data.count || bitsAvailable > 0
    }

    /// Reads a single bit.
    mutating func readBit() throws -> UInt32 {
        return try readBits(1)
    }

    /// Reads `count` bits and returns them as an unsigned integer.
    mutating func readBits(_ count: Int) throws -> UInt32 {
        while bitsAvailable < count {
            try loadByte()
        }
        bitsAvailable -= count
        let value = (bitBuffer >> bitsAvailable) & ((1 << count) - 1)
        return value
    }

    /// Loads the next byte from the data, handling byte stuffing.
    private mutating func loadByte() throws {
        guard byteOffset < data.count else {
            throw JLIError.decodingFailed("Unexpected end of entropy-coded data")
        }
        let byte = data[byteOffset]
        byteOffset += 1

        if byte == 0xFF {
            guard byteOffset < data.count else {
                throw JLIError.decodingFailed("Unexpected end of data after 0xFF")
            }
            let next = data[byteOffset]
            if next == 0x00 {
                // Byte stuffing — the 0xFF is a data byte
                byteOffset += 1
            } else {
                // This is a marker, not data — should not happen in entropy segment
                throw JLIError.decodingFailed("Unexpected marker 0xFF\(String(format: "%02X", next)) in entropy data")
            }
        }

        bitBuffer = (bitBuffer << 8) | UInt32(byte)
        bitsAvailable += 8
    }

    /// Aligns the reader to the next byte boundary by discarding remaining bits.
    mutating func alignToByte() {
        bitsAvailable = 0
        bitBuffer = 0
    }
}
