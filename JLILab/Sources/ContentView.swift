// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import SwiftUI
import AppKit
import Charts
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
                Button { model.runCrossCodec() } label: { Label("Compare codecs", systemImage: "rectangle.split.3x1") }
                    .disabled(model.source == nil)
                Button { model.runRDCurve() } label: { Label("RD curve", systemImage: "chart.xyaxis.line") }
                    .disabled(model.source == nil)
                Button { saveEncoded() } label: { Label("Save JPEG", systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.output == nil)
            }
        }
        .onChange(of: model.settings) { _, _ in model.run() }
        .onChange(of: model.diffAmplification) { _, _ in model.recomputeDifference() }
        .sheet(isPresented: $model.showCrossSheet) { CrossCodecSheet(model: model) }
        .sheet(isPresented: $model.showRDSheet) { RDCurveSheet(model: model) }
        .frame(minWidth: 900, minHeight: 560)
        .task { openLaunchArgumentFileIfPresent() }
    }

    /// Opens a file path passed on the command line (e.g. launching the binary with
    /// a path argument) so the lab can be scripted or pointed at a specific file.
    private func openLaunchArgumentFileIfPresent() {
        guard model.source == nil else { return }
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) { model.open(url: url); break }
        }
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

/// Standard CT window/level presets, in Hounsfield units. Only offered for CT,
/// where pixel intensities are HU after the Modality LUT.
private struct WindowPreset: Identifiable {
    let name: String
    let center: Double
    let width: Double
    var id: String { name }

    static let ctPresets: [WindowPreset] = [
        .init(name: "Soft", center: 40, width: 400),
        .init(name: "Lung", center: -600, width: 1500),
        .init(name: "Bone", center: 300, width: 1500),
        .init(name: "Brain", center: 40, width: 80),
    ]
}

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

                frameSection
                windowSection
                pipelineSection
                if model.settings.lossless { losslessSection } else { lossySection }
                Divider()
                MetricsView(model: model)
            }
            .padding(16)
        }
    }

    /// Frame scrubber — shown only for multi-frame (cine) sources, whose frames
    /// were all decoded concurrently at load. Scrubbing swaps the pre-decoded
    /// frame in and re-runs the round-trip on it; nothing is re-decoded.
    @ViewBuilder private var frameSection: some View {
        if let src = model.source, src.frames.count > 1 {
            GroupBox("Cine Frame") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Frame")
                        Spacer()
                        Text("\(model.frameIndex + 1) / \(src.frames.count)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.frameIndex) },
                            set: { model.selectFrame(Int($0.rounded())) }
                        ),
                        in: 0...Double(src.frames.count - 1), step: 1
                    )
                }.padding(6)
            }
        }
    }

    /// Window/level controls — shown only for monochrome DICOM. Dragging a slider
    /// re-windows the source (8- and 12-bit) and re-runs the round-trip. Named
    /// presets appear for CT, where pixels are in Hounsfield units.
    @ViewBuilder private var windowSection: some View {
        if let src = model.source, src.isWindowable {
            GroupBox("Window / Level") {
                VStack(alignment: .leading, spacing: 8) {
                    windowSlider("Center", value: windowBinding(\.windowCenter), range: centerRange(src))
                    windowSlider("Width", value: windowBinding(\.windowWidth), range: widthRange(src))
                    if src.isCT {
                        HStack(spacing: 6) {
                            ForEach(WindowPreset.ctPresets) { p in
                                Button(p.name) {
                                    model.windowCenter = p.center
                                    model.windowWidth = p.width
                                    model.applyWindow()
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        Button("Reset") { model.resetWindow() }.controlSize(.small)
                        Spacer()
                        Text(src.isCT ? "Hounsfield units (CT)" : "scanner units")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }.padding(6)
            }
        }
    }

    /// A `Binding` over a window property that re-windows + re-encodes on every
    /// change, so the viewer tracks the slider live.
    private func windowBinding(_ keyPath: ReferenceWritableKeyPath<AppModel, Double>) -> Binding<Double> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.applyWindow() }
        )
    }

    private func centerRange(_ src: SourceImage) -> ClosedRange<Double> {
        // CT center lives in a clinical Hounsfield band; ignore the very low
        // out-of-FOV padding floor (often −8192) so the slider isn't mostly dead
        // travel. Other modalities use their actual intensity range.
        if src.isCT { return -1024...max(src.intensityRange.upperBound, 1024) }
        let lo = src.intensityRange.lowerBound
        let hi = src.intensityRange.upperBound
        return hi > lo ? lo...hi : (lo - 1)...(lo + 1)
    }

    private func widthRange(_ src: SourceImage) -> ClosedRange<Double> {
        if src.isCT { return 1...max(src.defaultWidth, 4000) }
        let hi = max(src.defaultWidth, src.intensityRange.upperBound - src.intensityRange.lowerBound, 2)
        return 1...hi
    }

    private func windowSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
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
                        row("Butteraugli ↓", String(format: "%.4f", ba))
                    } else if model.settings.mode == .rgb8 && !model.butteraugliAvailable {
                        row("Butteraugli ↓", "n/a (install jpeg-xl)")
                    }
                    if let s2 = out.ssimulacra2 {
                        row("SSIMULACRA2 ↑", String(format: "%.2f", s2))
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

// MARK: - Cross-codec sheet

private struct CrossCodecSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cross-codec comparison").font(.title3).bold()
                Spacer()
                Button("Done") { model.showCrossSheet = false }.keyboardShortcut(.defaultAction)
            }
            if let r = model.crossReport {
                Text("8-bit RGB · \(r.width)×\(r.height) · quality \(r.quality)")
                    .font(.caption).foregroundStyle(.secondary)
                #if DEBUG
                Label("Debug build — encode times are ~100× slower than Release and not representative. Build the Release scheme for a real speed comparison.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
                comparisonTable(r)
                if r.rows.contains(where: { $0.spawnCorrected }) {
                    Text("Enc ms for shell-out codecs (libjpeg-turbo/mozjpeg/jpegli) is spawn-corrected (wall − 8×8 baseline). The fair in-process speed comparison is JLISwift vs ImageIO. PSNR/SSIM2/butteraugli are build-independent. b-augli: lower better; SSIM2: higher better.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("Interoperability (encode → decode across codecs)").font(.headline)
                interopList(r)
            } else if model.isComparing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Encoding with each codec…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }

    private func comparisonTable(_ r: CrossCodecReport) -> some View {
        VStack(spacing: 0) {
            HStack {
                cell("Codec", 130, .leading).bold()
                cell("Size", 72).bold(); cell("Ratio", 54).bold()
                cell("PSNR", 62).bold(); cell("b-augli", 64).bold()
                cell("SSIM2", 60).bold(); cell("Enc ms", 64).bold()
            }.font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(r.rows) { row in
                HStack {
                    cell(row.name, 130, .leading)
                    if !row.available {
                        Text("not installed").font(.caption).foregroundStyle(.tertiary)
                            .frame(width: 376, alignment: .leading)
                    } else if let err = row.error {
                        Text(err).font(.caption).foregroundStyle(.orange)
                            .frame(width: 376, alignment: .leading).lineLimit(1)
                    } else {
                        cell(byteString(row.encodedBytes), 72)
                        cell(String(format: "%.1f×", row.ratio), 54)
                        cell(row.psnr.isInfinite ? "∞" : String(format: "%.1f", row.psnr), 62)
                        cell(row.butteraugli.map { String(format: "%.3f", $0) } ?? "–", 64)
                        cell(row.ssimulacra2.map { String(format: "%.1f", $0) } ?? "–", 60)
                        cell(row.spawnCorrected ? String(format: "%.0f*", row.encodeMs) : String(format: "%.0f", row.encodeMs), 64)
                    }
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 3)
                .background(row.name == "JLISwift" ? Color.accentColor.opacity(0.10) : .clear)
            }
        }
    }

    private func interopList(_ r: CrossCodecReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if r.interop.isEmpty {
                Text("No interop checks available (reference codecs not installed).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(r.interop) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.ok ? .green : .red)
                    Text(item.label).frame(width: 280, alignment: .leading)
                    Text(item.detail).foregroundStyle(.secondary)
                    Spacer()
                }.font(.callout)
            }
        }
    }

    private func cell(_ s: String, _ w: CGFloat, _ align: Alignment = .trailing) -> some View {
        Text(s).frame(width: w, alignment: align)
    }

    private func byteString(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - RD-curve sheet

private struct RDCurveSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rate–distortion curves").font(.title3).bold()
                Spacer()
                Button("Done") { model.showRDSheet = false }.keyboardShortcut(.defaultAction)
            }
            if let r = model.rdReport {
                Text("8-bit RGB · \(r.width)×\(r.height) · quality sweep \(r.qualities.first ?? 0)–\(r.qualities.last ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Metric", selection: $model.rdMetric) {
                    ForEach(RDMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                chart(r)
                Text("Each line is a codec across the quality sweep. Compare codecs at the **same bpp** (x-axis): for Butteraugli, lower is better (curve nearer the bottom wins); for SSIMULACRA2/PSNR, higher wins.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else if model.isComputingRD {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Encoding the quality sweep across every codec (many encodes + metric runs)…\nSlower on large images.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }

    private func chart(_ r: RDReport) -> some View {
        let m = model.rdMetric
        let pts = r.points
            .filter { $0.value(m) != nil }
            .sorted { ($0.codec, $0.bpp) < ($1.codec, $1.bpp) }
        return Chart(pts) { p in
            LineMark(x: .value("bpp", p.bpp), y: .value("metric", p.value(m) ?? 0))
                .foregroundStyle(by: .value("Codec", p.codec))
            PointMark(x: .value("bpp", p.bpp), y: .value("metric", p.value(m) ?? 0))
                .foregroundStyle(by: .value("Codec", p.codec))
                .symbolSize(40)
        }
        .chartXAxisLabel("bits per pixel (→ larger file)")
        .chartYAxisLabel(m.rawValue)
        .chartLegend(position: .bottom)
        .frame(minHeight: 360)
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
