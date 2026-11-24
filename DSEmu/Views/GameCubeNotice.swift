// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

/// Short note at the top of the GameCube library section on iPhone and iPad.
struct GameCubeNoticeBanner: View {
    var body: some View {
        if GameCubeDisc.showsOnThisPlatform {
            Text(LocalizedStringKey(stringLiteral: GameCubeDisc.englishNotice))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("gamecube-notice")
        }
    }
}
