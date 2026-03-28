// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Metal GPU acceleration pipeline for JPEG processing.
///
/// Provides GPU-accelerated DCT, quantization, and color conversion
/// using Metal compute shaders on supported Apple platforms.
///
/// ## Architecture
///
/// The pipeline compiles Metal Shading Language kernels at runtime from
/// embedded source strings, avoiding the need to bundle `.metallib` files.
/// All operations fall back to CPU when Metal is unavailable.

#if canImport(Metal)
import Metal

/// GPU-accelerated JPEG processing pipeline using Metal compute shaders.
public final class JLIMetalPipeline: @unchecked Sendable {
    /// The Metal device used for GPU operations.
    let device: MTLDevice
    /// Command queue for submitting work to the GPU.
    let commandQueue: MTLCommandQueue
    /// Compiled compute pipeline states, keyed by kernel name.
    private var pipelines: [String: MTLComputePipelineState] = [:]

    /// Creates a new Metal pipeline using the default GPU device.
    ///
    /// - Throws: ``JLIError/notImplemented(_:)`` if Metal is not available.
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw JLIError.notImplemented(
                "Metal GPU not available on this device"
            )
        }
        guard let queue = device.makeCommandQueue() else {
            throw JLIError.encodingFailed("Failed to create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue
        try compileKernels()
    }

    /// Whether a Metal pipeline is available on the current device.
    public static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    // MARK: - GPU Operations

    /// Performs forward DCT on multiple 8×8 blocks using the GPU.
    ///
    /// - Parameter blocks: Array of 64-element Float arrays (8×8 blocks).
    /// - Returns: DCT-transformed blocks.
    public func forwardDCTBatch(_ blocks: [[Float]]) throws -> [[Float]] {
        guard let pipeline = pipelines["forward_dct"] else {
            throw JLIError.encodingFailed("DCT compute pipeline not available")
        }

        let blockCount = blocks.count
        let flatInput = blocks.flatMap { $0 }
        let inputBuffer = device.makeBuffer(
            bytes: flatInput,
            length: flatInput.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
        let outputBuffer = device.makeBuffer(
            length: flatInput.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )

        guard let inBuf = inputBuffer, let outBuf = outputBuffer,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            throw JLIError.encodingFailed("Failed to create Metal command buffer")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuf, offset: 0, index: 0)
        encoder.setBuffer(outBuf, offset: 0, index: 1)

        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(width: blockCount, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let resultPtr = outBuf.contents().bindMemory(to: Float.self, capacity: flatInput.count)
        var results = [[Float]]()
        for i in 0..<blockCount {
            let start = i * 64
            results.append(Array(UnsafeBufferPointer(start: resultPtr + start, count: 64)))
        }
        return results
    }

    // MARK: - Kernel Compilation

    private func compileKernels() throws {
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)

        for name in ["forward_dct", "inverse_dct", "rgb_to_ycbcr", "ycbcr_to_rgb"] {
            if let function = library.makeFunction(name: name) {
                pipelines[name] = try device.makeComputePipelineState(function: function)
            }
        }
    }

    // MARK: - Metal Shader Source

    /// Embedded Metal Shading Language source for JPEG compute kernels.
    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Precomputed DCT cosine basis
    constant float dct_matrix[64] = {
        0.353553, 0.353553, 0.353553, 0.353553, 0.353553, 0.353553, 0.353553, 0.353553,
        0.490393, 0.415735, 0.277785, 0.097545,-0.097545,-0.277785,-0.415735,-0.490393,
        0.461940, 0.191342,-0.191342,-0.461940,-0.461940,-0.191342, 0.191342, 0.461940,
        0.415735,-0.097545,-0.490393,-0.277785, 0.277785, 0.490393, 0.097545,-0.415735,
        0.353553,-0.353553,-0.353553, 0.353553, 0.353553,-0.353553,-0.353553, 0.353553,
        0.277785,-0.490393, 0.097545, 0.415735,-0.415735,-0.097545, 0.490393,-0.277785,
        0.191342,-0.461940, 0.461940,-0.191342,-0.191342, 0.461940,-0.461940, 0.191342,
        0.097545,-0.277785, 0.415735,-0.490393, 0.490393,-0.415735, 0.277785,-0.097545
    };

    kernel void forward_dct(
        device const float* input [[buffer(0)]],
        device float* output [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tid [[thread_position_in_threadgroup]]
    ) {
        uint blockIdx = gid.x / 8;
        uint u = tid.y;
        uint v = tid.x;
        uint baseOffset = blockIdx * 64;

        float sum = 0.0;
        for (uint x = 0; x < 8; x++) {
            for (uint y = 0; y < 8; y++) {
                sum += dct_matrix[u * 8 + x] * input[baseOffset + x * 8 + y] * dct_matrix[v * 8 + y];
            }
        }
        output[baseOffset + u * 8 + v] = sum;
    }

    kernel void inverse_dct(
        device const float* input [[buffer(0)]],
        device float* output [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tid [[thread_position_in_threadgroup]]
    ) {
        uint blockIdx = gid.x / 8;
        uint x = tid.y;
        uint y = tid.x;
        uint baseOffset = blockIdx * 64;

        float sum = 0.0;
        for (uint u = 0; u < 8; u++) {
            for (uint v = 0; v < 8; v++) {
                sum += dct_matrix[u * 8 + x] * input[baseOffset + u * 8 + v] * dct_matrix[v * 8 + y];
            }
        }
        output[baseOffset + x * 8 + y] = sum;
    }

    kernel void rgb_to_ycbcr(
        device const float* rgb [[buffer(0)]],
        device float* ycbcr [[buffer(1)]],
        uint gid [[thread_position_in_grid]]
    ) {
        uint idx = gid * 3;
        float r = rgb[idx];
        float g = rgb[idx + 1];
        float b = rgb[idx + 2];

        ycbcr[idx]     =  0.299 * r + 0.587 * g + 0.114 * b;
        ycbcr[idx + 1] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0;
        ycbcr[idx + 2] =  0.5 * r - 0.418688 * g - 0.081312 * b + 128.0;
    }

    kernel void ycbcr_to_rgb(
        device const float* ycbcr [[buffer(0)]],
        device float* rgb [[buffer(1)]],
        uint gid [[thread_position_in_grid]]
    ) {
        uint idx = gid * 3;
        float y  = ycbcr[idx];
        float cb = ycbcr[idx + 1] - 128.0;
        float cr = ycbcr[idx + 2] - 128.0;

        rgb[idx]     = clamp(y + 1.402 * cr, 0.0, 255.0);
        rgb[idx + 1] = clamp(y - 0.344136 * cb - 0.714136 * cr, 0.0, 255.0);
        rgb[idx + 2] = clamp(y + 1.772 * cb, 0.0, 255.0);
    }
    """
}
#endif
