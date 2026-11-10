// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI
import UIKit

extension View {
    /// DEBUG screenshot aid: with -TwinPlayForceLandscape YES the app asks the system to rotate its
    /// window to landscape (the headless simulator has no rotate menu). No-op otherwise.
    func debugForceLandscape() -> some View {
        #if DEBUG
        onAppear {
            guard UserDefaults.standard.bool(forKey: "TwinPlayForceLandscape") else { return }
            // Retried: a request made while a full-screen cover is presenting can be dropped.
            for delay in [0.3, 1.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for case let s as UIWindowScene in UIApplication.shared.connectedScenes {
                        s.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
                        s.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { e in NSLog("TwinPlay rotate: \(e)") }
                    }
                }
            }
        }
        #else
        self
        #endif
    }

    /// DEBUG screenshot aid: -TwinPlayInnerPreview YES lays the game out at the iPhone Duo's inner
    /// display size (669x951pt, portrait) scaled into the window, so the open / mid-fold lid can be
    /// captured from a simulator that is folded shut (its pose cannot be changed from the shell).
    @ViewBuilder func debugInnerPreview() -> some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TwinPlayInnerPreview") {
            GeometryReader { g in
                let k = min(g.size.width / 669.0, g.size.height / 951.0)
                self.frame(width: 669, height: 951).clipped()
                    .scaleEffect(k, anchor: .topLeading)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
            .background(Color.black).ignoresSafeArea()
        } else { self }
        #else
        self
        #endif
    }

    /// DEBUG screenshot aid: -TwinPlayOuterPreview YES draws the game in a 678x466pt box at the
    /// top-left corner (the iPhone Duo outer display in landscape), so it can be captured from a
    /// simulator whose outer display is off.
    @ViewBuilder func debugOuterPreview() -> some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TwinPlayOuterPreview") {
            // Scaled to the inner display's width (669pt); the capture is resized to 2034x1398.
            self.frame(width: 678, height: 466).clipped()
                .scaleEffect(669.0 / 678.0, anchor: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black).ignoresSafeArea()
        } else { self }
        #else
        self
        #endif
    }

}

#if DEBUG
/// DEBUG diagnostics: -TwinPlayDumpWindows <seconds> writes every window / view (class, frame,
/// hidden, alpha, background) and a snapshot of the key window to Documents/Logs after a game opens.
enum DebugWindowDump {
    /// Windows the game turned black when it opened.
    static var blackened: [String] = []
    static func schedule(extra: @escaping () -> String) {
        let d = UserDefaults.standard.double(forKey: "TwinPlayDumpWindows")
        guard d > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { run(extra: extra()) }
    }

    static func run(extra: String) {
        var out = "idiom=\(UIDevice.current.userInterfaceIdiom.rawValue) orient=\(UIDevice.current.orientation.rawValue) \(extra)\nblackened=\(blackened)\n"
        var lines = 0
        func walk(_ v: UIView, _ depth: Int) {
            guard lines < 4000 else { return }
            lines += 1
            out += String(repeating: " ", count: depth) + "\(type(of: v)) f=\(v.frame) h=\(v.isHidden) a=\(v.alpha) bg=\(v.backgroundColor.map { "\($0)" } ?? "nil") op=\(v.isOpaque) layer=\(type(of: v.layer))\n"
            for s in v.subviews { walk(s, depth + 1) }
        }
        var key: UIWindow?
        for case let sc as UIWindowScene in UIApplication.shared.connectedScenes {
            out += "SCENE role=\(sc.session.role.rawValue) state=\(sc.activationState.rawValue) io=\(sc.effectiveGeometry.interfaceOrientation.rawValue) bounds=\(sc.coordinateSpace.bounds)\n"
            for w in sc.windows {
                if w.isKeyWindow { key = w }
                out += "WINDOW \(type(of: w)) f=\(w.frame) hidden=\(w.isHidden) key=\(w.isKeyWindow) level=\(w.windowLevel.rawValue) bg=\(w.backgroundColor.map { "\($0)" } ?? "nil") root=\(w.rootViewController.map { "\(type(of: $0))" } ?? "nil") presented=\(w.rootViewController?.presentedViewController.map { "\(type(of: $0))" } ?? "nil")\n"
                walk(w, 1)
            }
        }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: dir.appendingPathComponent("window-dump.txt"), atomically: true, encoding: .utf8)
        print("TWINPLAYDUMP written \(out.count) chars")
        if let w = key {
            let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
            try? img.pngData()?.write(to: dir.appendingPathComponent("window-dump.png"))
        }
    }
}
#endif
