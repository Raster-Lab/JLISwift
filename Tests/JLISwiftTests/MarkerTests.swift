// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Testing
@testable import JLISwift

@Suite("JPEG Markers – Writer and Reader")
struct MarkerTests {

    // MARK: - Marker Writer

    @Test("SOI marker is correctly written")
    func soiMarker() {
        var writer = MarkerWriter()
        writer.writeSOI()
        #expect(writer.data == [0xFF, 0xD8])
    }

    @Test("EOI marker is correctly written")
    func eoiMarker() {
        var writer = MarkerWriter()
        writer.writeEOI()
        #expect(writer.data == [0xFF, 0xD9])
    }

    @Test("APP0 marker starts with correct identifier")
    func app0Marker() {
        var writer = MarkerWriter()
        writer.writeAPP0()
        // Should start with FF E0
        #expect(writer.data[0] == 0xFF)
        #expect(writer.data[1] == 0xE0)
        // Should contain "JFIF\0" identifier
        #expect(writer.data[4] == 0x4A)  // J
        #expect(writer.data[5] == 0x46)  // F
        #expect(writer.data[6] == 0x49)  // I
        #expect(writer.data[7] == 0x46)  // F
        #expect(writer.data[8] == 0x00)  // null
    }

    @Test("DQT marker writes quantization table")
    func dqtMarker() {
        var writer = MarkerWriter()
        let values = [UInt8](repeating: 16, count: 64)
        writer.writeDQT(tables: [(id: 0, values: values)])
        // FF DB, length 67 (2 + 65), table_id 0, 64 values
        #expect(writer.data[0] == 0xFF)
        #expect(writer.data[1] == 0xDB)
        // Length = 67 = 0x0043
        #expect(writer.data[2] == 0x00)
        #expect(writer.data[3] == 0x43)
    }

    @Test("SOF0 marker for grayscale")
    func sof0Grayscale() {
        var writer = MarkerWriter()
        writer.writeSOF(progressive: false, precision: 8, width: 16, height: 16,
                        components: [(id: 1, hSampling: 1, vSampling: 1, quantTableId: 0)])
        #expect(writer.data[0] == 0xFF)
        #expect(writer.data[1] == 0xC0)  // SOF0
    }

    @Test("SOF2 marker for progressive")
    func sof2Progressive() {
        var writer = MarkerWriter()
        writer.writeSOF(progressive: true, precision: 8, width: 16, height: 16,
                        components: [(id: 1, hSampling: 1, vSampling: 1, quantTableId: 0)])
        #expect(writer.data[0] == 0xFF)
        #expect(writer.data[1] == 0xC2)  // SOF2
    }

    // MARK: - Marker Reader

    @Test("MarkerReader reads SOF0 frame info correctly")
    func readerParsesSof0() throws {
        // Build a minimal JPEG: SOI + SOF0 with 1 grayscale component
        var data: [UInt8] = [0xFF, 0xD8]  // SOI

        // SOF0
        data.append(contentsOf: [0xFF, 0xC0])
        data.append(contentsOf: [0x00, 0x0B])  // Length: 11
        data.append(8)     // Precision
        data.append(contentsOf: [0x00, 0x10])  // Height: 16
        data.append(contentsOf: [0x00, 0x20])  // Width: 32
        data.append(1)     // 1 component
        data.append(1)     // Component ID
        data.append(0x11)  // Sampling: 1x1
        data.append(0)     // Quant table 0

        data.append(contentsOf: [0xFF, 0xD9])  // EOI

        var reader = MarkerReader(data: data)
        let info = try reader.readInfo()

        #expect(info.width == 32)
        #expect(info.height == 16)
        #expect(info.componentCount == 1)
        #expect(info.bitsPerComponent == 8)
        #expect(info.isProgressive == false)
    }

    @Test("MarkerReader detects progressive SOF2")
    func readerDetectsProgressive() throws {
        var data: [UInt8] = [0xFF, 0xD8]  // SOI

        // SOF2 (progressive)
        data.append(contentsOf: [0xFF, 0xC2])
        data.append(contentsOf: [0x00, 0x0B])  // Length: 11
        data.append(8)     // Precision
        data.append(contentsOf: [0x00, 0x08])  // Height: 8
        data.append(contentsOf: [0x00, 0x08])  // Width: 8
        data.append(1)     // 1 component
        data.append(1)     // Component ID
        data.append(0x11)  // Sampling: 1×1
        data.append(0)     // Quant table 0

        data.append(contentsOf: [0xFF, 0xD9])  // EOI

        var reader = MarkerReader(data: data)
        let info = try reader.readInfo()
        #expect(info.isProgressive == true)
    }

    @Test("MarkerReader rejects non-JPEG data")
    func readerRejectsNonJPEG() {
        var reader = MarkerReader(data: [0x89, 0x50, 0x4E, 0x47])  // PNG magic
        #expect(throws: JLIError.self) {
            try reader.readInfo()
        }
    }

    @Test("MarkerReader detects 4:2:0 subsampling")
    func readerDetects420() throws {
        var data: [UInt8] = [0xFF, 0xD8]  // SOI

        // SOF0 with 3 YCbCr components, 4:2:0
        data.append(contentsOf: [0xFF, 0xC0])
        data.append(contentsOf: [0x00, 0x11])  // Length: 17
        data.append(8)
        data.append(contentsOf: [0x00, 0x10])  // Height: 16
        data.append(contentsOf: [0x00, 0x10])  // Width: 16
        data.append(3)     // 3 components

        data.append(1)     // Y
        data.append(0x22)  // 2×2 sampling
        data.append(0)

        data.append(2)     // Cb
        data.append(0x11)  // 1×1 sampling
        data.append(1)

        data.append(3)     // Cr
        data.append(0x11)  // 1×1 sampling
        data.append(1)

        data.append(contentsOf: [0xFF, 0xD9])  // EOI

        var reader = MarkerReader(data: data)
        let info = try reader.readInfo()
        #expect(info.chromaSubsampling == .yuv420)
        #expect(info.componentCount == 3)
    }

    @Test("Writer and reader round-trip SOI")
    func writerReaderRoundTrip() throws {
        var writer = MarkerWriter()
        writer.writeSOI()
        writer.writeAPP0()
        writer.writeSOF(progressive: false, precision: 8, width: 100, height: 50,
                        components: [
                            (id: 1, hSampling: 2, vSampling: 2, quantTableId: 0),
                            (id: 2, hSampling: 1, vSampling: 1, quantTableId: 1),
                            (id: 3, hSampling: 1, vSampling: 1, quantTableId: 1)
                        ])
        writer.writeEOI()

        var reader = MarkerReader(data: writer.data)
        let info = try reader.readInfo()
        #expect(info.width == 100)
        #expect(info.height == 50)
        #expect(info.componentCount == 3)
    }
}
