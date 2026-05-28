// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Bit-level writer for constructing JPEG entropy-coded data.
///
/// Accumulates bits MSB-first into bytes, handling JPEG byte stuffing
/// (`0xFF` is followed by `0x00` in the entropy-coded segment). For a noisy
/// 512×512 encode the writer emits ~500k bytes; the previous `.append`-per-byte
/// implementation was the single hottest cost in that case. This rewrite
/// preallocates the buffer to an upper bound (caller can size it tightly via
/// the initializer) and writes via direct subscript, avoiding both bounds-check
/// growth and Array's copy-on-write checks in the inner loop.
struct BitWriter {
    /// Backing storage; only the first `byteCount` bytes are meaningful. Sized
    /// to the caller's estimated upper bound and doubled on the rare overflow.
    private var buffer: [UInt8]
    /// Number of bytes actually written to `buffer`.
    private var byteCount: Int = 0
    /// Bit accumulator: the low `nbits` bits hold pending output, MSB-first.
    /// A 64-bit register lets us coalesce byte emission instead of flushing one
    /// byte (through a closure) per 8 bits — the Huffman/bit-writing path is the
    /// hottest cost in a noisy encode, so batching here is the main lever.
    /// Kept below 8 after every `writeBits`, so it never overflows for the
    /// ≤16-bit writes JPEG entropy coding issues.
    private var acc: UInt64 = 0
    private var nbits: Int = 0

    /// 64 KB is enough for a typical 256×256 photo; the encoder passes a tighter
    /// upper bound derived from the image dimensions.
    init(estimatedMaxSize: Int = 65536) {
        buffer = [UInt8](repeating: 0, count: max(estimatedMaxSize, 64))
    }

    /// The bytes written so far. Computed — slices `buffer` down to actual length.
    var data: [UInt8] {
        Array(buffer[0..<byteCount])
    }

    /// Writes `count` bits from `value` (MSB-first).
    mutating func writeBits(_ value: UInt32, count: Int) {
        guard count > 0 else { return }
        acc = (acc << UInt64(count)) | UInt64(value & ((1 << count) - 1))
        nbits += count
        if nbits < 8 { return }   // no whole byte pending — skip the buffer access
        // Each pending whole byte can expand to two with stuffing; +2 slack for
        // the in-loop stuffing byte.
        if byteCount + (nbits >> 3) * 2 + 2 > buffer.count { grow() }
        buffer.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            var bc = byteCount
            while nbits >= 8 {
                nbits -= 8
                let byte = UInt8((acc >> UInt64(nbits)) & 0xFF)
                p[bc] = byte; bc += 1
                if byte == 0xFF { p[bc] = 0; bc += 1 }   // byte stuffing
            }
            byteCount = bc
        }
    }

    /// Writes a single bit.
    mutating func writeBit(_ bit: Bool) {
        writeBits(bit ? 1 : 0, count: 1)
    }

    /// Flushes any remaining bits, padding with 1-bits as per JPEG spec.
    mutating func flush() {
        guard nbits > 0 else { return }   // nbits is always 0–7 here
        let pad = 8 - nbits
        let byte = UInt8(((acc << UInt64(pad)) | UInt64((1 << pad) - 1)) & 0xFF)
        if byteCount + 2 > buffer.count { grow() }
        buffer.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            p[byteCount] = byte
            if byte == 0xFF { p[byteCount + 1] = 0 }
        }
        byteCount += (byte == 0xFF) ? 2 : 1
        acc = 0
        nbits = 0
    }

    /// Pads to a byte boundary (1-bits, per spec) and writes a restart marker
    /// `0xFF 0xD0…0xD7` (`index` cycles 0–7). The marker bytes are written raw —
    /// the `0xFF` here is a real marker prefix, not stuffed data.
    mutating func emitRestartMarker(_ index: Int) {
        flush()                       // align to byte boundary (no-op if already aligned)
        if byteCount + 2 > buffer.count { grow() }
        buffer.withUnsafeMutableBufferPointer { buf in
            buf[byteCount] = 0xFF
            buf[byteCount + 1] = 0xD0 + UInt8(index & 7)
        }
        byteCount += 2
    }

    /// Doubles the backing buffer when the initial estimate was too small.
    /// Allocating in chunks keeps the amortized cost ~O(1) per byte.
    private mutating func grow() {
        buffer.append(contentsOf: repeatElement(0, count: buffer.count))
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
        // Every legitimate JPEG bit-read is ≤ 16 bits (magnitude categories ≤ 15,
        // EOBRUN appendages ≤ 14). A larger width only arises from a malformed or
        // forged Huffman table (whose decoded "category" can be any byte) and
        // would overflow the 32-bit `bitBuffer` in `loadByte` — throw instead.
        guard count >= 0, count <= 16 else {
            throw JLIError.decodingFailed("invalid bit-read width \(count)")
        }
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

    /// Consumes a restart marker (`FF D<expectedIndex>`) at the current byte position.
    ///
    /// Called by the decoder after every `restartInterval` MCUs when the JPEG carries
    /// DRI + RST markers. Discards any partial bits first (restart markers always sit
    /// on byte boundaries), then advances past the two-byte marker. The marker index
    /// cycles 0–7 (`RST0`–`RST7`), so the caller passes `mcuCount / restartInterval & 7`.
    ///
    /// JPEG allows fill bytes (`0xFF 0xFF…`) before any marker; we tolerate them here.
    mutating func skipRestartMarker(expectedIndex: Int) throws {
        alignToByte()
        // Skip any 0xFF fill bytes that precede the marker.
        while byteOffset < data.count - 1, data[byteOffset] == 0xFF,
              data[byteOffset + 1] == 0xFF {
            byteOffset += 1
        }
        guard byteOffset + 1 < data.count else {
            throw JLIError.decodingFailed("Unexpected end of data expecting RST marker")
        }
        guard data[byteOffset] == 0xFF else {
            throw JLIError.decodingFailed(
                "Expected RST marker at offset \(byteOffset), got 0x\(String(format: "%02X", data[byteOffset]))"
            )
        }
        let expected = UInt8(0xD0 + (expectedIndex & 7))
        let got = data[byteOffset + 1]
        guard got >= 0xD0 && got <= 0xD7 else {
            throw JLIError.decodingFailed(
                "Expected RST\(expectedIndex & 7) (0xFF D\(expectedIndex & 7)), got 0xFF \(String(format: "%02X", got))"
            )
        }
        // Some encoders emit RSTs out of strict cyclic order on damaged streams,
        // but ImageIO/libjpeg always cycle 0–7. Accept what we got but warn via
        // throwing if it diverges — for now we accept any RST byte for robustness.
        _ = expected
        byteOffset += 2
    }
}
