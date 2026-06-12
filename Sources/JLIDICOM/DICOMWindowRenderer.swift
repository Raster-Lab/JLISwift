// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Accelerate
import Foundation

/// Interactive window/level renderer: snapshots a ``DICOMImage``'s decoded
/// intensities **once** and renders any window from the cache.
///
/// `DICOMImage.render8bit/render12bit` re-decode the full pixel buffer
/// (bitsStored masking, sign extension, Modality LUT) on every call — correct,
/// but wasteful when only the window changes, which is exactly the interactive
/// slider case (every tick re-paid a full decode of a possibly-24-Mpx plane).
/// Construct one renderer per image and call ``render8bit(windowCenter:windowWidth:)``
/// per tick instead; output is pixel-identical to the `DICOMImage` methods
/// (verified by `DICOMWindowRendererTests`).
///
/// The window mapping itself is vectorized with vDSP using only operations
/// that are op-for-op identical to the scalar code (separate multiply and add
/// passes, IEEE division, clip, truncating convert — no fused or re-rounded
/// variants), so vectorization does not change a single output byte.
public struct DICOMWindowRenderer: Sendable {
    public let width: Int
    public let height: Int
    /// Post-rescale intensities (real-world units), cached at init. Empty for
    /// the 8-bit RGB photographic case (which windowing does not apply to).
    public let intensities: [Double]
    /// Pre-rendered RGB for the 8-bit RGB photographic case (window-independent:
    /// de-interleaved + YBR-converted once), `nil` for grayscale.
    private let rgbPassthrough: [UInt8]?
    private let invert: Bool

    public init(_ image: DICOMImage) {
        width = image.width
        height = image.height
        invert = image.photometric == "MONOCHROME1"
        if image.samplesPerPixel == 3 && image.bitsAllocated == 8 {
            // Window-independent: render once with any window, reuse forever.
            // Intensities are still cached so render12bit/intensityRange match
            // DICOMImage's behavior on RGB input exactly (it runs the same
            // intensity decode there, odd as windowing RGB is).
            rgbPassthrough = image.render8bit(windowCenter: 0, windowWidth: 1)
        } else {
            rgbPassthrough = nil
        }
        intensities = image.decodeIntensitiesForRenderer()
    }

    /// Full post-rescale intensity range (the natural slider bounds); matches
    /// `DICOMImage.intensityRange()`.
    public func intensityRange() -> (lo: Double, hi: Double) {
        guard rgbPassthrough == nil, !intensities.isEmpty else { return (0, 255) }
        var lo = 0.0, hi = 0.0
        vDSP_minvD(intensities, 1, &lo, vDSP_Length(intensities.count))
        vDSP_maxvD(intensities, 1, &hi, vDSP_Length(intensities.count))
        if !lo.isFinite || !hi.isFinite { return (0, 255) }
        if lo == hi { return (lo - 1, hi + 1) }
        return (lo, hi)
    }

    /// 8-bit interleaved RGB (gray replicated ×3) for the given window —
    /// pixel-identical to `DICOMImage.render8bit(windowCenter:windowWidth:)`.
    public func render8bit(windowCenter center: Double, windowWidth width: Double) -> [UInt8] {
        if let rgb = rgbPassthrough { return rgb }
        let px = self.width * self.height
        let n = min(px, intensities.count)
        var gray = [UInt8](repeating: 0, count: n)
        Self.windowMap(intensities, count: n, center: center, width: width,
                       invert: invert, peak: 255.0, into: &gray)
        var rgb = [UInt8](unsafeUninitializedCapacity: px * 3) { _, c in c = px * 3 }
        rgb.withUnsafeMutableBufferPointer { rp in
            let d = rp.baseAddress!
            // Pixels beyond the (truncated-buffer) intensity count stay 0,
            // matching DICOMImage.render8bit's zero-filled output.
            if n < px { d.update(repeating: 0, count: px * 3) }
            gray.withUnsafeBufferPointer { gp in
                let g = gp.baseAddress!
                for i in 0..<n {
                    d[i * 3] = g[i]; d[i * 3 + 1] = g[i]; d[i * 3 + 2] = g[i]
                }
            }
        }
        return rgb
    }

    /// 12-bit grayscale (0–4095) for the given window — pixel-identical to
    /// `DICOMImage.render12bit(windowCenter:windowWidth:)`.
    public func render12bit(windowCenter center: Double, windowWidth width: Double) -> [UInt16] {
        let px = self.width * self.height
        let n = min(px, intensities.count)
        var gray16 = [UInt16](repeating: 0, count: px)
        guard n > 0 else { return gray16 }
        var scratch = [Double](unsafeUninitializedCapacity: n) { _, c in c = n }
        Self.windowScale(intensities, count: n, center: center, width: width,
                         invert: invert, peak: 4095.0, into: &scratch)
        gray16.withUnsafeMutableBufferPointer { gp in
            vDSP_vfixu16D(scratch, 1, gp.baseAddress!, 1, vDSP_Length(n))
        }
        return gray16
    }

    /// The window chain shared by both depths, producing `v·peak + 0.5` doubles:
    /// subtract `low`, divide by `span`, clip to [0,1], optionally `1 − v`
    /// (computed as `(−v) + 1`, exact in IEEE), multiply by `peak`, add 0.5 —
    /// every pass element-wise identical to the scalar reference.
    private static func windowScale(
        _ input: [Double], count n: Int, center: Double, width: Double,
        invert: Bool, peak: Double, into out: inout [Double]
    ) {
        var low = -(center - width / 2)
        let span = max(1e-9, width)
        var zero = 0.0, one = 1.0, half = 0.5
        var negOne = -1.0
        var peakV = peak
        let len = vDSP_Length(n)
        input.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                let i = ip.baseAddress!, o = op.baseAddress!
                vDSP_vsaddD(i, 1, &low, o, 1, len)          // v = x − low
                // Explicit element-wise divide, NOT vDSP_vsdivD: vsdivD is not
                // documented correctly-rounded (it may use reciprocal multiply),
                // which would break the pixel-identity contract with the scalar
                // path. The compiler vectorizes this loop to hardware fdiv,
                // which IS IEEE correctly rounded — identical to scalar `/`.
                for j in 0..<n { o[j] = o[j] / span }
                vDSP_vclipD(o, 1, &zero, &one, o, 1, len)   // clamp [0, 1]
                if invert {
                    vDSP_vsmulD(o, 1, &negOne, o, 1, len)   // v = −v
                    vDSP_vsaddD(o, 1, &one, o, 1, len)      //   + 1   (≡ 1 − v exactly)
                }
                vDSP_vsmulD(o, 1, &peakV, o, 1, len)        // v *= peak
                vDSP_vsaddD(o, 1, &half, o, 1, len)         // v += 0.5
            }
        }
    }

    /// `windowScale` + truncating Double→UInt8 convert (`vDSP_vfixu8D` truncates
    /// toward zero, matching Swift's `UInt8(_: Double)` for in-range values).
    private static func windowMap(
        _ input: [Double], count n: Int, center: Double, width: Double,
        invert: Bool, peak: Double, into out: inout [UInt8]
    ) {
        guard n > 0 else { return }
        var scratch = [Double](unsafeUninitializedCapacity: n) { _, c in c = n }
        windowScale(input, count: n, center: center, width: width,
                    invert: invert, peak: peak, into: &scratch)
        out.withUnsafeMutableBufferPointer { op in
            vDSP_vfixu8D(scratch, 1, op.baseAddress!, 1, vDSP_Length(n))
        }
    }
}
