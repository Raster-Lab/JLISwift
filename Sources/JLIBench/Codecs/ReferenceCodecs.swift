// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// A `Codec` that runs an external command-line encoder/decoder, piping pixel
/// data in via PPM on stdin and reading JPEG (or PPM) back from stdout.
///
/// Three concrete codecs ship below — libjpeg-turbo, mozjpeg, and jpegli —
/// all of which speak the same `cjpeg`/`djpeg` CLI dialect or a near-dialect.
///
/// Availability is determined at init time by probing the configured paths.
/// If neither candidate path exists `enabled` is false and the bench skips
/// this codec rather than failing every row.
struct CLICodec: Codec {
    let name: String
    /// Path to the encoder binary, or nil if no candidate was found.
    let encoderPath: String?
    /// Path to the decoder binary (often the same project's `djpeg`).
    let decoderPath: String?
    /// Builds the encoder argv for a given quality. Stdin = PPM, stdout = JPEG.
    let encoderArgs: @Sendable (Int) -> [String]
    let isExternal = true

    /// `enabled` is what the bench checks before adding the codec to its codec
    /// list — encode/decode will throw `CodecError.unavailable` otherwise.
    var enabled: Bool { encoderPath != nil && decoderPath != nil }

    func encode(rgb: [UInt8], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        guard let path = encoderPath else { throw CodecError.unavailable(name) }
        let ppm = PPM.encode(rgb: rgb, width: width, height: height)
        return try CLIProcess.run(binary: path, args: encoderArgs(quality), stdin: ppm)
    }

    func decode(jpeg: [UInt8]) throws -> (rgb: [UInt8], width: Int, height: Int) {
        guard let path = decoderPath else { throw CodecError.unavailable(name) }
        // `djpeg` (libjpeg-turbo/mozjpeg) writes PPM to stdout by default.
        let ppm = try CLIProcess.run(binary: path, args: [], stdin: jpeg)
        return try PPM.decode(ppm)
    }
}

/// Runs an external binary, feeding `stdin` bytes and capturing stdout bytes.
enum CLIProcess {
    /// Throws `CodecError.processFailed` (with stderr) on non-zero exit.
    static func run(binary: String, args: [String], stdin: [UInt8]) throws -> [UInt8] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        // Write input on a background thread so a large stdin doesn't deadlock
        // against a small stdout pipe buffer.
        let writeHandle = inPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            writeHandle.write(Data(stdin))
            try? writeHandle.close()
        }

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "<binary stderr>"
            throw CodecError.processFailed(
                command: "\(binary) \(args.joined(separator: " "))",
                exitCode: Int(proc.terminationStatus),
                stderr: errStr
            )
        }
        return [UInt8](stdoutData)
    }
}

enum CodecError: Error, CustomStringConvertible {
    case unavailable(String)
    case processFailed(command: String, exitCode: Int, stderr: String)
    var description: String {
        switch self {
        case .unavailable(let name):
            return "\(name) is not installed (set $JLIBENCH_<NAME>_BIN or install via brew)"
        case .processFailed(let cmd, let code, let err):
            // Trim long stderr — the diff/regression table doesn't need a wall of text.
            let trimmed = err.split(separator: "\n").prefix(3).joined(separator: " ")
            return "\(cmd) exit \(code): \(trimmed)"
        }
    }
}

// MARK: - Concrete codecs

/// Returns the first existing file from `candidates`, or nil if none exist.
/// The bench probes a small set of well-known Homebrew/system paths.
private func firstExisting(_ candidates: [String]) -> String? {
    for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
        return p
    }
    return nil
}

/// 12-bit grayscale shell-out codec. Pipes 16-bit PGM through
/// `cjpeg -precision 12` and `djpeg`, both of which natively read/write the
/// netpbm 16-bit (big-endian) format. libjpeg-turbo 3.x is the only widely
/// installed encoder with a 12-bit path, so this is the cross-codec reference
/// for JLISwift's 12-bit output.
struct Gray16CLICodec: Gray16Codec {
    let name: String
    let encoderPath: String?
    let decoderPath: String?
    let isExternal = true
    var enabled: Bool { encoderPath != nil && decoderPath != nil }

    func encodeGray16(_ samples: [UInt16], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        guard let path = encoderPath else { throw CodecError.unavailable(name) }
        let pgm = PGM16.encode(gray: samples, width: width, height: height, maxVal: 4095)
        return try CLIProcess.run(
            binary: path, args: ["-precision", "12", "-quality", "\(quality)"], stdin: pgm
        )
    }

    func decodeGray16(_ jpeg: [UInt8]) throws -> (gray: [UInt16], width: Int, height: Int) {
        guard let path = decoderPath else { throw CodecError.unavailable(name) }
        let pgm = try CLIProcess.run(binary: path, args: [], stdin: jpeg)
        return try PGM16.decode(pgm)
    }
}

/// 12-bit color shell-out codec. Pipes 16-bit PPM through `cjpeg -precision 12`
/// and `djpeg`. Forced to 4:4:4 (`-sample 1x1`) so cross-codec PSNR isn't muddied
/// by cjpeg's default 2×2 chroma subsampling — the cross-codec reference for
/// JLISwift's 12-bit color output.
struct Color16CLICodec: Color16Codec {
    let name: String
    let encoderPath: String?
    let decoderPath: String?
    let isExternal = true
    var enabled: Bool { encoderPath != nil && decoderPath != nil }

    func encodeColor16(_ rgb: [UInt16], width: Int, height: Int, quality: Int) throws -> [UInt8] {
        guard let path = encoderPath else { throw CodecError.unavailable(name) }
        let ppm = PPM16.encode(rgb: rgb, width: width, height: height, maxVal: 4095)
        return try CLIProcess.run(
            binary: path,
            args: ["-precision", "12", "-quality", "\(quality)", "-sample", "1x1"], stdin: ppm
        )
    }

    func decodeColor16(_ jpeg: [UInt8]) throws -> (rgb: [UInt16], width: Int, height: Int) {
        guard let path = decoderPath else { throw CodecError.unavailable(name) }
        let ppm = try CLIProcess.run(binary: path, args: [], stdin: jpeg)
        return try PPM16.decode(ppm)
    }
}

enum ReferenceCodecs {

    /// libjpeg-turbo's `cjpeg`/`djpeg`. Apple's ImageIO uses libjpeg-turbo too
    /// internally — this independent install is a sanity check that our
    /// JLISwift output decodes outside the Apple stack.
    static func libjpegTurbo() -> CLICodec {
        let enc = firstExisting([
            "/opt/homebrew/opt/jpeg-turbo/bin/cjpeg",
            "/usr/local/opt/jpeg-turbo/bin/cjpeg",
            ProcessInfo.processInfo.environment["JLIBENCH_LIBJPEG_TURBO_BIN"] ?? "",
        ])
        let dec = firstExisting([
            "/opt/homebrew/opt/jpeg-turbo/bin/djpeg",
            "/usr/local/opt/jpeg-turbo/bin/djpeg",
        ])
        return CLICodec(
            name: "libjpeg-turbo", encoderPath: enc, decoderPath: dec,
            encoderArgs: { q in ["-quality", "\(q)", "-optimize"] }
        )
    }

    /// libjpeg-turbo in 12-bit mode (`cjpeg -precision 12`). The cross-codec
    /// reference for JLISwift's 12-bit grayscale output.
    static func libjpegTurbo12() -> Gray16CLICodec {
        let enc = firstExisting([
            "/opt/homebrew/opt/jpeg-turbo/bin/cjpeg",
            "/usr/local/opt/jpeg-turbo/bin/cjpeg",
            ProcessInfo.processInfo.environment["JLIBENCH_LIBJPEG_TURBO_BIN"] ?? "",
        ])
        let dec = firstExisting([
            "/opt/homebrew/opt/jpeg-turbo/bin/djpeg",
            "/usr/local/opt/jpeg-turbo/bin/djpeg",
        ])
        return Gray16CLICodec(name: "libjpeg-turbo-12", encoderPath: enc, decoderPath: dec)
    }

    /// libjpeg-turbo in 12-bit color mode (`cjpeg -precision 12`). The cross-codec
    /// reference for JLISwift's 12-bit color output.
    static func libjpegTurbo12Color() -> Color16CLICodec {
        let enc = firstExisting([
            "/opt/homebrew/opt/jpeg-turbo/bin/cjpeg",
            "/usr/local/opt/jpeg-turbo/bin/cjpeg",
            ProcessInfo.processInfo.environment["JLIBENCH_LIBJPEG_TURBO_BIN"] ?? "",
        ])
        let dec = firstExisting([
            "/opt/homebrew/opt/jpeg-turbo/bin/djpeg",
            "/usr/local/opt/jpeg-turbo/bin/djpeg",
        ])
        return Color16CLICodec(name: "libjpeg-turbo-12c", encoderPath: enc, decoderPath: dec)
    }

    /// Mozilla's mozjpeg encoder — drop-in `cjpeg`-API replacement with
    /// trellis quantization + tuned tables. Materially better compression
    /// than libjpeg-turbo at matched visual quality, so a good "improved
    /// baseline JPEG" reference.
    static func mozjpeg() -> CLICodec {
        let enc = firstExisting([
            "/opt/homebrew/opt/mozjpeg/bin/cjpeg",
            "/usr/local/opt/mozjpeg/bin/cjpeg",
            ProcessInfo.processInfo.environment["JLIBENCH_MOZJPEG_BIN"] ?? "",
        ])
        let dec = firstExisting([
            "/opt/homebrew/opt/mozjpeg/bin/djpeg",
            "/usr/local/opt/mozjpeg/bin/djpeg",
        ])
        // mozjpeg's default is progressive (SOF2) — JLISwift now decodes that,
        // so we let it use its native default, exercising the progressive path
        // in the cross-codec matrix.
        return CLICodec(
            name: "mozjpeg", encoderPath: enc, decoderPath: dec,
            encoderArgs: { q in ["-quality", "\(q)"] }
        )
    }

    /// Google's jpegli (`cjpegli`) — the reference JLISwift's long-term roadmap
    /// targets. Encodes baseline-compatible JPEGs with jpegli's adaptive
    /// quantization and tuned matrices. Decoding goes through libjpeg-turbo's
    /// `djpeg` since jpegli output is standard JPEG.
    static func jpegli() -> CLICodec {
        let enc = firstExisting([
            "/opt/homebrew/opt/jpegli/bin/cjpegli",
            "/opt/homebrew/opt/jpeg-xl/bin/cjpegli",
            "/usr/local/opt/jpegli/bin/cjpegli",
            ProcessInfo.processInfo.environment["JLIBENCH_JPEGLI_BIN"] ?? "",
        ])
        // jpegli has no dedicated decoder — its output is standard JPEG, so we
        // fall back to libjpeg-turbo's djpeg for the decode side.
        let dec = firstExisting([
            "/opt/homebrew/opt/jpeg-turbo/bin/djpeg",
            "/usr/local/opt/jpeg-turbo/bin/djpeg",
        ])
        return CLICodec(
            name: "jpegli", encoderPath: enc, decoderPath: dec,
            // cjpegli wants files, not stdin. We adapt at the call site by
            // mapping `-` to stdin; recent cjpegli builds support it.
            encoderArgs: { q in ["--quality", "\(q)", "-", "-"] }
        )
    }
}
