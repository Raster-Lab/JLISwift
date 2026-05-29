// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

enum Metrics {
    /// PSNR (dB) between two equal-length 8-bit buffers. `.infinity` if identical.
    static func psnr8(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return .nan }
        var sse = 0.0
        for i in 0..<n { let d = Double(a[i]) - Double(b[i]); sse += d * d }
        if sse == 0 { return .infinity }
        return 10.0 * log10((255.0 * 255.0) / (sse / Double(n)))
    }

    /// PSNR (dB) between two 16-bit sample buffers against `peak` (e.g. 4095 for 12-bit).
    static func psnr16(_ a: [UInt16], _ b: [UInt16], peak: Double) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return .nan }
        var sse = 0.0
        for i in 0..<n { let d = Double(a[i]) - Double(b[i]); sse += d * d }
        if sse == 0 { return .infinity }
        return 10.0 * log10((peak * peak) / (sse / Double(n)))
    }

    static func maxAbs8(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = min(a.count, b.count)
        var m = 0
        for i in 0..<n { let d = abs(Int(a[i]) - Int(b[i])); if d > m { m = d } }
        return m
    }

    static func maxAbs16(_ a: [UInt16], _ b: [UInt16]) -> Int {
        let n = min(a.count, b.count)
        var m = 0
        for i in 0..<n { let d = abs(Int(a[i]) - Int(b[i])); if d > m { m = d } }
        return m
    }
}

/// Perceptual quality metric via libjxl's `butteraugli_main` (Homebrew `jpeg-xl`).
/// Returns a distance where ~1.0 is the just-noticeable-difference threshold;
/// lower is better. `nil` when the tool isn't installed or the inputs don't match.
enum Butteraugli {
    static let binaryPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/butteraugli_main",
            "/opt/homebrew/opt/jpeg-xl/bin/butteraugli_main",
            "/usr/local/bin/butteraugli_main",
            ProcessInfo.processInfo.environment["JLI_BUTTERAUGLI_BIN"] ?? "",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { binaryPath != nil }

    static func distance(reference: [UInt8], distorted: [UInt8], width: Int, height: Int) -> Double? {
        guard let bin = binaryPath else { return nil }
        guard reference.count == width * height * 3,
              distorted.count == width * height * 3 else { return nil }

        let tmp = NSTemporaryDirectory()
        let token = UUID().uuidString
        let refPath = "\(tmp)jlilab-ref-\(token).ppm"
        let distPath = "\(tmp)jlilab-dist-\(token).ppm"
        defer {
            try? FileManager.default.removeItem(atPath: refPath)
            try? FileManager.default.removeItem(atPath: distPath)
        }
        do {
            try writePPM(reference, width: width, height: height, to: refPath)
            try writePPM(distorted, width: width, height: height, to: distPath)
        } catch { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [refPath, distPath]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let text = String(data: data, encoding: .utf8) ?? ""
        guard let first = text.split(separator: "\n").first,
              let value = Double(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value
    }

    private static func writePPM(_ rgb: [UInt8], width: Int, height: Int, to path: String) throws {
        var data = Data("P6\n\(width) \(height)\n255\n".utf8)
        data.append(contentsOf: rgb)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
