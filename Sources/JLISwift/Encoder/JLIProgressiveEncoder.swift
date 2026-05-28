// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Encodes per-component quantized coefficients (zigzag order) into progressive
/// (SOF2) scans — the inverse of ``ProgressiveDecoder``.
///
/// Scan script (spectral selection only, no successive approximation):
/// - one **DC scan**, all components interleaved (Ss=Se=0);
/// - one **AC scan per component** over the full band (Ss=1, Se=63),
///   non-interleaved, with end-of-band runs (EOBRUN) — the main progressive
///   compression lever: a run of blocks empty in the band collapses to one EOBn
///   symbol.
///
/// Four optimal Huffman tables (DC/AC × luma/chroma) are built from a counting
/// pass over the exact same walk the emit pass uses, and defined once up front;
/// every scan references them. Successive approximation (finer progressive
/// rendering, smaller files) is left for a later revision.
struct ProgressiveEncoder {
    let components: [JPEGComponentInfo]   // id, sampling, quantTableIndex
    let isGrayscale: Bool
    let mcuCountH: Int
    let mcuCountV: Int
    /// MCU-padded blocks per row, per component (coefficient storage stride).
    let blocksPerRow: [Int]
    /// Real data-unit grid per component (non-interleaved AC scans address this).
    let realBlocksW: [Int]
    let realBlocksH: [Int]
    /// Per-component **natural-order** quantized coefficients, block `b` at
    /// `b*64` (as produced by `quantizePlane`). AC indexing goes through
    /// `Quantization.zigzagOrder` to walk the spectral band in zigzag sequence.
    let quant: [[Int32]]

    struct ScanPlan {
        let sosComponents: [(selector: UInt8, dcTableId: Int, acTableId: Int)]
        let ss: Int
        let se: Int
        let entropy: [UInt8]
    }

    struct Output {
        /// (tableClass, tableId, bits, values) for a single DHT segment.
        let dhtTables: [(tableClass: Int, tableId: Int, bits: [UInt8], values: [UInt8])]
        let scans: [ScanPlan]
        let estimatedSize: Int
    }

    /// Component index → table id: luma (component 0) uses table 0, chroma uses 1.
    private func tableId(_ compIndex: Int) -> Int { compIndex == 0 ? 0 : 1 }

    func build() -> Output {
        // 1. Counting pass → four symbol-frequency histograms.
        var dcLumFreq = [Int](repeating: 0, count: 256)
        var dcChrFreq = [Int](repeating: 0, count: 256)
        var acLumFreq = [Int](repeating: 0, count: 256)
        var acChrFreq = [Int](repeating: 0, count: 256)

        countDC(dcLum: &dcLumFreq, dcChr: &dcChrFreq)
        for c in 0..<components.count {
            if c == 0 { countAC(component: c, freq: &acLumFreq) }
            else { countAC(component: c, freq: &acChrFreq) }
        }

        // 2. Build optimal tables.
        let dcLum = HuffmanTableBuilder.build(frequencies: dcLumFreq, fallback: StandardHuffmanTables.dcLuminance)
        let acLum = HuffmanTableBuilder.build(frequencies: acLumFreq, fallback: StandardHuffmanTables.acLuminance)
        var dht: [(tableClass: Int, tableId: Int, bits: [UInt8], values: [UInt8])] = [
            (0, 0, dcLum.bits, dcLum.values),
            (1, 0, acLum.bits, acLum.values),
        ]
        var dcChr = dcLum, acChr = acLum
        if !isGrayscale {
            dcChr = HuffmanTableBuilder.build(frequencies: dcChrFreq, fallback: StandardHuffmanTables.dcChrominance)
            acChr = HuffmanTableBuilder.build(frequencies: acChrFreq, fallback: StandardHuffmanTables.acChrominance)
            dht.append((0, 1, dcChr.bits, dcChr.values))
            dht.append((1, 1, acChr.bits, acChr.values))
        }

        // 3. Emit each scan.
        var scans = [ScanPlan]()
        var total = 0

        // DC scan: all components interleaved, Ss=Se=0.
        var dcSOS = [(selector: UInt8, dcTableId: Int, acTableId: Int)]()
        for c in 0..<components.count {
            dcSOS.append((components[c].id, tableId(c), 0))
        }
        let dcEntropy = emitDC(dcLum: dcLum, dcChr: dcChr)
        scans.append(ScanPlan(sosComponents: dcSOS, ss: 0, se: 0, entropy: dcEntropy))
        total += dcEntropy.count

        // AC scans: one per component, full band, non-interleaved.
        for c in 0..<components.count {
            let table = c == 0 ? acLum : acChr
            let entropy = emitAC(component: c, table: table)
            scans.append(ScanPlan(
                sosComponents: [(components[c].id, 0, tableId(c))],
                ss: 1, se: 63, entropy: entropy
            ))
            total += entropy.count
        }

        return Output(dhtTables: dht, scans: scans, estimatedSize: total + 1024)
    }

    // MARK: - DC scan (interleaved)

    private func countDC(dcLum: inout [Int], dcChr: inout [Int]) {
        var pred = [Int32](repeating: 0, count: components.count)
        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                for c in 0..<components.count {
                    let comp = components[c]
                    for by in 0..<comp.verticalSampling {
                        for bx in 0..<comp.horizontalSampling {
                            let bidx = (mcuY * comp.verticalSampling + by) * blocksPerRow[c]
                                + (mcuX * comp.horizontalSampling + bx)
                            let dc = quant[c][bidx * 64]
                            let diff = dc - pred[c]
                            pred[c] = dc
                            let cat = HuffmanEncoder.category(for: diff)
                            if c == 0 { dcLum[cat] += 1 } else { dcChr[cat] += 1 }
                        }
                    }
                }
            }
        }
    }

    private func emitDC(dcLum: HuffmanTable, dcChr: HuffmanTable) -> [UInt8] {
        var w = BitWriter(estimatedMaxSize: mcuCountH * mcuCountV * 8 + 1024)
        var pred = [Int32](repeating: 0, count: components.count)
        for mcuY in 0..<mcuCountV {
            for mcuX in 0..<mcuCountH {
                for c in 0..<components.count {
                    let comp = components[c]
                    let table = c == 0 ? dcLum : dcChr
                    for by in 0..<comp.verticalSampling {
                        for bx in 0..<comp.horizontalSampling {
                            let bidx = (mcuY * comp.verticalSampling + by) * blocksPerRow[c]
                                + (mcuX * comp.horizontalSampling + bx)
                            let dc = quant[c][bidx * 64]
                            let diff = dc - pred[c]
                            pred[c] = dc
                            HuffmanEncoder.encodeDC(diff, table: table, writer: &w)
                        }
                    }
                }
            }
        }
        w.flush()
        return w.data
    }

    // MARK: - AC scan (non-interleaved, single component, band 1–63)

    /// Walks a component's AC band, invoking `onSymbol` for each Huffman symbol
    /// (run/size byte) with its coefficient value (0 for EOBn/ZRL), and tracking
    /// EOBRUN. Shared by the count and emit passes.
    private func walkAC(
        component c: Int,
        onNonzero: (_ symbol: Int, _ coef: Int32) -> Void,
        onEOBRun: (_ eobrun: Int) -> Void
    ) {
        let stride = blocksPerRow[c]
        let zz = Quantization.zigzagOrder
        var eobrun = 0
        for blockY in 0..<realBlocksH[c] {
            for blockX in 0..<realBlocksW[c] {
                let base = (blockY * stride + blockX) * 64
                var run = 0
                for k in 1...63 {
                    let coef = quant[c][base + zz[k]]
                    if coef == 0 { run += 1; continue }
                    // A nonzero ends any pending EOB run.
                    if eobrun > 0 { onEOBRun(eobrun); eobrun = 0 }
                    while run > 15 { onNonzero(0xF0, 0); run -= 16 }  // ZRL
                    let size = HuffmanEncoder.category(for: coef)
                    onNonzero((run << 4) | size, coef)
                    run = 0
                }
                if run > 0 {  // block ends with zeros → contributes to EOB run
                    eobrun += 1
                    if eobrun == 0x7FFF { onEOBRun(eobrun); eobrun = 0 }
                }
            }
        }
        if eobrun > 0 { onEOBRun(eobrun) }
    }

    /// EOBn symbol for a run: size field 0, run field = floor(log2(eobrun)).
    private func eobnSymbol(_ eobrun: Int) -> Int {
        var nbits = 0
        var t = eobrun >> 1
        while t != 0 { nbits += 1; t >>= 1 }
        return nbits << 4
    }

    private func countAC(component c: Int, freq: inout [Int]) {
        var f = freq
        walkAC(component: c,
               onNonzero: { symbol, _ in f[symbol] += 1 },
               onEOBRun: { eobrun in f[self.eobnSymbol(eobrun)] += 1 })
        freq = f
    }

    private func emitAC(component c: Int, table: HuffmanTable) -> [UInt8] {
        var w = BitWriter(estimatedMaxSize: realBlocksW[c] * realBlocksH[c] * 16 + 1024)
        walkAC(component: c,
               onNonzero: { symbol, coef in
                   let entry = table.encodingTable[symbol]
                   w.writeBits(UInt32(entry.code), count: Int(entry.length))
                   let size = symbol & 0x0F
                   if size > 0 {
                       w.writeBits(HuffmanEncoder.additionalBits(for: coef, category: size), count: size)
                   }
               },
               onEOBRun: { eobrun in
                   let symbol = self.eobnSymbol(eobrun)
                   let entry = table.encodingTable[symbol]
                   w.writeBits(UInt32(entry.code), count: Int(entry.length))
                   let nbits = symbol >> 4
                   if nbits > 0 {
                       w.writeBits(UInt32(eobrun & ((1 << nbits) - 1)), count: nbits)
                   }
               })
        w.flush()
        return w.data
    }
}
