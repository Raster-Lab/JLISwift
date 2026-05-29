// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation
import JLIDICOM

/// A DICOM image loaded and converted to 8-bit RGB so it slots into the
/// existing `Codec` API.
struct CorpusImage {
    /// Stable identifier of the form `modality/study/instance`, e.g.
    /// `ct/study_001/instance_000050`. Used as the row label in bench output
    /// and as the regression-baseline key.
    let id: String
    let modality: String
    let width: Int
    let height: Int
    /// Interleaved RGB, grayscale-replicated for monochrome modalities (8-bit bench).
    let rgb: [UInt8]
    /// 12-bit grayscale samples (0–4095), same window as `rgb` (high-precision bench).
    let gray12: [UInt16]
}

/// Samples and caches a manageable subset of the DICOM corpus.
///
/// The full dataset is ~30k files (~50 GB) and would dwarf the bench. We pick
/// `perModality` files per modality, deterministically (sorted by path so
/// repeated runs hit the same set), convert each to 8-bit interleaved RGB,
/// and cache the result as a tiny binary file in `~/.cache/jlibench/`.
///
/// Cache invalidates implicitly: if you change `perModality` or the source
/// files, the cache key still matches old entries. For now `--rebuild-cache`
/// removes the cache directory.
enum DICOMCorpus {
    /// Modality subdirectories of `medical-dicom-organized`, in display order.
    static let modalities = ["ct", "mr", "dx", "mg", "px", "xa"]

    /// Loads `perModality` images per modality from `rootDir`. Files that
    /// hit unsupported transfer syntaxes (compressed DICOM, etc.) are skipped
    /// and the next candidate is tried. Returns at most `perModality * modalities.count`
    /// images. Cached on disk under `cacheDir` (defaults to `~/.cache/jlibench`).
    static func load(
        rootDir: String,
        perModality: Int = 5,
        cacheDir: String? = nil
    ) -> [CorpusImage] {
        let cache = cacheDir ?? defaultCacheDir()
        try? FileManager.default.createDirectory(
            atPath: cache, withIntermediateDirectories: true
        )

        var out = [CorpusImage]()
        for modality in modalities {
            let modalityDir = "\(rootDir)/\(modality)"
            let candidates = enumerateDICOM(modalityDir).sorted()
            var picked = 0
            for path in candidates {
                if picked >= perModality { break }
                let id = corpusID(path: path, modality: modality)
                if let cached = loadCached(id: id, cacheDir: cache) {
                    out.append(cached)
                    picked += 1
                    continue
                }
                guard let img = tryLoad(path: path, modality: modality, id: id) else {
                    // Unsupported / corrupt — try the next file.
                    continue
                }
                saveCached(img, cacheDir: cache)
                out.append(img)
                picked += 1
            }
        }
        return out
    }

    /// Removes the cache directory, forcing a full rebuild on the next run.
    static func clearCache(cacheDir: String? = nil) {
        let cache = cacheDir ?? defaultCacheDir()
        try? FileManager.default.removeItem(atPath: cache)
    }

    // MARK: - File system

    private static func defaultCacheDir() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.cache/jlibench/corpus"
    }

    /// Enumerates `*.dcm` files under `dir`, recursively, skipping macOS
    /// `.DS_Store` and dotfiles.
    private static func enumerateDICOM(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else { return [] }
        var paths = [String]()
        for case let rel as String in enumerator {
            if rel.hasSuffix(".dcm") {
                paths.append("\(dir)/\(rel)")
            }
        }
        return paths
    }

    /// Turns `.../ct/study_001/instance_000123.dcm` into `ct/study_001/instance_000123`.
    private static func corpusID(path: String, modality: String) -> String {
        var s = path
        if let r = s.range(of: "/\(modality)/") {
            s = String(s[r.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if s.hasSuffix(".dcm") { s = String(s.dropLast(4)) }
        return s
    }

    private static func tryLoad(path: String, modality: String, id: String) -> CorpusImage? {
        do {
            let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            let dicom = try DICOMReader.read(data)
            return CorpusImage(
                id: id, modality: modality,
                width: dicom.width, height: dicom.height,
                rgb: dicom.toRGB8(), gray12: dicom.toGray12()
            )
        } catch {
            // Quietly skip — the bench reports counts at the end.
            return nil
        }
    }

    // MARK: - Cache format
    //
    // Trivial little-endian binary:
    //   [4 B width][4 B height][w*h*3 B rgb][w*h*2 B gray12 (LE)]
    // ID and modality are encoded in the file path under cacheDir. Caches from
    // before the gray12 plane was added fail the size check and get re-parsed.

    private static func cachePath(id: String, cacheDir: String) -> String {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return "\(cacheDir)/\(safe).v2"
    }

    private static func saveCached(_ img: CorpusImage, cacheDir: String) {
        var out = [UInt8]()
        out.reserveCapacity(8 + img.rgb.count + img.gray12.count * 2)
        for shift in stride(from: 0, through: 24, by: 8) {
            out.append(UInt8(truncatingIfNeeded: img.width >> shift))
        }
        for shift in stride(from: 0, through: 24, by: 8) {
            out.append(UInt8(truncatingIfNeeded: img.height >> shift))
        }
        out.append(contentsOf: img.rgb)
        for s in img.gray12 { out.append(UInt8(s & 0xFF)); out.append(UInt8(s >> 8)) }
        try? Data(out).write(to: URL(fileURLWithPath: cachePath(id: img.id, cacheDir: cacheDir)))
    }

    private static func loadCached(id: String, cacheDir: String) -> CorpusImage? {
        let path = cachePath(id: id, cacheDir: cacheDir)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        var w = 0, h = 0
        for i in 0..<4 { w |= Int(bytes[i]) << (i * 8) }
        for i in 0..<4 { h |= Int(bytes[4 + i]) << (i * 8) }
        let rgbCount = w * h * 3
        let grayBytes = w * h * 2
        guard bytes.count == 8 + rgbCount + grayBytes else { return nil }
        let rgb = Array(bytes[8..<(8 + rgbCount)])
        var gray = [UInt16](repeating: 0, count: w * h)
        let base = 8 + rgbCount
        for i in 0..<gray.count {
            gray[i] = UInt16(bytes[base + i * 2]) | (UInt16(bytes[base + i * 2 + 1]) << 8)
        }
        let modality = id.split(separator: "/").first.map(String.init) ?? "unknown"
        return CorpusImage(id: id, modality: modality, width: w, height: h, rgb: rgb, gray12: gray)
    }
}
