// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import CoreGraphics
import ImageIO
import JLIDICOM

/// A loaded source image normalized for the round-trip lab.
///
/// `rgb8` is always present (8-bit interleaved RGB, row-major top-down) and is
/// what the 8-bit pipeline encodes. `gray12` is present only for monochrome
/// DICOM sources — the 12-bit medical pipeline encodes that instead.
struct SourceImage: Sendable {
    var url: URL?
    var width: Int
    var height: Int
    var rgb8: [UInt8]
    var gray12: [UInt16]?
    var kind: String

    var hasHighBitDepth: Bool { gray12 != nil }
}

enum LoadError: Error, CustomStringConvertible {
    case dicom(String)
    case decodeFailed(String)

    var description: String {
        switch self {
        case .dicom(let m): return m
        case .decodeFailed(let m): return m
        }
    }
}

enum ImageLoader {

    static func load(url: URL) throws -> SourceImage {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        let ext = url.pathExtension.lowercased()

        if isDICOMMagic(bytes) || ext == "dcm" || ext == "dicom" {
            do {
                return try loadDICOM(bytes, url: url)
            } catch let e as DICOMError {
                throw LoadError.dicom("DICOM: \(e.description)")
            }
        }
        return try loadStandard(data, url: url)
    }

    private static func isDICOMMagic(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 132 && bytes[128] == 0x44 && bytes[129] == 0x49
            && bytes[130] == 0x43 && bytes[131] == 0x4D
    }

    private static func loadDICOM(_ bytes: [UInt8], url: URL) throws -> SourceImage {
        let dicom = try DICOMReader.read(bytes)
        let rgb8 = dicom.toRGB8()
        let mono = dicom.photometric.hasPrefix("MONOCHROME")
        let gray12: [UInt16]? = mono ? dicom.toGray12() : nil
        let kind = "DICOM · \(dicom.bitsStored)-bit \(dicom.photometric) · \(dicom.width)×\(dicom.height)"
        return SourceImage(
            url: url, width: dicom.width, height: dicom.height,
            rgb8: rgb8, gray12: gray12, kind: kind
        )
    }

    private static func loadStandard(_ data: Data, url: URL) throws -> SourceImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw LoadError.decodeFailed("Could not decode \(url.lastPathComponent) as an image")
        }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { throw LoadError.decodeFailed("Image has zero dimensions") }

        // Render into a tightly-packed RGBA8 buffer, then drop alpha. A
        // freshly-created bitmap context is top-down (row 0 = top), matching how
        // we later build CGImages from the raw buffer, so both panes stay
        // mutually consistent.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = rgba.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs, bitmapInfo: info)
        }) else {
            throw LoadError.decodeFailed("Could not create bitmap context")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3]     = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        let label = ext(url).isEmpty ? "Image" : ext(url).uppercased()
        return SourceImage(
            url: url, width: w, height: h, rgb8: rgb, gray12: nil,
            kind: "\(label) · 8-bit RGB · \(w)×\(h)"
        )
    }

    private static func ext(_ url: URL) -> String { url.pathExtension }
}
