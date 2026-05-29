// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import CoreGraphics
import Observation

/// Round-trip outcome carried back from the detached compute task. A bespoke
/// `Sendable` enum (rather than `Result`, whose `Failure` must be an `Error`)
/// lets the failure case carry a plain, already-formatted message string.
enum RunResult: Sendable {
    case success(RoundTripOutput)
    case failure(String)
}

enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case sideBySide = "Side by side"
    case original = "Original"
    case decoded = "Decoded"
    case difference = "Difference"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    var source: SourceImage?
    var settings = LabSettings()
    var output: RoundTripOutput?

    var isRunning = false
    var errorMessage: String?
    var statusMessage = "Open a DICOM (.dcm) or image file to begin."

    // View state — changing these never re-encodes.
    var viewMode: ViewMode = .sideBySide
    var diffAmplification: Double = 10

    // Derived, rendered on the main actor from Sendable buffers.
    var originalImage: CGImage?
    var decodedImage: CGImage?
    var differenceImage: CGImage?

    // Cross-codec comparison (8-bit RGB) against reference codecs.
    var crossReport: CrossCodecReport?
    var isComparing = false
    var showCrossSheet = false

    // Rate–distortion curve (quality sweep across codecs).
    var rdReport: RDReport?
    var isComputingRD = false
    var showRDSheet = false
    var rdMetric: RDMetric = .butteraugli

    private var runTask: Task<Void, Never>?

    var butteraugliAvailable: Bool { Butteraugli.isAvailable }
    var highBitAvailable: Bool { source?.gray12 != nil }

    func open(url: URL) {
        errorMessage = nil
        do {
            let src = try ImageLoader.load(url: url)
            source = src
            if src.gray12 == nil && settings.mode == .gray12 { settings.mode = .rgb8 }
            originalImage = Render.cgImage(rgb8: src.rgb8, width: src.width, height: src.height)
            statusMessage = src.kind
            run()
        } catch {
            source = nil
            output = nil
            originalImage = nil; decodedImage = nil; differenceImage = nil
            errorMessage = describe(error)
        }
    }

    /// Re-runs the round-trip for the current source + settings, debounced and
    /// cancellable so dragging a slider doesn't queue a backlog of encodes.
    func run() {
        guard let src = source else { return }
        runTask?.cancel()
        let settings = self.settings
        isRunning = true
        errorMessage = nil

        runTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }

            let result: RunResult = await Task.detached(priority: .userInitiated) {
                do { return .success(try RoundTripEngine.run(source: src, settings: settings)) }
                catch { return .failure(Self.describe(error)) }
            }.value

            if Task.isCancelled { return }
            guard let self else { return }
            self.isRunning = false
            switch result {
            case .success(let out):
                self.output = out
                self.decodedImage = Render.cgImage(rgb8: out.decodedRGB8, width: out.width, height: out.height)
                self.recomputeDifference()
            case .failure(let message):
                self.output = nil
                self.decodedImage = nil
                self.differenceImage = nil
                self.errorMessage = message
            }
        }
    }

    /// Runs the loaded image (as 8-bit RGB, at the current quality) through
    /// JLISwift + available reference codecs, plus both-directions interop checks.
    func runCrossCodec() {
        guard let src = source else { return }
        let rgb = src.rgb8, w = src.width, h = src.height
        let q = max(1, min(100, Int(settings.quality.rounded())))
        var s = settings
        s.mode = .rgb8; s.lossless = false; s.useDistance = false; s.quality = Double(q)
        let cfg = s.encoderConfiguration()

        crossReport = nil
        isComparing = true
        showCrossSheet = true
        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                CrossCodecRunner.run(rgb8: rgb, width: w, height: h, quality: q, jliConfig: cfg)
            }.value
            guard let self else { return }
            self.crossReport = report
            self.isComparing = false
        }
    }

    /// Sweeps quality across all codecs to build rate–distortion curves. Many
    /// encodes + metric runs, so it's explicit and runs off-main with a spinner.
    func runRDCurve() {
        guard let src = source else { return }
        let rgb = src.rgb8, w = src.width, h = src.height
        var s = settings
        s.mode = .rgb8; s.lossless = false; s.useDistance = false
        let cfg = s.encoderConfiguration()

        rdReport = nil
        isComputingRD = true
        showRDSheet = true
        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                RDCurveRunner.run(rgb8: rgb, width: w, height: h, jliConfig: cfg)
            }.value
            guard let self else { return }
            self.rdReport = report
            self.isComputingRD = false
        }
    }

    func recomputeDifference() {
        guard let src = source, let out = output else { differenceImage = nil; return }
        differenceImage = Render.differenceImage(
            original: src.rgb8, decoded: out.decodedRGB8,
            width: out.width, height: out.height, amplification: diffAmplification
        )
    }

    func saveEncoded(to url: URL) throws {
        guard let out = output else { return }
        try Data(out.encoded).write(to: url)
    }

    private func describe(_ error: Error) -> String { Self.describe(error) }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        // DICOMError / LoadError are CustomStringConvertible, so this surfaces
        // their `.description`; other errors fall back to a readable form.
        return String(describing: error)
    }
}
