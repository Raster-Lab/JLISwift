// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Perceptual quality metric via libjxl's `butteraugli_main`.
///
/// PSNR measures raw signal error and is the wrong tool for perceptually-tuned
/// techniques (adaptive quantization, XYB) — they can *lower* PSNR while
/// *raising* visual quality. Butteraugli models the human visual system: it
/// returns a distance where ~1.0 is the just-noticeable-difference threshold
/// and larger means more visible degradation. Lower is better.
///
/// The tool ships with the Homebrew `jpeg-xl` bottle. If it isn't found,
/// `distance` returns nil and the bench simply omits the column.
enum Butteraugli {

    /// Probed once: path to `butteraugli_main`, or nil if not installed.
    static let binaryPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/butteraugli_main",
            "/opt/homebrew/opt/jpeg-xl/bin/butteraugli_main",
            "/usr/local/bin/butteraugli_main",
            ProcessInfo.processInfo.environment["JLIBENCH_BUTTERAUGLI_BIN"] ?? "",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { binaryPath != nil }

    /// Returns the butteraugli distance between `reference` and `distorted`
    /// (both interleaved 8-bit RGB of the same dimensions), or nil if the tool
    /// is unavailable or fails. Writes the two images as temporary PPMs since
    /// `butteraugli_main` takes file paths.
    static func distance(
        reference: [UInt8], distorted: [UInt8], width: Int, height: Int
    ) -> Double? {
        guard let bin = binaryPath else { return nil }
        guard reference.count == width * height * 3,
              distorted.count == width * height * 3 else { return nil }

        let tmp = NSTemporaryDirectory()
        let token = UUID().uuidString
        let refPath = "\(tmp)ba-ref-\(token).ppm"
        let distPath = "\(tmp)ba-dist-\(token).ppm"
        defer {
            try? FileManager.default.removeItem(atPath: refPath)
            try? FileManager.default.removeItem(atPath: distPath)
        }

        do {
            try Data(PPM.encode(rgb: reference, width: width, height: height))
                .write(to: URL(fileURLWithPath: refPath))
            try Data(PPM.encode(rgb: distorted, width: width, height: height))
                .write(to: URL(fileURLWithPath: distPath))
        } catch {
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [refPath, distPath]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()  // discard
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        // First stdout line is the max-norm distance, e.g. "1.2345678".
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let firstLine = text.split(separator: "\n").first,
              let value = Double(firstLine.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return value
    }
}
