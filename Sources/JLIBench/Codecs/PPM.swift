// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// PPM (Portable PixMap, P6 binary) is the simplest interchange format the
/// `cjpeg`/`djpeg` family of CLI tools all read and write. Used to pipe pixel
/// data through shell-out codec adapters.
///
/// Format (text header, then raw RGB bytes):
///
///     P6
///     <width> <height>
///     255
///     <width * height * 3 bytes RGB>
enum PPM {

    /// Encodes interleaved RGB bytes into a PPM (P6) byte buffer.
    static func encode(rgb: [UInt8], width: Int, height: Int) -> [UInt8] {
        precondition(rgb.count == width * height * 3, "RGB buffer size mismatch")
        let header = "P6\n\(width) \(height)\n255\n"
        var out = [UInt8](header.utf8)
        out.append(contentsOf: rgb)
        return out
    }

    /// Decodes a P6 PPM into (rgb, width, height). Accepts comments (`#` to EOL)
    /// in the header per PPM spec. Throws on unsupported variants (P3 ASCII,
    /// maxval ≠ 255, P5 grayscale).
    static func decode(_ data: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        // Parse the header field-by-field, advancing past whitespace and comments.
        var cursor = 0
        func nextToken() throws -> String {
            // Skip whitespace + comment lines.
            while cursor < data.count {
                let c = data[cursor]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    cursor += 1
                } else if c == 0x23 /* # */ {
                    while cursor < data.count, data[cursor] != 0x0A { cursor += 1 }
                } else {
                    break
                }
            }
            let start = cursor
            while cursor < data.count {
                let c = data[cursor]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
                cursor += 1
            }
            guard start < cursor else {
                throw PPMError.malformed("unexpected end of header")
            }
            return String(bytes: data[start..<cursor], encoding: .ascii) ?? ""
        }

        let magic = try nextToken()
        guard magic == "P6" else {
            throw PPMError.malformed("unsupported PPM magic \(magic) (expected P6 binary RGB)")
        }
        guard let width = Int(try nextToken()), width > 0 else {
            throw PPMError.malformed("invalid width")
        }
        guard let height = Int(try nextToken()), height > 0 else {
            throw PPMError.malformed("invalid height")
        }
        guard let maxVal = Int(try nextToken()), maxVal == 255 else {
            throw PPMError.malformed("unsupported maxval (only 255 supported)")
        }
        // Per PPM spec, exactly one whitespace byte separates the maxval header
        // from the binary pixel data. Skip it.
        guard cursor < data.count else { throw PPMError.malformed("missing pixel data") }
        cursor += 1

        let expected = width * height * 3
        guard data.count - cursor >= expected else {
            throw PPMError.malformed("truncated pixel data: got \(data.count - cursor) bytes, need \(expected)")
        }
        let rgb = Array(data[cursor..<(cursor + expected)])
        return (rgb, width, height)
    }
}

enum PPMError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String {
        switch self {
        case .malformed(let s): return "malformed PPM: \(s)"
        }
    }
}

/// 16-bit grayscale PGM (P5). Per the netpbm spec, samples with maxval > 255
/// are stored as 2 bytes **big-endian**. Used to pipe 12-bit grayscale through
/// `cjpeg -precision 12` / `djpeg`, which read and write exactly this format.
enum PGM16 {

    /// Encodes 16-bit grayscale samples into a P5 PGM with `maxVal` (e.g. 4095
    /// for 12-bit), big-endian sample bytes.
    static func encode(gray: [UInt16], width: Int, height: Int, maxVal: Int = 4095) -> [UInt8] {
        precondition(gray.count == width * height, "gray buffer size mismatch")
        let header = "P5\n\(width) \(height)\n\(maxVal)\n"
        var out = [UInt8](header.utf8)
        out.reserveCapacity(out.count + gray.count * 2)
        for s in gray {
            out.append(UInt8(s >> 8))     // big-endian high byte
            out.append(UInt8(s & 0xFF))
        }
        return out
    }

    /// Decodes a P5 PGM. Supports both 8-bit (maxval ≤ 255, 1 byte/sample) and
    /// 16-bit (maxval > 255, 2 bytes/sample big-endian).
    static func decode(_ data: [UInt8]) throws -> (gray: [UInt16], width: Int, height: Int) {
        var cursor = 0
        func nextToken() throws -> String {
            while cursor < data.count {
                let c = data[cursor]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { cursor += 1 }
                else if c == 0x23 { while cursor < data.count, data[cursor] != 0x0A { cursor += 1 } }
                else { break }
            }
            let start = cursor
            while cursor < data.count {
                let c = data[cursor]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
                cursor += 1
            }
            guard start < cursor else { throw PPMError.malformed("unexpected end of header") }
            return String(bytes: data[start..<cursor], encoding: .ascii) ?? ""
        }

        guard try nextToken() == "P5" else {
            throw PPMError.malformed("expected P5 grayscale PGM")
        }
        guard let width = Int(try nextToken()), width > 0,
              let height = Int(try nextToken()), height > 0,
              let maxVal = Int(try nextToken()), maxVal > 0 else {
            throw PPMError.malformed("invalid PGM header")
        }
        guard cursor < data.count else { throw PPMError.malformed("missing pixel data") }
        cursor += 1  // single whitespace separator before binary data

        let count = width * height
        var gray = [UInt16](repeating: 0, count: count)
        if maxVal > 255 {
            guard data.count - cursor >= count * 2 else {
                throw PPMError.malformed("truncated 16-bit pixel data")
            }
            for i in 0..<count {
                gray[i] = (UInt16(data[cursor + i * 2]) << 8) | UInt16(data[cursor + i * 2 + 1])
            }
        } else {
            guard data.count - cursor >= count else {
                throw PPMError.malformed("truncated 8-bit pixel data")
            }
            for i in 0..<count { gray[i] = UInt16(data[cursor + i]) }
        }
        return (gray, width, height)
    }
}

/// 16-bit color PPM (P6) — the RGB counterpart of ``PGM16``. Per the netpbm
/// spec, samples with maxval > 255 are stored as 2 bytes **big-endian**. Used to
/// pipe 12-bit color through `cjpeg -precision 12` / `djpeg`, the cross-codec
/// reference for JLISwift's 12-bit color output.
enum PPM16 {

    /// Encodes interleaved 16-bit RGB samples (`width*height*3`) into a P6 PPM
    /// with `maxVal` (e.g. 4095 for 12-bit), big-endian sample bytes.
    static func encode(rgb: [UInt16], width: Int, height: Int, maxVal: Int = 4095) -> [UInt8] {
        precondition(rgb.count == width * height * 3, "rgb buffer size mismatch")
        let header = "P6\n\(width) \(height)\n\(maxVal)\n"
        var out = [UInt8](header.utf8)
        out.reserveCapacity(out.count + rgb.count * 2)
        for s in rgb {
            out.append(UInt8(s >> 8))     // big-endian high byte
            out.append(UInt8(s & 0xFF))
        }
        return out
    }

    /// Decodes a P6 PPM. Supports 8-bit (maxval ≤ 255, 1 byte/sample) and 16-bit
    /// (maxval > 255, 2 bytes/sample big-endian). Returns interleaved RGB.
    static func decode(_ data: [UInt8]) throws -> (rgb: [UInt16], width: Int, height: Int) {
        var cursor = 0
        func nextToken() throws -> String {
            while cursor < data.count {
                let c = data[cursor]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { cursor += 1 }
                else if c == 0x23 { while cursor < data.count, data[cursor] != 0x0A { cursor += 1 } }
                else { break }
            }
            let start = cursor
            while cursor < data.count {
                let c = data[cursor]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
                cursor += 1
            }
            guard start < cursor else { throw PPMError.malformed("unexpected end of header") }
            return String(bytes: data[start..<cursor], encoding: .ascii) ?? ""
        }

        guard try nextToken() == "P6" else {
            throw PPMError.malformed("expected P6 color PPM")
        }
        guard let width = Int(try nextToken()), width > 0,
              let height = Int(try nextToken()), height > 0,
              let maxVal = Int(try nextToken()), maxVal > 0 else {
            throw PPMError.malformed("invalid PPM header")
        }
        guard cursor < data.count else { throw PPMError.malformed("missing pixel data") }
        cursor += 1  // single whitespace separator before binary data

        let count = width * height * 3
        var rgb = [UInt16](repeating: 0, count: count)
        if maxVal > 255 {
            guard data.count - cursor >= count * 2 else {
                throw PPMError.malformed("truncated 16-bit pixel data")
            }
            for i in 0..<count {
                rgb[i] = (UInt16(data[cursor + i * 2]) << 8) | UInt16(data[cursor + i * 2 + 1])
            }
        } else {
            guard data.count - cursor >= count else {
                throw PPMError.malformed("truncated 8-bit pixel data")
            }
            for i in 0..<count { rgb[i] = UInt16(data[cursor + i]) }
        }
        return (rgb, width, height)
    }
}
