// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// Color space conversion utilities for JPEG encoding and decoding.
///
/// Uses floating-point precision throughout the pipeline, converting to integers
/// only at the final stage — matching the jpegli approach.
enum ColorConversion {

    // MARK: - RGB ↔ YCbCr (BT.601)

    /// Converts an RGB pixel to YCbCr.
    ///
    /// Uses BT.601 coefficients as specified by JFIF/JPEG:
    /// ```
    /// Y  =  0.299 * R + 0.587 * G + 0.114 * B
    /// Cb = -0.168736 * R - 0.331264 * G + 0.5 * B + 128
    /// Cr =  0.5 * R - 0.418688 * G - 0.081312 * B + 128
    /// ```
    @inlinable
    static func rgbToYCbCr(r: Float, g: Float, b: Float) -> (y: Float, cb: Float, cr: Float) {
        let y  =  0.299 * r + 0.587 * g + 0.114 * b
        let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0
        let cr =  0.5 * r - 0.418688 * g - 0.081312 * b + 128.0
        return (y, cb, cr)
    }

    /// Converts a YCbCr pixel to RGB.
    @inlinable
    static func ycbcrToRGB(y: Float, cb: Float, cr: Float) -> (r: Float, g: Float, b: Float) {
        let cbShifted = cb - 128.0
        let crShifted = cr - 128.0
        let r = y + 1.402 * crShifted
        let g = y - 0.344136 * cbShifted - 0.714136 * crShifted
        let b = y + 1.772 * cbShifted
        return (r, g, b)
    }

    /// Converts an entire image from RGB to YCbCr component planes.
    ///
    /// Returns three separate planes (Y, Cb, Cr), each of size `width × height`.
    static func imageRGBToYCbCr(data: [UInt8], width: Int, height: Int,
                                 componentCount: Int) -> (y: [Float], cb: [Float], cr: [Float]) {
        let pixelCount = width * height
        var yPlane = [Float](repeating: 0, count: pixelCount)
        var cbPlane = [Float](repeating: 0, count: pixelCount)
        var crPlane = [Float](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            let r = Float(data[i * componentCount])
            let g = Float(data[i * componentCount + 1])
            let b = Float(data[i * componentCount + 2])
            let (y, cb, cr) = rgbToYCbCr(r: r, g: g, b: b)
            yPlane[i] = y
            cbPlane[i] = cb
            crPlane[i] = cr
        }
        return (yPlane, cbPlane, crPlane)
    }

    /// Converts YCbCr component planes back to interleaved RGB bytes.
    static func imageYCbCrToRGB(y: [Float], cb: [Float], cr: [Float],
                                 width: Int, height: Int) -> [UInt8] {
        let pixelCount = width * height
        var result = [UInt8](repeating: 0, count: pixelCount * 3)

        for i in 0..<pixelCount {
            let (r, g, b) = ycbcrToRGB(y: y[i], cb: cb[i], cr: cr[i])
            result[i * 3]     = UInt8(clamping: Int(r.rounded()))
            result[i * 3 + 1] = UInt8(clamping: Int(g.rounded()))
            result[i * 3 + 2] = UInt8(clamping: Int(b.rounded()))
        }
        return result
    }

    /// Converts a grayscale image buffer to a luminance plane.
    static func imageGrayscaleToY(data: [UInt8], width: Int, height: Int) -> [Float] {
        return data.map { Float($0) }
    }

    /// Converts a luminance plane back to grayscale bytes.
    static func imageYToGrayscale(y: [Float], width: Int, height: Int) -> [UInt8] {
        return y.map { UInt8(clamping: Int($0.rounded())) }
    }

    // MARK: - RGB ↔ XYB (JPEG XL Perceptual Color Space)

    /// Converts an RGB pixel (linear, 0–255) to XYB.
    ///
    /// The XYB transform follows the JPEG XL specification:
    /// 1. Linear RGB → LMS (cone response)
    /// 2. Cube root transfer function
    /// 3. LMS → XYB rotation
    static func rgbToXYB(r: Float, g: Float, b: Float) -> (x: Float, y: Float, bOut: Float) {
        // Linear RGB to LMS
        let rLin = r / 255.0
        let gLin = g / 255.0
        let bLin = b / 255.0

        let l = 0.3 * rLin + 0.622 * gLin + 0.078 * bLin
        let m = 0.23 * rLin + 0.692 * gLin + 0.078 * bLin
        let s = 0.24342268 * rLin + 0.20476744 * gLin + 0.55180988 * bLin

        // Perceptual transfer function (cube root)
        let lPrime = cbrt(max(0, l))
        let mPrime = cbrt(max(0, m))
        let sPrime = cbrt(max(0, s))

        // LMS to XYB
        let x = (lPrime - mPrime) * 0.5
        let yOut = (lPrime + mPrime) * 0.5
        let bChannel = sPrime

        return (x, yOut, bChannel)
    }

    /// Converts an XYB pixel back to RGB (0–255).
    static func xybToRGB(x: Float, y: Float, bChannel: Float) -> (r: Float, g: Float, b: Float) {
        // XYB to LMS
        let lPrime = y + x
        let mPrime = y - x
        let sPrime = bChannel

        // Inverse transfer (cube)
        let l = lPrime * lPrime * lPrime
        let m = mPrime * mPrime * mPrime
        let s = sPrime * sPrime * sPrime

        // LMS to linear RGB (inverse of the forward matrix)
        // Using the pseudo-inverse for the 3×3 matrix
        let rLin =  5.3386859 * l - 4.2586608 * m - 0.0800251 * s
        let gLin = -1.1252742 * l + 2.2135497 * m - 0.0882755 * s
        let bLin =  0.0452064 * l - 0.2640891 * m + 1.2188827 * s

        return (
            max(0, min(255, rLin * 255.0)),
            max(0, min(255, gLin * 255.0)),
            max(0, min(255, bLin * 255.0))
        )
    }
}
