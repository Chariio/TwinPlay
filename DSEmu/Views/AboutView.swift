// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Credits / About: version, creator, follow link, thanks and legal note.
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var focus = 0

    private let xURL = URL(string: "https://x.com/CharioBro")!
    private let appXURL = URL(string: "https://x.com/TwinPlayEmu")!
    private let supportURL = Support.mailtoURL
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return b.isEmpty ? String(localized: "Version \(v)") : String(localized: "Version \(v) (\(b))")
    }
    /// Controller-focusable links, top to bottom.
    private var links: [URL] { [appXURL, xURL, supportURL] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    card(title: "Follow on X", icon: "person.crop.circle.badge.plus") {
                        linkButton(0, title: "Follow @TwinPlayEmu for updates", subtitle: "x.com/TwinPlayEmu · official account", symbol: "megaphone", tint: .purple) { openURL(appXURL) }
                        linkButton(1, title: "Follow me on X @CharioBro", subtitle: "x.com/CharioBro · Charlie, creator", symbol: "at", tint: .primary) { openURL(xURL) }
                    }
                    card(title: "Contact/support", icon: "envelope") {
                        linkButton(2, title: "Contact/support", subtitle: Support.email, symbol: "envelope.fill", tint: .blue) { openURL(supportURL) }
                    }
                    card(title: "Your version", icon: "star.circle") {
                        HStack {
                            Text("TwinPlay \(Store.shared.tier.label)").font(.body.weight(.semibold))
                            Spacer()
                            Button((Store.shared.tier == .pro ? "Restore" : "Upgrade").loc) { PaywallPresenter.present() }
                                .glassButton(prominent: true).tint(.purple)
                        }
                    }
                    card(title: "Thanks", icon: "sparkles") {
                        Text("Thanks for downloading TwinPlay! I hope it brings back great memories. Enjoy your games. 💜")
                            .font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("TwinPlay is not affiliated with, endorsed by or sponsored by Nintendo. Nintendo, DS, Game Boy, Game Boy Advance, NES and Super NES are trademarks of their respective owners. TwinPlay includes no games, BIOS or firmware: use only games you have legally obtained and own. Game icons come from your own files; covers are images you choose yourself. The emulation core is experimental and some games do not run correctly yet.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                    Text("© 2026 Charlie Rodriguez Garcia").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(LinearGradient(colors: [Color.purple.opacity(0.25), Color(.systemGroupedBackground)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea())
            .navigationTitle("About TwinPlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { ControllerHintBar(items: [(.up, "Move"), (.a, "Open"), (.y, "Upgrade"), (.b, "Close")]) }
            .padScope("about") { e in
                switch e {
                case .up: focus = max(0, focus - 1); UISelectionFeedbackGenerator().selectionChanged()
                case .down: focus = min(links.count - 1, focus + 1); UISelectionFeedbackGenerator().selectionChanged()
                case .a: openURL(links[focus])
                case .y: PaywallPresenter.present()
                case .b, .menu: dismiss()
                default: break
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image("AboutIcon").resizable().interpolation(.high).frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .shadow(color: .purple.opacity(0.45), radius: 16, y: 8)
                .accessibilityHidden(true)
            Text("TwinPlay").font(.system(size: 38, weight: .heavy, design: .rounded))
            Text(version).font(.subheadline).foregroundStyle(.secondary)
            Text("Created by Charlie Rodriguez Garcia").font(.headline).padding(.top, 2)
            Text("© 2026 Charlie Rodriguez Garcia").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func card<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.loc, systemImage: icon).font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ObservedObject private var pad = PadNavigator.shared

    private func linkButton(_ i: Int, title: String, subtitle: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.loc).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle.loc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padFocus(pad.connected && focus == i)
        .accessibilityHint("Opens \(subtitle)")
    }
}
