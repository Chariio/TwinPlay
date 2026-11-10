// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Game info for both library styles. The picture, type and stats follow the
// selected menu theme. Layout flips between a row and a stack from the width
// it is offered — no orientation or window code.
import SwiftUI

struct GameInfoCard: View {
    let entry: ROMLibrary.Entry
    var compact = false
    @EnvironmentObject private var library: ROMLibrary
    @ObservedObject private var featured = FeaturedBackdropStore.shared

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        details
            .padding(compact ? 12 : 16)
            .frame(maxWidth: .infinity, minHeight: compact ? 108 : 132, alignment: .leading)
            .background { cardBackdrop }
            .clipShape(cardShape)
            .overlay(cardShape.strokeBorder(ClassicPalette.accent.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
            .onAppear { featured.prefetch(for: entry, library: library) }
            .onChange(of: entry.id) { _ in featured.prefetch(for: entry, library: library) }
            .onChange(of: featured.localGeneration) { _ in featured.prefetch(for: entry, library: library) }
    }

    /// Box art stays inside the card. The frame is the card's, never the picture's own size.
    private var cardBackdrop: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                ClassicPalette.screen
                if let img = featured.current(for: entry, library: library)
                    ?? entry.cover ?? entry.titleScreen ?? entry.icon {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .allowsHitTesting(false)
                    LinearGradient(
                        colors: [Color.black.opacity(0.28), Color.black.opacity(0.42), Color.black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(cardShape)
            .allowsHitTesting(false)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.name)
                .font(.system(compact ? .headline : .title2, design: .rounded).weight(.bold))
                .foregroundStyle(ClassicPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(ClassicGameCard.subtitle(entry))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(ClassicPalette.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Rectangle().fill(ClassicPalette.line).frame(height: 1).padding(.vertical, 2)
            HStack(alignment: .top, spacing: 0) {
                stat(ClassicGameCard.duration(entry.playSeconds), "TIME")
                stat("\(entry.playCount)", "PLAYS")
                stat(ClassicGameCard.lastPlayed(entry.lastPlayed), "LAST PLAYED")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(compact ? .subheadline : .title3, design: .rounded).weight(.semibold))
                .foregroundStyle(ClassicPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.loc)
                .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(ClassicPalette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GameInfoSheet: View {
    let entry: ROMLibrary.Entry
    @EnvironmentObject private var library: ROMLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var profileID = ""

    private var live: ROMLibrary.Entry { library.entries.first { $0.id == entry.id } ?? entry }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GameInfoCard(entry: live)
                    if !profileID.isEmpty {
                        RecommendedSettingsRow(profileID: profileID)
                    }
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(ClassicPalette.body.ignoresSafeArea())
            .navigationTitle("Game Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            profileID = GameProfiles.identify(url: live.url, system: live.system, gameCode: live.gameCode ?? "").primary
        }
    }
}

/// Per-game "Use recommended settings". On when the key has never been set.
struct RecommendedSettingsRow: View {
    let profileID: String
    @State private var on = true

    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use recommended settings").font(.system(.body, design: .rounded).weight(.semibold))
                Text("On for each game until you change it. Your own graphics choices are kept when this is off.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(ClassicPalette.accent)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ClassicPalette.panel))
        .onAppear { on = GameProfiles.isEnabled(profileID) }
        .onChange(of: on) { value in GameProfiles.setEnabled(profileID, value) }
    }
}

#if DEBUG
struct GameInfoCard_Previews: PreviewProvider {
    static var sample: ROMLibrary.Entry {
        var e = ROMLibrary.Entry(url: URL(fileURLWithPath: "/tmp/Sample Rally.nds"), name: "Sample Rally", dateAdded: .now)
        e.playCount = 12
        e.playSeconds = 5400
        e.lastPlayed = .now
        e.gameCode = "AMCE"
        e.system = .ds
        return e
    }
    static var previews: some View {
        Group {
            GameInfoCard(entry: sample).padding().frame(width: 320, height: 420)
                .environmentObject(ROMLibrary())
                .previewDisplayName("Small iPhone")
            GameInfoCard(entry: sample).padding().frame(width: 430, height: 280)
                .previewDisplayName("Large iPhone landscape")
            GameInfoCard(entry: sample).padding().frame(width: 820, height: 420)
                .previewDisplayName("iPad")
            GameInfoCard(entry: sample, compact: true).padding().frame(width: 700, height: 160)
                .previewDisplayName("Short landscape")
        }
        .environmentObject(ROMLibrary())
        .background(ClassicPalette.body)
    }
}
#endif
