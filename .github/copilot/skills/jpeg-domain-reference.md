# Skill: JPEG Domain Reference

You are working on JPEG codec implementation. This reference covers the key domain concepts needed for JLISwift development.

## JPEG Compression Pipeline (Encoder)

```
Input Pixels
    │
    ▼
[1] Color Space Conversion (RGB → YCbCr or RGB → XYB)
    │
    ▼
[2] Chroma Subsampling (4:4:4, 4:2:2, 4:2:0)
    │
    ▼
[3] Block Splitting (divide into 8×8 MCU blocks)
    │
    ▼
[4] Level Shift (subtract 128 for 8-bit; center around zero)
    │
    ▼
[5] Forward DCT (spatial → frequency domain)
    │
    ▼
[6] Quantization (divide by quantization table, round to integer)
    │  ├── Standard: fixed quantization tables
    │  └── jpegli: adaptive dead-zone quantization
    │
    ▼
[7] Entropy Coding (Huffman or arithmetic coding)
    │  ├── DC coefficients: DPCM (difference from previous block)
    │  └── AC coefficients: zig-zag scan order, run-length coding
    │
    ▼
[8] Bitstream Assembly (SOI, markers, scan data, EOI)
    │
    ▼
JPEG File
```

## JPEG Decompression Pipeline (Decoder)

```
JPEG File
    │
    ▼
[1] Marker Parsing (SOI, SOF, SOS, DHT, DQT, APP, EOI)
    │
    ▼
[2] Entropy Decoding (Huffman or arithmetic)
    │
    ▼
[3] Dequantization (multiply by quantization table)
    │  └── jpegli: smooth dequantization (Laplacian expectation)
    │
    ▼
[4] Inverse DCT (frequency → spatial domain)
    │
    ▼
[5] Level Shift (add 128 for 8-bit)
    │
    ▼
[6] Chroma Upsampling (interpolate chrominance to full resolution)
    │
    ▼
[7] Color Space Conversion (YCbCr → RGB or XYB → RGB)
    │
    ▼
Output Pixels
```

## Key JPEG Markers

| Marker | Hex | Name | Description |
|--------|-----|------|-------------|
| SOI | `FF D8` | Start of Image | First two bytes of every JPEG |
| SOF0 | `FF C0` | Start of Frame (Baseline) | Image dimensions, components, precision |
| SOF2 | `FF C2` | Start of Frame (Progressive) | Progressive mode image parameters |
| DHT | `FF C4` | Define Huffman Table | Huffman coding tables |
| DQT | `FF DB` | Define Quantization Table | Quantization matrices |
| DRI | `FF DD` | Define Restart Interval | Restart marker interval |
| SOS | `FF DA` | Start of Scan | Scan header + compressed data follows |
| APP0 | `FF E0` | Application Segment 0 | JFIF header |
| APP1 | `FF E1` | Application Segment 1 | Exif metadata |
| APP2 | `FF E2` | Application Segment 2 | ICC color profile |
| COM | `FF FE` | Comment | Text comment |
| EOI | `FF D9` | End of Image | Last two bytes of JPEG |

## SOF Marker Structure (Image Metadata)

```
FF C0 (or FF C2 for progressive)
  Length (2 bytes)
  Precision (1 byte) — bits per component (8, 12, or 16)
  Height (2 bytes)
  Width (2 bytes)
  Component count (1 byte)
  For each component:
    Component ID (1 byte)
    Sampling factors (1 byte) — H:V in upper:lower nibble
    Quantization table selector (1 byte)
```

## DCT (Discrete Cosine Transform)

### Forward DCT (Type II)

$$F(u,v) = \frac{1}{4} C(u) C(v) \sum_{x=0}^{7} \sum_{y=0}^{7} f(x,y) \cos\left[\frac{(2x+1)u\pi}{16}\right] \cos\left[\frac{(2y+1)v\pi}{16}\right]$$

where $C(k) = \frac{1}{\sqrt{2}}$ for $k=0$, and $C(k) = 1$ otherwise.

### Inverse DCT (Type III)

$$f(x,y) = \frac{1}{4} \sum_{u=0}^{7} \sum_{v=0}^{7} C(u) C(v) F(u,v) \cos\left[\frac{(2x+1)u\pi}{16}\right] \cos\left[\frac{(2y+1)v\pi}{16}\right]$$

### Zig-zag Scan Order

```
 0  1  5  6 14 15 27 28
 2  4  7 13 16 26 29 42
 3  8 12 17 25 30 41 43
 9 11 18 24 31 40 44 53
10 19 23 32 39 45 52 54
20 22 33 38 46 51 55 60
21 34 37 47 50 56 59 61
35 36 48 49 57 58 62 63
```

## Quantization

### Standard JPEG Luminance Table (Quality 50)

```
16  11  10  16  24  40  51  61
12  12  14  19  26  58  60  55
14  13  16  24  40  57  69  56
14  17  22  29  51  87  80  62
18  22  37  56  68 109 103  77
24  35  55  64  81 104 113  92
49  64  78  87 103 121 120 101
72  92  95  98 112 100 103  99
```

Quality scaling: For quality Q, multiply table by `(100 - Q) / 50` when Q > 50, or `50 / Q` when Q ≤ 50.

## jpegli Innovations

### Adaptive Dead-Zone Quantization

Standard JPEG uses a fixed rounding threshold of 0.5 for quantization. jpegli adjusts the threshold ("dead zone") per-block based on local image statistics:

- **Smooth regions:** Smaller dead zone → more coefficients survive → better quality
- **Textured/noisy regions:** Larger dead zone → more aggressive compression → less visible artifacts
- The adaptation map is computed from local variance of DCT coefficients

### Floating-Point Pipeline

Standard JPEG typically uses integer arithmetic throughout. jpegli keeps all intermediate values in floating point:

1. Color conversion: floating-point matrix multiply
2. Chroma subsampling: floating-point filtering
3. DCT: floating-point transform
4. Only at the final quantization step are values rounded to integers

This eliminates accumulated rounding errors and improves quality at the same file size.

### Distance Parameter

jpegli uses a "distance" parameter (borrowed from JPEG XL):
- Distance 0.0 = mathematically lossless
- Distance 1.0 = visually lossless
- Higher values = more compression, more artifacts

The mapping from quality to distance: `distance = jpegli_quality_to_distance(quality)`

## Color Spaces

### YCbCr (BT.601)

```
Y  =  0.299   * R + 0.587   * G + 0.114   * B
Cb = -0.168736 * R - 0.331264 * G + 0.5     * B + 128
Cr =  0.5      * R - 0.418688 * G - 0.081312 * B + 128
```

### XYB (JPEG XL Perceptual)

XYB separates intensity from color more effectively than YCbCr for human perception. The transform involves:
1. Linear RGB → LMS (long/medium/short cone response)
2. Cube root transfer function (approximating human perception)
3. LMS → XYB rotation

For JPEG compatibility, XYB JPEGs embed an ICC profile so standard decoders can display them (with slightly degraded quality), while jpegli-aware decoders apply the correct inverse transform.

## Chroma Subsampling

| Mode | H:V Factors | Description |
|------|------------|-------------|
| 4:4:4 | 1:1 | No subsampling — full resolution chrominance |
| 4:2:2 | 2:1 | Horizontal subsampling — half horizontal chroma resolution |
| 4:2:0 | 2:2 | Both — quarter chroma resolution (most common) |
| 4:0:0 | N/A | Grayscale — no chrominance channels |

## MCU (Minimum Coded Unit)

The MCU size depends on subsampling:
- 4:4:4 → 8×8 pixels (one block per component)
- 4:2:2 → 16×8 pixels (two Y blocks, one Cb, one Cr)
- 4:2:0 → 16×16 pixels (four Y blocks, one Cb, one Cr)

## Progressive JPEG Scans

Progressive encoding sends coefficients in multiple passes:
1. **DC scan:** Only DC coefficients (low-frequency average of each block)
2. **AC scan 1:** Low-frequency AC coefficients
3. **AC scan 2+:** Higher-frequency AC coefficients
4. **Refinement scans:** Additional bits of precision for previously sent coefficients

This allows a preview to appear quickly while the full image loads.
