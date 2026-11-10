// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// In-app purchases (StoreKit 2): Free, Plus ($0.99) and Pro ($4.99), both non-consumable.
// Pro includes everything in Plus. Every game plays at the best settings on every tier.
import StoreKit
import SwiftUI
import UIKit

enum Tier: Int, Comparable {
    case free = 0, plus = 1, pro = 2
    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String { switch self { case .free: "Free"; case .plus: "Plus"; case .pro: "Pro" } }
}

/// Features gated by a tier.
enum Feature: String, CaseIterable, Identifiable {
    case extraSkins, libraryBackgrounds, appIcons, screenLayouts
    case coverFlow, customBIOS, fpsOverlay, stickCalibration, customBackground, noAds
    var id: String { rawValue }
    /// Shipped in this build. (The box-art finder is free since 1.1, so it is not a feature here.)
    var isAvailable: Bool { true }
    var tier: Tier {
        switch self {
        case .extraSkins, .libraryBackgrounds, .appIcons, .screenLayouts: return .plus
        default: return .pro
        }
    }
    var title: String { englishTitle.loc }
    /// English source text (the String Catalog key).
    var englishTitle: String {
        switch self {
        case .extraSkins: "All skins"
        case .libraryBackgrounds: "Library scenes"
        case .appIcons: "App icons"
        case .screenLayouts: "Single-screen mode"
        case .coverFlow: "Cover Flow"
        case .customBIOS: "BIOS tools"
        case .fpsOverlay: "FPS overlay"
        case .stickCalibration: "Joystick calibration"
        case .customBackground: "Your own background picture"
        case .noAds: "No ads"
        }
    }
    var icon: String {
        switch self {
        case .extraSkins: "paintpalette"
        case .libraryBackgrounds: "photo.on.rectangle"
        case .appIcons: "app.badge"
        case .screenLayouts: "rectangle.on.rectangle"
        case .coverFlow: "rectangle.stack"
        case .customBIOS: "cpu"
        case .fpsOverlay: "speedometer"
        case .stickCalibration: "scope"
        case .customBackground: "photo"
        case .noAds: "nosign"
        }
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    static let plusID = "com.charlie.dsemu.plus"
    static let proID = "com.charlie.dsemu.pro"
    private static let tierKey = "nduo.purchasedTier"

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var purchasedTier: Tier = Tier(rawValue: UserDefaults.standard.integer(forKey: tierKey)) ?? .free
    /// Set after the first StoreKit entitlement pass (including refunds and revocations).
    @Published private(set) var entitlementsReady = false
    @Published var busy = false
    @Published var message: String?
    private var updates: Task<Void, Never>?

    private init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task { await load() }
    }

    /// Effective tier. Debug builds accept `-TwinPlayDebugUnlock plus|pro|free` (launch argument or default).
    nonisolated static var tier: Tier {
        #if NDUO_TESTER_UNLOCK
        // Charlie's personal device builds (passed on the xcodebuild command line, never in the
        // project): everything unlocked, since local StoreKit testing needs Xcode attached.
        return .pro
        #endif
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "TwinPlayDebugUnlock") {
        case "pro": return .pro
        case "plus": return .plus
        case "free": return .free
        default: break
        }
        #endif
        return Tier(rawValue: UserDefaults.standard.integer(forKey: tierKey)) ?? .free
    }
    var tier: Tier { _ = purchasedTier; return Store.tier }
    nonisolated static func allows(_ f: Feature) -> Bool { tier >= f.tier }

    /// Returns true when allowed; otherwise opens the upgrade screen and returns false.
    @discardableResult
    static func gate(_ f: Feature) -> Bool {
        if allows(f) { return true }
        PaywallPresenter.present(highlight: f)
        return false
    }

    func load() async {
        do {
            let list = try await Product.products(for: [Store.plusID, Store.proID])
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        } catch { message = String(localized: "Couldn't reach the App Store.") }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        // Unverified and revoked/refunded transactions do not count. With none left, the tier is Free.
        var t: Tier = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result, tx.revocationDate == nil else { continue }
            if tx.productID == Store.proID { t = .pro }
            else if tx.productID == Store.plusID, t < .plus { t = .plus }
        }
        UserDefaults.standard.set(t.rawValue, forKey: Store.tierKey)
        purchasedTier = t
        entitlementsReady = true
    }

    func buy(_ id: String) async {
        guard let p = products[id] else { message = String(localized: "This item isn't available right now."); return }
        busy = true; defer { busy = false }
        do {
            switch try await p.purchase() {
            case .success(let v):
                if case .verified(let tx) = v { await tx.finish(); message = String(localized: "Thanks for your support!") }
                else { message = String(localized: "The purchase couldn't be verified.") }
                await refreshEntitlements()
            case .pending: message = String(localized: "Purchase pending approval.")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        busy = true; defer { busy = false }
        do { try await AppStore.sync() } catch { message = String(localized: "Restore failed: \(error.localizedDescription)"); return }
        await refreshEntitlements()
        message = tier == .free ? String(localized: "No purchases found for this Apple ID.") : String(localized: "Restored \(tier.label).")
    }

    func price(_ id: String, fallback: String) -> String { products[id]?.displayPrice ?? fallback }
}

/// Shows the upgrade screen over whatever is on screen (works from inside other sheets).
enum PaywallPresenter {
    @MainActor static func present(highlight: Feature? = nil) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        if top is PaywallHost { return }
        let host = PaywallHost(rootView: PaywallView(highlight: highlight))
        host.modalPresentationStyle = .formSheet
        top.present(host, animated: true)
    }
}
final class PaywallHost: UIHostingController<PaywallView> {}
