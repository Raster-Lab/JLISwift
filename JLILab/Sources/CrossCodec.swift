// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import JLISwift

// MARK: - Report types (Sendable: produced off-main, displayed on main)

struct CrossCodecRow: Sendable, Identifiable {
    var id: String { name }
    let name: String
    var available: Bool
    var error: String?
    var encodedBytes: Int = 0
    var bpp: Double = 0
    var ratio: Double = 0
    var psnr: Double = 0
    var butteraugli: Double?
    var encodeMs: Double = 0
}

/// One interoperability check: encode with codec A, decode with codec B, and
/// confirm the bytes are readable and reconstruct the right image.
struct InteropResult: Sendable, Identifiable {
    var id: String { label }
    let label: String
    let ok: Bool
    let detail: String
}

struct CrossCodecReport: Sendable {
    var quality: Int
    var width: Int
    var height: Int
    var rows: [CrossCodecRow]
    var interop: [InteropResult]
}

// MARK: - Codec abstraction

protocol LabCodec: Sendable {
    var name: String { get }
    var available: Bool { get }
    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8]
    func decode(_ jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int)
}

/// JLISwift itself, encoding 8-bit RGB at a comparison quality while keeping the
/// lab's other choices (subsampling, progressive, trellis, perceptual tables).
struct JLISwiftLabCodec: LabCodec {
    let name = "JLISwift"
    let available = true
    let base: JLIEncoderConfiguration

    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        var cfg = base
        cfg.lossless = false
        cfg.distance = nil
        cfg.quality = Double(quality)
        let img = try JLIImage(width: width, height: height, pixelFormat: .uint8, colorModel: .rgb, data: rgb)
        return try JLIEncoder().encode(img, configuration: cfg)
    }

    func decode(_ jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        let d = try JLIDecoder().decode(from: jpeg)
        return (toRGB8(d), d.width, d.height)
    }

    private func toRGB8(_ img: JLIImage) -> [UInt8] {
        let n = img.width * img.height
        if img.colorModel == .rgb && img.pixelFormat == .uint8 { return img.data }
        var out = [UInt8](repeating: 0, count: n * 3)
        if img.colorModel == .grayscale && img.pixelFormat == .uint8 {
            for i in 0..<min(n, img.data.count) { let g = img.data[i]; out[i*3]=g; out[i*3+1]=g; out[i*3+2]=g }
        } else {
            let cc = img.colorModel.componentCount
            for i in 0..<min(n, img.data.count / cc) {
                out[i*3] = img.data[i*cc]; out[i*3+1] = img.data[i*cc+1]; out[i*3+2] = img.data[i*cc+2]
            }
        }
        return out
    }
}

/// Apple ImageIO (libjpeg-turbo under the hood) via CGImageDestination/Source.
struct ImageIOLabCodec: LabCodec {
    let name = "ImageIO"
    let available = true

    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        let n = width * height
        var rgbx = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n { rgbx[i*4]=rgb[i*3]; rgbx[i*4+1]=rgb[i*3+1]; rgbx[i*4+2]=rgb[i*3+2]; rgbx[i*4+3]=255 }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgbx) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width*4, space: cs, bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw LabCodecError.message("ImageIO: CGImage construction failed")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LabCodecError.message("ImageIO: destination failed")
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: Double(quality)/100.0] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LabCodecError.message("ImageIO: finalize failed") }
        return [UInt8](out as Data)
    }

    func decode(_ jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw LabCodecError.message("ImageIO: decode failed")
        }
        let w = cg.width, h = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = ctx.data else { throw LabCodecError.message("ImageIO: context failed") }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let stride = ctx.bytesPerRow
        let p = base.bindMemory(to: UInt8.self, capacity: stride * h)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let s = y*stride + x*4, d = (y*w+x)*3
            rgb[d]=p[s]; rgb[d+1]=p[s+1]; rgb[d+2]=p[s+2]
        } }
        return (rgb, w, h)
    }
}

/// External `cjpeg`/`djpeg`-style codec (libjpeg-turbo, mozjpeg, jpegli),
/// piping PPM in and JPEG/PPM out. Unavailable if the binaries aren't found.
struct CLILabCodec: LabCodec {
    let name: String
    let encoderPath: String?
    let decoderPath: String?
    let encoderArgs: @Sendable (Int) -> [String]
    var available: Bool { encoderPath != nil && decoderPath != nil }

    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        guard let path = encoderPath else { throw LabCodecError.message("\(name) not installed") }
        return try CLIProc.run(binary: path, args: encoderArgs(quality),
                               stdin: LabPPM.encode(rgb: rgb, width: width, height: height))
    }

    func decode(_ jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        guard let path = decoderPath else { throw LabCodecError.message("\(name) not installed") }
        return try LabPPM.decode(CLIProc.run(binary: path, args: [], stdin: jpeg))
    }

    static func libjpegTurbo() -> CLILabCodec {
        CLILabCodec(name: "libjpeg-turbo",
                    encoderPath: firstExisting(["/opt/homebrew/opt/jpeg-turbo/bin/cjpeg", "/usr/local/opt/jpeg-turbo/bin/cjpeg"]),
                    decoderPath: firstExisting(["/opt/homebrew/opt/jpeg-turbo/bin/djpeg", "/usr/local/opt/jpeg-turbo/bin/djpeg"]),
                    encoderArgs: { ["-quality", "\($0)", "-optimize"] })
    }
    static func mozjpeg() -> CLILabCodec {
        CLILabCodec(name: "mozjpeg",
                    encoderPath: firstExisting(["/opt/homebrew/opt/mozjpeg/bin/cjpeg", "/usr/local/opt/mozjpeg/bin/cjpeg"]),
                    decoderPath: firstExisting(["/opt/homebrew/opt/mozjpeg/bin/djpeg", "/usr/local/opt/mozjpeg/bin/djpeg",
                                                "/opt/homebrew/opt/jpeg-turbo/bin/djpeg"]),
                    encoderArgs: { ["-quality", "\($0)"] })
    }
    static func jpegli() -> CLILabCodec {
        CLILabCodec(name: "jpegli",
                    encoderPath: firstExisting(["/opt/homebrew/opt/jpegli/bin/cjpegli", "/opt/homebrew/opt/jpeg-xl/bin/cjpegli", "/usr/local/opt/jpegli/bin/cjpegli"]),
                    decoderPath: firstExisting(["/opt/homebrew/opt/jpeg-turbo/bin/djpeg", "/usr/local/opt/jpeg-turbo/bin/djpeg"]),
                    encoderArgs: { ["--quality", "\($0)", "-", "-"] })
    }
}

private func firstExisting(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

enum LabCodecError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let m): return m } }
}

enum CLIProc {
    static func run(binary: String, args: [String], stdin: [UInt8]) throws -> [UInt8] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe; proc.standardOutput = outPipe; proc.standardError = errPipe
        try proc.run()
        let wh = inPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async { wh.write(Data(stdin)); try? wh.close() }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LabCodecError.message("\(URL(fileURLWithPath: binary).lastPathComponent) exit \(proc.terminationStatus): \(err.split(separator: "\n").first.map(String.init) ?? "")")
        }
        return [UInt8](out)
    }
}

// MARK: - PPM (P6)

enum LabPPM {
    static func encode(rgb: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = Array("P6\n\(width) \(height)\n255\n".utf8)
        out += rgb
        return out
    }

    static func decode(_ data: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        var i = 0
        func token() throws -> String {
            while i < data.count, data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D || data[i] == 0x09 { i += 1 }
            if i < data.count, data[i] == UInt8(ascii: "#") { while i < data.count, data[i] != 0x0A { i += 1 }; return try token() }
            var s = [UInt8]()
            while i < data.count, !(data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D || data[i] == 0x09) { s.append(data[i]); i += 1 }
            return String(bytes: s, encoding: .ascii) ?? ""
        }
        guard try token() == "P6" else { throw LabCodecError.message("PPM: not P6") }
        guard let w = Int(try token()), let h = Int(try token()), let mx = Int(try token()), mx == 255 else {
            throw LabCodecError.message("PPM: bad header")
        }
        i += 1   // single whitespace after maxval
        let need = w * h * 3
        guard i + need <= data.count else { throw LabCodecError.message("PPM: truncated") }
        return (Array(data[i..<(i+need)]), w, h)
    }
}

// MARK: - Runner

enum CrossCodecRunner {
    static func run(rgb8: [UInt8], width: Int, height: Int, quality: Int,
                    jliConfig: JLIEncoderConfiguration) -> CrossCodecReport {
        let jli = JLISwiftLabCodec(base: jliConfig)
        let imageIO = ImageIOLabCodec()
        let turbo = CLILabCodec.libjpegTurbo()
        let moz = CLILabCodec.mozjpeg()
        let jpegli = CLILabCodec.jpegli()
        let codecs: [LabCodec] = [jli, imageIO, turbo, moz, jpegli]

        var rows: [CrossCodecRow] = []
        for c in codecs {
            guard c.available else { rows.append(CrossCodecRow(name: c.name, available: false)); continue }
            do {
                let t0 = Date()
                let jpeg = try c.encode(rgb: rgb8, width: width, height: height, quality: quality)
                let encMs = Date().timeIntervalSince(t0) * 1000
                let dec = try c.decode(jpeg)
                let cmp = min(rgb8.count, dec.rgb.count)
                let psnr = Metrics.psnr8(Array(rgb8.prefix(cmp)), Array(dec.rgb.prefix(cmp)))
                let ba = (dec.width == width && dec.height == height)
                    ? Butteraugli.distance(reference: rgb8, distorted: dec.rgb, width: width, height: height) : nil
                var row = CrossCodecRow(name: c.name, available: true)
                row.encodedBytes = jpeg.count
                row.bpp = Double(jpeg.count * 8) / Double(width * height)
                row.ratio = Double(width * height * 3) / Double(max(1, jpeg.count))
                row.psnr = psnr; row.butteraugli = ba; row.encodeMs = encMs
                rows.append(row)
            } catch {
                rows.append(CrossCodecRow(name: c.name, available: true, error: describe(error)))
            }
        }

        // Interop validation, both directions.
        var interop: [InteropResult] = []
        if let ours = try? jli.encode(rgb: rgb8, width: width, height: height, quality: quality) {
            interop.append(crossDecode("JLISwift → ImageIO", ours, imageIO, rgb8, width, height))
            if turbo.available { interop.append(crossDecode("JLISwift → libjpeg-turbo (djpeg)", ours, turbo, rgb8, width, height)) }
        }
        if let j = try? imageIO.encode(rgb: rgb8, width: width, height: height, quality: quality) {
            interop.append(crossDecode("ImageIO → JLISwift", j, jli, rgb8, width, height))
        }
        if turbo.available, let j = try? turbo.encode(rgb: rgb8, width: width, height: height, quality: quality) {
            interop.append(crossDecode("libjpeg-turbo → JLISwift", j, jli, rgb8, width, height))
        }
        if moz.available, let j = try? moz.encode(rgb: rgb8, width: width, height: height, quality: quality) {
            interop.append(crossDecode("mozjpeg → JLISwift", j, jli, rgb8, width, height))
        }
        return CrossCodecReport(quality: quality, width: width, height: height, rows: rows, interop: interop)
    }

    private static func crossDecode(_ label: String, _ jpeg: [UInt8], _ decoder: LabCodec,
                                    _ original: [UInt8], _ w: Int, _ h: Int) -> InteropResult {
        do {
            let dec = try decoder.decode(jpeg)
            guard dec.width == w && dec.height == h else {
                return InteropResult(label: label, ok: false, detail: "decoded \(dec.width)×\(dec.height), expected \(w)×\(h)")
            }
            let cmp = min(original.count, dec.rgb.count)
            let psnr = Metrics.psnr8(Array(original.prefix(cmp)), Array(dec.rgb.prefix(cmp)))
            return InteropResult(label: label, ok: true, detail: String(format: "OK · PSNR %.1f dB", psnr))
        } catch {
            return InteropResult(label: label, ok: false, detail: "failed: \(describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? LabCodecError { return e.description }
        if let e = error as? CustomStringConvertible { return e.description }
        return "\(error)"
    }
}
