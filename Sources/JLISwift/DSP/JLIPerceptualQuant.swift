// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// jpegli's perceptual quantization-table model, ported from libjxl v0.11.2
/// `lib/jpegli/quant.cc` (Apache-2.0). Rather than scaling the ITU-T Annex K
/// tables by an IJG quality factor, jpegli derives each quantization step from
/// perceptually-tuned base matrices and a per-coefficient *non-linear* function
/// of the Butteraugli `distance`. Selected by
/// ``JLIEncoderConfiguration/perceptualQuantTables``; the Annex K path
/// (``Quantization/scaleTable(_:quality:)``) remains the default.
///
/// Only the YCbCr (non-XYB, baseline) model is ported: the default single chroma
/// table uses jpegli's Cr base matrix for both Cb and Cr, and 4:2:0 applies the
/// extra global (1.22) and per-coefficient chroma rescales jpegli uses.
extension Quantization {
    /// `kGlobalScaleYCbCr` — overall YCbCr scale.
    static let jpegliGlobalScaleYCbCr = 1.73966010
    /// `k420GlobalScale` — extra global scale applied for 4:2:0.
    static let jpegliGlobalScale420 = 1.22
    /// `kDist0` — distance below which scaling is linear (`scale == distance`).
    static let jpegliDist0 = 1.5

    static let jpegliBaseY: [Double] = [
        1.239740935, 1.72271151, 2.921216716, 2.812737435, 3.339819712, 3.463603763, 3.840915218, 3.86956,
        1.72271151, 2.092889441, 2.84567609, 2.704506821, 3.440767352, 3.166232352, 4.025208742, 4.035324491,
        2.921216716, 2.84567609, 2.958740352, 3.386294897, 3.619523781, 3.904628, 3.757835838, 4.237447516,
        2.812737435, 2.704506821, 3.386294897, 3.380058822, 4.167986742, 4.805510627, 4.784259, 4.605934,
        3.339819712, 3.440767352, 3.619523781, 4.167986742, 4.579851258, 4.923237, 5.574107, 5.485333361,
        3.463603763, 3.166232352, 3.904628, 4.805510627, 4.923237, 5.43936, 5.093895742, 6.087225442,
        3.840915218, 4.025208742, 3.757835838, 4.784259, 5.574107, 5.093895742, 5.438461, 5.403735949,
        3.86956, 4.035324491, 4.237447516, 4.605934, 5.485333361, 6.087225442, 5.403735949, 4.377871012,
    ]

    /// jpegli's Cr base matrix — used for the single chroma table (Cb and Cr).
    static let jpegliBaseChroma: [Double] = [
        2.921725496, 4.497681013, 7.356344521, 6.583891507, 8.53560874, 8.799434353, 9.188341534, 9.482700481,
        4.497681013, 6.309548852, 7.024608963, 7.156445324, 8.049059219, 7.012429066, 6.711923184, 8.380307846,
        7.356344521, 7.024608963, 6.892101177, 6.882819916, 8.78222609, 6.877475, 7.885817597, 8.67909,
        6.583891507, 7.156445324, 6.882819916, 7.003072945, 7.72234647, 7.95542572, 7.473411, 8.362933243,
        8.53560874, 8.049059219, 8.78222609, 7.72234647, 6.778005927, 9.484922742, 9.043702664, 8.0531782,
        8.799434353, 7.012429066, 6.877475, 7.95542572, 9.484922742, 8.607606527, 9.922697394, 64.2513518,
        9.188341534, 6.711923184, 7.885817597, 7.473411, 9.043702664, 9.922697394, 63.18493655, 83.3529434,
        9.482700481, 8.380307846, 8.67909, 8.362933243, 8.0531782, 64.2513518, 83.3529434, 114.8920245,
    ]

    /// `kExponent` — per-coefficient exponent for the non-linear distance scale.
    static let jpegliExponent: [Double] = [
        1, 0.51, 0.67, 0.74, 1, 1, 1, 1,
        0.51, 0.66, 0.69, 0.87, 1, 1, 1, 1,
        0.67, 0.69, 0.84, 0.83, 0.96, 1, 1, 1,
        0.74, 0.87, 0.83, 1, 1, 0.91, 0.91, 1,
        1, 1, 0.96, 1, 1, 1, 1, 1,
        1, 1, 1, 0.91, 1, 1, 1, 1,
        1, 1, 1, 0.91, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1,
    ]

    /// `k420Rescale` — per-coefficient chroma rescale applied only for 4:2:0.
    static let jpegli420Rescale: [Double] = [
        0.4093, 0.3209, 0.3477, 0.3333, 0.3144, 0.2823, 0.3214, 0.3354,
        0.3209, 0.3111, 0.3489, 0.2801, 0.3059, 0.3119, 0.4135, 0.3445,
        0.3477, 0.3489, 0.3586, 0.3257, 0.2727, 0.3754, 0.3369, 0.3484,
        0.3333, 0.2801, 0.3257, 0.302, 0.3515, 0.341, 0.3971, 0.3839,
        0.3144, 0.3059, 0.2727, 0.3515, 0.3105, 0.3397, 0.2716, 0.3836,
        0.2823, 0.3119, 0.3754, 0.341, 0.3397, 0.3212, 0.3203, 0.0726,
        0.3214, 0.4135, 0.3369, 0.3971, 0.2716, 0.3203, 0.0798, 0.0553,
        0.3354, 0.3445, 0.3484, 0.3839, 0.3836, 0.0726, 0.0553, 0.3368,
    ]

    /// `DistanceToScale`: per-coefficient non-linear mapping from Butteraugli
    /// distance to a quantization scale. Linear below ``jpegliDist0``.
    static func jpegliDistanceToScale(_ distance: Double, _ k: Int) -> Double {
        if distance < jpegliDist0 { return distance }
        let e = jpegliExponent[k]
        let mul = pow(jpegliDist0, 1.0 - e)
        return max(0.5 * distance, mul * pow(distance, e))
    }

    /// Builds a natural-order 64-entry quant table for `distance` using jpegli's
    /// perceptual model. `chroma` selects the Cr base matrix; `isYUV420` adds the
    /// 4:2:0 global and per-coefficient chroma rescales. Clamped to 1...255
    /// (baseline 8-bit).
    static func perceptualQuantTable(distance: Double, chroma: Bool, isYUV420: Bool) -> [Int] {
        let base = chroma ? jpegliBaseChroma : jpegliBaseY
        var gscale = jpegliGlobalScaleYCbCr
        if isYUV420 { gscale *= jpegliGlobalScale420 }
        var table = [Int](repeating: 0, count: 64)
        for k in 0..<64 {
            var scale = gscale * jpegliDistanceToScale(distance, k)
            if isYUV420 && chroma { scale *= jpegli420Rescale[k] }
            table[k] = max(1, min(255, Int((scale * base[k]).rounded())))
        }
        return table
    }

    /// Maps an IJG quality (1–100) to a Butteraugli distance — libjxl's
    /// `JpegQualityToDistance`. Used when no explicit distance is configured.
    static func distanceForQuality(_ quality: Double) -> Double {
        let q = max(1.0, min(100.0, quality))
        if q >= 100.0 { return 0.01 }
        if q >= 30.0 { return 0.1 + (100.0 - q) * 0.09 }
        return 53.0 / 3000.0 * q * q - 23.0 / 20.0 * q + 25.0
    }
}
