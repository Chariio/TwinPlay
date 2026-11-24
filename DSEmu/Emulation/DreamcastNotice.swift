// Copyright (c) 2026 Charlie Rodriguez Garcia.
// Shown in the Dreamcast library section on iPhone and iPad.
import SwiftUI

enum DreamcastNotice {
    /// English source. Spanish lives in Localizable.xcstrings under this key.
    static let devices = "Designed for modern iPhone and iPad (iPhone 15 Pro or newer, or an iPad with an M-series chip). Older devices may run slowly."

    static var showOnThisDevice: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    static var text: String { devices.loc }
}

struct DreamcastDevicesNote: View {
    var body: some View {
        if DreamcastNotice.showOnThisDevice {
            Text(DreamcastNotice.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
