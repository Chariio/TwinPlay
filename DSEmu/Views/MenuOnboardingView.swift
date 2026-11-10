// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// First-launch choice of library style. Writes the existing `libraryStyle` key.
// Shown once. Does not touch orientation, lid, or window code.
import SwiftUI

enum MenuOnboarding {
    static let chosenKey = "twinplay.onboarding.menuChosen"
    static let styleKey = "libraryStyle"

    /// True only when this install has never stored a style and has not dismissed the screen.
    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: chosenKey) { return false }
        if defaults.object(forKey: styleKey) != nil { return false }
        return true
    }

    static func choose(_ style: String, defaults: UserDefaults = .standard) {
        defaults.set(style, forKey: styleKey)
        defaults.set(true, forKey: chosenKey)
    }
}

struct MenuOnboardingView: View {
    var onChoose: (String) -> Void
    @State private var selected = "classicDS"

    var body: some View {
        GeometryReader { geo in
            let pad = max(16, min(28, geo.size.width * 0.04))
            ScrollView {
                VStack(alignment: .leading, spacing: geo.size.height < 420 ? 12 : 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How should your library look?")
                            .font(.system(geo.size.width < 380 ? .title2 : .largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(ClassicPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Pick one to start. You can change it any time in Settings.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(ClassicPalette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let wide = geo.size.width >= 680
                    Group {
                        if wide {
                            HStack(alignment: .top, spacing: 16) { styleChoices(tall: geo.size.height) }
                        } else {
                            VStack(spacing: 14) { styleChoices(tall: geo.size.height) }
                        }
                    }
                    Button { onChoose(selected) } label: {
                        Text("Continue with \(selected == "classicDS" ? "Classic" : "Standard")")
                            .font(.system(.headline, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ClassicPalette.accent)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, pad)
                .padding(.top, max(pad, geo.safeAreaInsets.top + 8))
                .padding(.bottom, max(pad, geo.safeAreaInsets.bottom + 12))
                .frame(maxWidth: geo.size.width >= 900 ? 880 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(ClassicPalette.body.ignoresSafeArea())
        }
    }

    @ViewBuilder private func styleChoices(tall: CGFloat) -> some View {
        styleCard("classicDS", "Classic", "Two screens, like a closed handheld menu. The game you select sits on top.", tall: tall)
        styleCard("standard", "Standard", "A scrolling library with your game’s picture, play time, and stats up front.", tall: tall)
    }

    private func styleCard(_ id: String, _ title: String, _ detail: String, tall: CGFloat) -> some View {
        let on = selected == id
        return Button { selected = id } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if id == "classicDS" { ClassicStylePreview() }
                        else { StandardStylePreview() }
                    }
                    .frame(height: tall < 420 ? 150 : 210)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if on {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ClassicPalette.accent)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(ClassicPalette.text)
                Text(detail)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(ClassicPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(on ? ClassicPalette.screen : LinearGradient(colors: [ClassicPalette.panel, ClassicPalette.panel], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(on ? ClassicPalette.accent : ClassicPalette.line, lineWidth: on ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Miniature of the Classic library: top card, hinge, icon row. The highlight moves.
private struct ClassicStylePreview: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.4)) { ctx in
            let tick = Int(ctx.date.timeIntervalSinceReferenceDate / 1.4)
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("TwinPlay").font(.system(size: 9, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(ClassicPalette.accent))
                            .foregroundStyle(.black.opacity(0.8))
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ClassicPalette.accent.opacity(0.85))
                            .frame(width: 36, height: 48)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Night Circuit").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(ClassicPalette.text).lineLimit(1)
                            Text("12 plays · 2h").font(.system(size: 9, design: .rounded)).foregroundStyle(ClassicPalette.dim)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClassicPalette.screen))
                Capsule().fill(Color.black.opacity(0.55)).frame(height: 8)
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(i == tick % 4 ? ClassicPalette.accent : Color.white.opacity(0.14))
                            .frame(height: 36)
                            .overlay(
                                Text(["NC", "PH", "RC", "GL"][i])
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(i == tick % 4 ? Color.black.opacity(0.75) : ClassicPalette.text)
                            )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .padding(8)
            .background(ClassicPalette.body)
        }
        .accessibilityHidden(true)
    }
}

/// Miniature of the Standard library: title, info card, tile grid.
private struct StandardStylePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TwinPlay")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ClassicPalette.accent.opacity(0.9))
                    .frame(width: 42, height: 56)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Night Circuit").font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text("TIME  2h   PLAYS  12").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(["Paper Harbor", "Red Canyon", "Glass Lake", "North Line", "Amber Road", "Quiet Bay"], id: \.self) { name in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 36)
                        Text(name).font(.system(size: 8, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemGroupedBackground))
        .accessibilityHidden(true)
    }
}

#if DEBUG
struct MenuOnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MenuOnboardingView { _ in }.frame(width: 320, height: 568).previewDisplayName("Small iPhone")
            MenuOnboardingView { _ in }.frame(width: 430, height: 932).previewDisplayName("Large iPhone")
            MenuOnboardingView { _ in }.frame(width: 820, height: 1180).previewDisplayName("iPad")
            MenuOnboardingView { _ in }.frame(width: 900, height: 420).previewDisplayName("Landscape")
        }
    }
}
#endif
