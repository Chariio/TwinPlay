// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Google User Messaging Platform (UMP): shows the GDPR consent form to users in the
// EEA, UK and Switzerland (and other regulated regions) before any ad is requested.
// DEBUG builds use UMP test settings: -TwinPlayConsentGeo EEA|notEEA forces the geography,
// -TwinPlayConsentReset YES clears the stored choice, -TwinPlayConsentTestDevice <hashed id>.
import UIKit
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(UserMessagingPlatform)
import UserMessagingPlatform
#endif

enum Consent {
    /// Posted on the main thread whenever the consent state was refreshed.
    static let updatedNote = Notification.Name("TwinPlayConsentUpdated")

    /// Gathers consent (shows the form only when required), then calls `done` on the main thread.
    @MainActor static func gather(_ finish: @escaping @MainActor () -> Void) {
        let done: @MainActor () -> Void = { NotificationCenter.default.post(name: updatedNote, object: nil); finish() }
        requestTrackingThen { gatherUMP(done) }
    }

    /// Apple requires the ATT prompt (and NSUserTrackingUsageDescription) when a linked
    /// SDK declares device-ID data as used for tracking. Request it before UMP, and only
    /// once the app is active, so the system dialog can appear.
    @MainActor private static func requestTrackingThen(_ next: @escaping @MainActor () -> Void) {
        let run = {
            #if canImport(AppTrackingTransparency)
            if #available(iOS 14, *) {
                ATTrackingManager.requestTrackingAuthorization { _ in
                    Task { @MainActor in next() }
                }
                return
            }
            #endif
            next()
        }
        if UIApplication.shared.applicationState == .active {
            run()
        } else {
            var tok: NSObjectProtocol?
            tok = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                if let tok { NotificationCenter.default.removeObserver(tok) }
                run()
            }
        }
    }

    @MainActor private static func gatherUMP(_ done: @escaping @MainActor () -> Void) {
        #if canImport(UserMessagingPlatform)
        let params = RequestParameters()
        #if DEBUG
        let d = UserDefaults.standard
        let debug = DebugSettings()
        switch d.string(forKey: "TwinPlayConsentGeo") {
        case "EEA": debug.geography = .EEA
        case "notEEA": debug.geography = .other
        default: break
        }
        if let id = d.string(forKey: "TwinPlayConsentTestDevice") { debug.testDeviceIdentifiers = [id] }
        params.debugSettings = debug
        if d.bool(forKey: "TwinPlayConsentReset") { ConsentInformation.shared.reset() }
        #endif
        ConsentInformation.shared.requestConsentInfoUpdate(with: params) { error in
            Task { @MainActor in
                if let error { AdLog.line("UMP update failed: \(error.localizedDescription)"); done(); return }
                ConsentForm.loadAndPresentIfRequired(from: topController()) { error in
                    Task { @MainActor in
                        if let error { AdLog.line("UMP form failed: \(error.localizedDescription)") }
                        done()
                    }
                }
            }
        }
        #else
        done()
        #endif
    }

    /// Ads may be requested (consent obtained or not required). Without UMP compiled in: true.
    @MainActor static var canRequestAds: Bool {
        #if canImport(UserMessagingPlatform)
        return ConsentInformation.shared.canRequestAds
        #else
        return true
        #endif
    }

    /// Whether Settings must offer a "Privacy choices" entry (required by Google in the EEA/UK).
    @MainActor static var privacyOptionsRequired: Bool {
        #if canImport(UserMessagingPlatform)
        return ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        #else
        return false
        #endif
    }

    @MainActor static func showPrivacyOptions() {
        #if canImport(UserMessagingPlatform)
        ConsentForm.presentPrivacyOptionsForm(from: topController()) { error in
            if let error { print("UMP privacy options failed: \(error)") }
            Task { @MainActor in NotificationCenter.default.post(name: updatedNote, object: nil) }
        }
        #endif
    }

    @MainActor private static func topController() -> UIViewController? {
        var vc = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}
