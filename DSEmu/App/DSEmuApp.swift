// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

@main
struct DSEmuApp: App {
    @StateObject private var library = ROMLibrary()
    @Environment(\.scenePhase) private var scenePhase
    // Create LibraryView only after the first-launch choice (or a prior install's
    // libraryStyle). @AppStorage("libraryStyle") would otherwise write the default
    // and MenuOnboarding.shouldPresent() would skip the prompt.
    #if DEBUG
    @State private var needsMenuChoice: Bool = {
        // Must run before this initializer reads TPAutoBoot / TwinPlayAutoOpen.
        DebugLaunchArgs.sync()
        return (UserDefaults.standard.string(forKey: "TPAutoBoot") == nil
            && UserDefaults.standard.string(forKey: "TwinPlayAutoOpen") == nil)
            ? MenuOnboarding.shouldPresent() : false
    }()
    #else
    @State private var needsMenuChoice = MenuOnboarding.shouldPresent()
    #endif

    init() {
        #if DEBUG
        DebugLaunchArgs.sync()
        #endif
        QualityDefaults.register()
        if let dir = EmulatorSession.logsDirectory() { DSCoreBridge.installCrashLogger(directory: dir.path) }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if needsMenuChoice {
                    MenuOnboardingView { style in
                        MenuOnboarding.choose(style)
                        needsMenuChoice = false
                    }
                } else {
                    LibraryView()
                        .environmentObject(library)
                }
            }
            .task { _ = Store.shared }   // start listening for purchases / restore entitlements
            .task { CloudSaveSync.shared.start() }   // #19 iCloud saves: sync on launch, then watch
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: CloudSaveSync.shared.foreground()
            case .background: CloudSaveSync.shared.background()
            default: break
            }
        }
    }
}
