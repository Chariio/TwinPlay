// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Upgrade screen: Free / Plus / Pro, Restore Purchases. Touch or controller (D-pad + A, B closes).
import StoreKit
import SwiftUI

struct PaywallView: View {
    var highlight: Feature?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = Store.shared
    @ObservedObject private var pad = PadNavigator.shared
    @State private var focus = 1          // 0 Plus, 1 Pro, 2 Restore

    private let freeItems = ["Play every supported game", "Best quality settings", "Save states & controllers", "Classic skins & icon"]
    private var plusFeatures: [Feature] { Feature.allCases.filter { $0.tier == .plus && $0.isAvailable } }
    private var proFeatures: [Feature] { Feature.allCases.filter { $0.tier == .pro && $0.isAvailable } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Image("AboutIcon").resizable().frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Text("Upgrade TwinPlay").font(.system(size: 30, weight: .heavy, design: .rounded))
                        if let highlight {
                            Text("“\(highlight.title)” needs \(highlight.tier.label).").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("One-time purchase. No subscription.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if store.tier > .free {
                            Label("You have \(store.tier.label)", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                        }
                    }
                    tierCard(title: "Free", price: "Free", tint: .gray, rows: freeItems.map { ($0, "checkmark") }, index: nil, owned: true)
                    tierCard(title: "Plus", price: store.price(Store.plusID, fallback: "$0.99"), tint: .blue,
                             rows: [("Everything in Free", "checkmark")] + plusFeatures.map { ($0.title, $0.icon) },
                             index: 0, owned: store.tier >= .plus)
                    tierCard(title: "Pro", price: store.price(Store.proID, fallback: "$4.99"), tint: .purple,
                             rows: [("Everything in Plus", "checkmark")] + proFeatures.map { ($0.title, $0.icon) },
                             index: 1, owned: store.tier >= .pro, badge: "BEST VALUE")
                    Button { Task { await store.restore() } } label: {
                        Text("Restore Purchases").font(.headline).frame(maxWidth: .infinity).padding(12)
                    }
                    .glassButton()
                    .padFocus(pad.connected && focus == 2)
                    if let m = store.message { Text(m).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Text("Purchases are tied to your Apple ID and work on all your devices. Payment is charged to your Apple ID at confirmation. TwinPlay includes no games or BIOS.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
            .disabled(store.busy)
            .overlay { if store.busy { ProgressView().controlSize(.large) } }
            .background(LinearGradient(colors: [Color.purple.opacity(0.3), Color(.systemGroupedBackground)], startPoint: .top, endPoint: .center).ignoresSafeArea())
            .navigationTitle("TwinPlay Plus & Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { ControllerHintBar(items: [(.up, "Move"), (.a, "Choose"), (.b, "Close")]) }
            .padScope("paywall") { e in
                switch e {
                case .up: focus = max(0, focus - 1); UISelectionFeedbackGenerator().selectionChanged()
                case .down: focus = min(2, focus + 1); UISelectionFeedbackGenerator().selectionChanged()
                case .a: activate(focus)
                case .b, .menu: dismiss()
                default: break
                }
            }
            .task { if store.products.isEmpty { await store.load() } }
            .onAppear { if let h = highlight { focus = h.tier == .plus ? 0 : 1 } }
        }
    }

    private func activate(_ i: Int) {
        switch i {
        case 0: if store.tier < .plus { Task { await store.buy(Store.plusID) } }
        case 1: if store.tier < .pro { Task { await store.buy(Store.proID) } }
        default: Task { await store.restore() }
        }
    }

    private func tierCard(title: String, price: String, tint: Color, rows: [(String, String)], index: Int?, owned: Bool, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.loc).font(.title2.weight(.bold)).foregroundStyle(tint)
                if let badge { Text(badge.loc).font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 3).background(tint, in: Capsule()).foregroundStyle(.white) }
                Spacer()
                Text(price.loc).font(.title3.weight(.semibold))
            }
            ForEach(rows, id: \.0) { row in
                Label(row.0.loc, systemImage: row.1).font(.subheadline)
            }
            if let index {
                Button { activate(index) } label: {
                    Text(owned ? "Purchased".loc : String(localized: "Get \(title.loc) — \(price)")).font(.headline).frame(maxWidth: .infinity).padding(12)
                }
                .glassButton(prominent: true).tint(tint).disabled(owned)
            }
        }
        .padding()
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(index == 1 ? 0.8 : 0.25), lineWidth: index == 1 ? 2 : 1))
        .padFocus(pad.connected && index != nil && focus == index)
    }
}
