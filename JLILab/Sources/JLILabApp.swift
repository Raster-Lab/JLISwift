// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import SwiftUI

/// JLISwift Medical Image Lab — an encode→decode round-trip workbench for
/// evaluating the JLISwift JPEG codec on DICOM and standard images.
@main
struct JLILabApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("JLISwift Medical Image Lab") {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
