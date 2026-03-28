// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// The jpegli-compatible JPEG encoder.
///
/// `JLIEncoder` compresses image data into JPEG format using the jpegli algorithm,
/// providing up to 35% better compression ratios compared to traditional JPEG encoders
/// while maintaining full backward compatibility.
///
/// ## Current Status
///
/// This is the Milestone 1 (Foundation) implementation. Encoding is not yet functional
/// and will return ``JLIError/notImplemented(_:)`` until the codec pipeline is built
/// in subsequent milestones.
///
/// ## Usage
///
/// ```swift
/// let encoder = JLIEncoder()
/// let jpegData = try encoder.encode(image, configuration: .default)
/// ```
public struct JLIEncoder: Sendable {
    /// Creates a new encoder instance.
    public init() {}

    /// Encodes an image to JPEG data using the jpegli algorithm.
    ///
    /// - Parameters:
    ///   - image: The source image to encode.
    ///   - configuration: Encoder settings controlling quality, color space, and features.
    /// - Returns: The encoded JPEG data.
    /// - Throws: ``JLIError`` if encoding fails or the feature is not yet implemented.
    public func encode(
        _ image: JLIImage,
        configuration: JLIEncoderConfiguration = .default
    ) throws -> [UInt8] {
        try validateConfiguration(configuration)
        throw JLIError.notImplemented(
            "JPEG encoding — available from Milestone 2 (Baseline Codec via libjpeg-turbo)"
        )
    }

    /// Validates the encoder configuration, throwing on invalid parameters.
    private func validateConfiguration(_ configuration: JLIEncoderConfiguration) throws {
        guard configuration.quality >= 0.0, configuration.quality <= 100.0 else {
            throw JLIError.invalidQuality(configuration.quality)
        }
        if let distance = configuration.distance {
            guard distance >= 0.0 else {
                throw JLIError.invalidDistance(distance)
            }
        }
    }
}
