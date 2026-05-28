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
