// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            ControlsSidebar(model: model)
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 420)
            ViewerPane(model: model)
                .frame(minWidth: 420, minHeight: 360)
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isRunning { ProgressView().controlSize(.small) }
                Button { openFile() } label: { Label("Open", systemImage: "folder") }
                    .keyboardShortcut("o", modifiers: .command)
                Button { saveEncoded() } label: { Label("Save JPEG", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.output == nil)
            }
        }
        .onChange(of: model.settings) { _, _ in model.run() }
        .onChange(of: model.diffAmplification) { _, _ in model.recomputeDifference() }
        .frame(minWidth: 900, minHeight: 560)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.image]
        if let dcm = UTType(filenameExtension: "dcm") { types.append(dcm) }
        if let dicom = UTType(filenameExtension: "dicom") { types.append(dicom) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { model.open(url: url) }
    }

    private func saveEncoded() {
        guard model.output != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        let base = model.source?.url?.deletingPathExtension().lastPathComponent ?? "compressed"
        panel.nameFieldStringValue = "\(base)-jliswift.jpg"
        if panel.runModal() == .OK, let url = panel.url {
            try? model.saveEncoded(to: url)
        }
    }
}

// MARK: - Controls

private struct ControlsSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.statusMessage)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let err = model.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                pipelineSection
                if model.settings.lossless { losslessSection } else { lossySection }
                Divider()
                MetricsView(model: model)
            }
            .padding(16)
        }
    }

    private var pipelineSection: some View {
        GroupBox("Pipeline") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $model.settings.mode) {
                    ForEach(LabMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                            .disabled(m == .gray12 && !model.highBitAvailable)
                    }
                }
                if model.settings.mode == .gray12 {
                    Text("12-bit grayscale from DICOM window/level.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Lossless (SOF3)", isOn: $model.settings.lossless)
            }.padding(6)
        }
    }

    private var lossySection: some View {
        GroupBox("Lossy DCT") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use distance (jpegli/JXL)", isOn: $model.settings.useDistance)
                if model.settings.useDistance {
                    labeledSlider("Distance", value: $model.settings.distance,
                                  range: 0.5...15, step: 0.1, format: "%.2f")
                } else {
                    labeledSlider("Quality", value: $model.settings.quality,
                                  range: 1...100, step: 1, format: "%.0f")
                }
                if model.settings.mode == .rgb8 {
                    Picker("Chroma", selection: $model.settings.subsampling) {
                        ForEach(LabSubsampling.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Color space", selection: $model.settings.colorSpace) {
                        ForEach(LabColorSpace.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Toggle("Progressive", isOn: $model.settings.progressive)
                if model.settings.progressive {
                    Picker("Scan script", selection: $model.settings.progressiveMode) {
                        ForEach(LabProgressiveMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Toggle("Optimized Huffman", isOn: $model.settings.optimiseHuffman)
                Toggle("Trellis quantization", isOn: $model.settings.adaptiveQuantization)
                Toggle("Adaptive-quant field", isOn: $model.settings.adaptiveQuantField)
                    .disabled(!model.settings.adaptiveQuantization)
                Toggle("Perceptual quant tables", isOn: $model.settings.perceptualQuantTables)
                    .disabled(model.settings.mode == .gray12)
                Stepper("Restart interval: \(model.settings.restartInterval)",
                        value: $model.settings.restartInterval, in: 0...512, step: 8)
            }.padding(6)
        }
    }

    private var losslessSection: some View {
        GroupBox("Lossless (SOF3)") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper("Predictor: \(model.settings.losslessPredictor)",
                        value: $model.settings.losslessPredictor, in: 1...7)
                Stepper("Near-lossless Pt: \(model.settings.losslessPointTransform)",
                        value: $model.settings.losslessPointTransform, in: 0...7)
                Text(model.settings.losslessPointTransform == 0
                     ? "Pt = 0 → bit-exact reconstruction."
                     : "Pt = \(model.settings.losslessPointTransform) → bounded error ≤ \((1 << model.settings.losslessPointTransform) - 1).")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private func labeledSlider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>,
        step: Double, format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

// MARK: - Metrics

private struct MetricsView: View {
    @Bindable var model: AppModel

    var body: some View {
        GroupBox("Result") {
            if let out = model.output {
                VStack(alignment: .leading, spacing: 6) {
                    Text(out.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    row("Encoded size", byteString(out.encodedBytes))
                    row("Compression", String(format: "%.1f× · %.3f bpp", out.compressionRatio, out.bpp))
                    row("PSNR", out.psnr.isInfinite ? "∞ (bit-exact)" : String(format: "%.2f dB", out.psnr))
                    row("Max abs error", "\(out.maxAbsError)")
                    if let ba = out.butteraugli {
                        row("Butteraugli", String(format: "%.4f", ba))
                    } else if model.settings.mode == .rgb8 && !model.butteraugliAvailable {
                        row("Butteraugli", "n/a (install jpeg-xl)")
                    }
                    row("Encode", String(format: "%.1f ms", out.encodeMs))
                    row("Decode", String(format: "%.1f ms", out.decodeMs))
                }.padding(6)
            } else {
                Text(model.source == nil ? "No image loaded." : "Encoding…")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.callout)
    }

    private func byteString(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - Viewer

private struct ViewerPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                Spacer()
                if model.viewMode == .difference {
                    HStack(spacing: 6) {
                        Text("Amplify").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.diffAmplification, in: 1...50)
                            .frame(width: 140)
                        Text(String(format: "%.0f×", model.diffAmplification))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    @ViewBuilder private var content: some View {
        if model.source == nil {
            ContentUnavailableView {
                Label("No image", systemImage: "photo")
            } description: {
                Text("Open a DICOM (.dcm) or standard image (PNG/JPEG/TIFF) to run a JLISwift round-trip.")
            }
        } else {
            switch model.viewMode {
            case .sideBySide:
                HStack(spacing: 1) {
                    ImagePane(title: "Original", image: model.originalImage)
                    ImagePane(title: "Decoded", image: model.decodedImage)
                }
            case .original:
                ImagePane(title: "Original", image: model.originalImage)
            case .decoded:
                ImagePane(title: "Decoded", image: model.decodedImage)
            case .difference:
                ImagePane(title: "Difference (amplified)", image: model.differenceImage)
            }
        }
    }
}

private struct ImagePane: View {
    let title: String
    let image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
