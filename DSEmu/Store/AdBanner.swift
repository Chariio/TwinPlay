// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Anchored adaptive AdMob banner for the library only (Classic and Standard). Never during gameplay.
// Hidden for Pro (`Store.allows(.noAds)`). IDs live in project.yml. Debug always uses the test unit.
import os
import SwiftUI
import UIKit
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

enum AdLog {
    private static let log = Logger(subsystem: "com.charlie.dsemu", category: "Ads")
    /// Console line Charlie can filter for (`Ads:`) plus the unified log category Ads.
    static func line(_ message: String) {
        log.info("\(message, privacy: .public)")
        print("Ads: \(message)")
    }
}

enum AdConfig {
    /// Google's public test banner unit (always serves test ads).
    static let testBannerUnitID = "ca-app-pub-3940256099942544/2934735716"
    #if DEBUG
    /// Google's adaptive-banner test unit. Used only by the debug "force test ads" switch.
    static let forceTestBannerUnitID = "ca-app-pub-3940256099942544/2435281174"
    static let forceTestAdsKey = "twinplay.debug.forceTestAds"
    static var forceTestAds: Bool { UserDefaults.standard.bool(forKey: forceTestAdsKey) }
    #endif
    /// Debug: a Google test unit (never the real one). Release: TwinPlayBannerUnitID from Info.plist
    /// (<- TWINPLAY_ADMOB_BANNER_ID in project.yml), falling back to the test unit.
    static var bannerUnitID: String {
        #if DEBUG
        if forceTestAds { return forceTestBannerUnitID }
        return testBannerUnitID
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "TwinPlayBannerUnitID") as? String)
            .flatMap { $0.hasPrefix("ca-app-pub-") ? $0 : nil } ?? testBannerUnitID
        #endif
    }
    static var enabled: Bool {
        #if canImport(GoogleMobileAds)
        return true
        #else
        return false
        #endif
    }
    /// True once consent allows requesting ads (or UMP is unavailable). Banners wait for this.
    @MainActor static var canRequestAds = false { didSet { NotificationCenter.default.post(name: readyNote, object: nil) } }
    static let readyNote = Notification.Name("TwinPlayAdsReady")

    /// UMP consent, then the Mobile Ads SDK. Safe to call more than once. No-ops for Pro.
    /// Not tied to a library style: the library calls this after the menu chooser.
    @MainActor static func start() {
        #if canImport(GoogleMobileAds)
        #if DEBUG
        let force = forceTestAds
        if force, !loggedForce {
            loggedForce = true
            AdLog.line("force test ads ON")
        }
        #else
        let force = false
        #endif
        if Store.allows(.noAds), !force {
            if !loggedProSkip {
                loggedProSkip = true
                AdLog.line("SDK start skipped: Pro removes ads (Store.allows noAds)")
            }
            return
        }
        guard !started else { return }
        started = true
        AdLog.line("SDK start: gathering consent (UMP)")
        Consent.gather { startSDK() }
        #else
        AdLog.line("SDK start skipped: GoogleMobileAds is not linked")
        #endif
    }

    #if canImport(GoogleMobileAds)
    /// Height of an anchored adaptive banner for this width. Falls back to 50 before the SDK sizes it.
    @MainActor static func adaptiveHeight(width: CGFloat) -> CGFloat {
        let width = max(width, 1)
        let height = currentOrientationAnchoredAdaptiveBanner(width: width).size.height
        return height > 1 ? height : 50
    }

    @MainActor private static func startSDK() {
        let ok = Consent.canRequestAds
        AdLog.line("consent canRequestAds=\(ok)")
        guard ok else {
            AdLog.line("SDK start skipped: consent does not allow ad requests")
            started = false
            return
        }
        AdLog.line("SDK start: MobileAds.shared.start")
        MobileAds.shared.start { _ in
            AdLog.line("SDK start finished")
        }
        canRequestAds = true
    }
    #endif
    @MainActor private static var started = false
    @MainActor private static var loggedProSkip = false
    #if DEBUG
    @MainActor private static var loggedForce = false
    #endif
}

struct LibraryAdBanner: View {
    @ObservedObject private var store = Store.shared
    #if DEBUG
    @AppStorage(AdConfig.forceTestAdsKey) private var forceTestAds = false
    #endif
    /// Reads `purchasedTier` so a refund/restore hides or shows the banner.
    private var showsAds: Bool {
        _ = store.tier
        #if DEBUG
        if forceTestAds { return AdConfig.enabled }
        #endif
        return AdConfig.enabled && !Store.allows(.noAds)
    }
    var body: some View {
        if showsAds {
            VStack(spacing: 2) {
                AdSlot()
                Button { PaywallPresenter.present(highlight: .noAds) } label: {
                    Text("Remove ads with Pro").font(.caption2)
                }
                .accessibilityLabel("Remove ads with Pro")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
        }
    }
}

#if canImport(GoogleMobileAds)
private struct BannerRepresentable: UIViewRepresentable {
    var width: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView()
        banner.adUnitID = AdConfig.bannerUnitID
        banner.delegate = context.coordinator
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {
        let width = max(width, 1)
        guard abs(width - context.coordinator.requestedWidth) > 2 else { return }
        let size = currentOrientationAnchoredAdaptiveBanner(width: width)
        banner.adSize = size
        context.coordinator.requestedWidth = width
        banner.rootViewController = Self.hostController(for: banner)
        AdLog.line("ad request unit=\(AdConfig.bannerUnitID) size=\(Int(size.size.width))x\(Int(size.size.height))")
        banner.load(Request())
    }

    private static func hostController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder {
            if let controller = next as? UIViewController { return controller }
            responder = next.next
        }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        var requestedWidth: CGFloat = 0
        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            AdLog.line("ad load success unit=\(bannerView.adUnitID)")
        }
        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            AdLog.line("ad load failure unit=\(bannerView.adUnitID) error=\(error.localizedDescription)")
        }
    }
}
#endif

/// Holds the banner's space and only creates it once consent allows ads.
private struct AdSlot: View {
    @State private var ready = AdConfig.canRequestAds
    @State private var width: CGFloat = 0
    var body: some View {
        let height: CGFloat = {
            #if canImport(GoogleMobileAds)
            return width > 1 ? AdConfig.adaptiveHeight(width: width) : 50
            #else
            return 0
            #endif
        }()
        ZStack {
            #if canImport(GoogleMobileAds)
            if ready && width > 1 {
                BannerRepresentable(width: width)
            }
            #endif
        }
        .frame(maxWidth: .infinity)
        .frame(height: ready ? height : 0)
        .background(GeometryReader { geo in
            Color.clear.preference(key: AdWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(AdWidthKey.self) { width = $0 }
        .onReceive(NotificationCenter.default.publisher(for: AdConfig.readyNote)) { _ in ready = AdConfig.canRequestAds }
        .accessibilityHidden(!ready)
    }
}

private struct AdWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
