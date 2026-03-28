# Skill: Add New Public API

You are adding a new public API type, method, or enum to JLISwift. Follow these rules precisely.

## Checklist for Every Public Symbol

- [ ] **`JLI` prefix:** All public types start with `JLI` (e.g., `JLIProgressiveOptions`)
- [ ] **`Sendable`:** All public types must conform to `Sendable`
- [ ] **Doc comment:** Every public symbol has a `///` doc comment with DocC markup
- [ ] **License header:** File starts with `// SPDX-License-Identifier: Apache-2.0` and `// Copyright 2024 Raster Lab. All rights reserved.`
- [ ] **Error handling:** Invalid inputs throw a `JLIError` case — never `fatalError` or `preconditionFailure`
- [ ] **Not-implemented stub:** If the feature isn't functional yet, throw `JLIError.notImplemented("description — available from Milestone N")`
- [ ] **Test coverage:** Minimum 80% unit test coverage; at least one unit test per public method/initializer
- [ ] **Correct directory:** Place the file in the appropriate subdirectory (`Core/`, `Encoder/`, `Decoder/`, `Platform/`)

## Template: New Public Struct

```swift
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Brief one-line description.
///
/// Detailed description explaining purpose and context.
///
/// ## Usage
///
/// ```swift
/// let thing = JLIThing(parameter: value)
/// ```
///
/// - Note: Available from Milestone N.
public struct JLIThing: Sendable {
    /// Description of property.
    public let property: Type
    
    /// Creates a new instance.
    ///
    /// - Parameter property: Description.
    /// - Throws: ``JLIError/invalidX`` if validation fails.
    public init(property: Type) throws {
        guard isValid(property) else {
            throw JLIError.someCase
        }
        self.property = property
    }
}
```

## Template: New Public Enum

```swift
// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Brief description of what this enum represents.
public enum JLIConcept: Sendable {
    /// Description of case.
    case option1
    
    /// Description of case.
    case option2
    
    /// Computed property if needed.
    public var someProperty: Type {
        switch self {
        case .option1: return value1
        case .option2: return value2
        }
    }
}
```

## Template: New Method on Existing Type

```swift
extension JLIEncoder {
    /// Brief description of what this method does.
    ///
    /// Detailed explanation of behavior, edge cases, and relationship
    /// to other methods.
    ///
    /// - Parameters:
    ///   - param1: Description.
    ///   - param2: Description.
    /// - Returns: Description of return value.
    /// - Throws: ``JLIError/caseName`` when condition occurs.
    public func newMethod(param1: Type1, param2: Type2) throws -> ReturnType {
        // Validate inputs
        guard isValid(param1) else {
            throw JLIError.invalidCase
        }
        // Implementation...
    }
}
```

## Template: Configuration Struct

```swift
/// Configuration for JLI feature.
///
/// Use ``JLIFeatureConfiguration/default`` for sensible defaults.
public struct JLIFeatureConfiguration: Sendable {
    /// Description of setting.
    public var setting1: Type1
    
    /// Description of setting.
    public var setting2: Type2
    
    /// A sensible default configuration.
    public static let `default` = JLIFeatureConfiguration(
        setting1: defaultValue1,
        setting2: defaultValue2
    )
    
    /// Creates a feature configuration.
    ///
    /// - Parameters:
    ///   - setting1: Description. Default is `defaultValue1`.
    ///   - setting2: Description. Default is `defaultValue2`.
    public init(
        setting1: Type1 = defaultValue1,
        setting2: Type2 = defaultValue2
    ) {
        self.setting1 = setting1
        self.setting2 = setting2
    }
}
```

## Naming Conventions

| Kind | Pattern | Example |
|------|---------|---------|
| Data container | `JLI<Thing>` | `JLIImage`, `JLIJPEGInfo` |
| Configuration | `JLI<Thing>Configuration` | `JLIEncoderConfiguration` |
| Enum (concept) | `JLI<Concept>` | `JLIPixelFormat`, `JLIChromaSubsampling` |
| Processor | `JLI<Action>er` | `JLIEncoder`, `JLIDecoder` |
| Error | `JLIError` (single enum) | `JLIError.invalidQuality` |
| Capabilities | `JLIPlatformCapabilities` | (singleton) |

## Domain Abbreviations Allowed

These abbreviations are standard in the JPEG domain and may be used without expansion:

`DCT`, `IDCT`, `MCU`, `RGB`, `YCbCr`, `XYB`, `ICC`, `JPEG`, `SOF`, `SOS`, `DHT`, `DQT`, `DRI`, `EOI`, `APP`, `SSIM`, `PSNR`, `CMYK`, `SIMD`, `GPU`, `CPU`

All other terms should be spelled out in full.

## Adding to Error Enum

When a new error case is needed:

1. Add the case to `JLIError` in `Core/JLIError.swift`
2. Add its `description` in the `CustomStringConvertible` extension
3. Add a test that triggers the error
4. Never remove existing error cases (backward compatibility)
