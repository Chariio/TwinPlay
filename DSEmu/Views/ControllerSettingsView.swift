// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import GameController
import SwiftUI

/// Remaps the buttons of each controller model and calibrates its sticks. Profiles and
/// calibrations are saved per model (vendor name, e.g. "Xbox Wireless Controller").
/// Fully usable with the controller: up/down, A = remap / open, X = clear, B = back.
struct ControllerSettingsView: View {
    /// The running game's manager, or nil to create one for this screen.
    var manager: GameControllerManager?
    @Environment(\.dismiss) private var dismiss
    @State private var ownManager: GameControllerManager?
    @State private var controllerIDs: [String] = []
    @State private var selected: String = ""
    @State private var profile = ControllerProfile.standard
    @State private var capturing: PadAction?
    @State private var page = "main"
    @State private var confirmReset = false

    private var mgr: GameControllerManager? { manager ?? ownManager }

    var body: some View {
        NavigationStack {
            ZStack {
                if page == "calibrate" {
                    StickCalibrationView(controllerID: selected) { page = "main" }
                        .transition(.move(edge: .trailing))
                } else {
                    PadFormView(sections: sections, scope: "controllers", onBack: {
                        if capturing != nil { stopCapture() } else { dismiss() }
                    }, onOther: { e, row in
                        if e == .x, let row, let a = PadAction(rawValue: row.id) { profile.clear(a); save(); return true }
                        if e == .menu { dismiss(); return true }
                        return false
                    })
                }
                if confirmReset {
                    PadDialog(title: "Reset button mapping?", message: String(localized: "Restores the default buttons for \(selected)."), buttons: [
                        PadDialogButton(title: "Reset", destructive: true) { profile = .standard; save() },
                        PadDialogButton(title: "Cancel", cancel: true) {},
                    ]) { confirmReset = false }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: page)
            .navigationTitle((page == "calibrate" ? "Stick calibration" : "Controllers").loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page != "main" {
                    ToolbarItem(placement: .cancellationAction) { Button { page = "main" } label: { Label("Back", systemImage: "chevron.left") } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { stopCapture(); dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if page == "main" {
                    ControllerHintBar(items: [(.up, "Move"), (.a, capturing == nil ? "Remap" : "…"), (.x, "Clear"), (.left, "Change"), (.b, "Back")])
                }
            }
            .onAppear {
                if manager == nil && ownManager == nil { ownManager = GameControllerManager() }
                refreshControllers()
            }
            .onDisappear { stopCapture() }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshControllers() }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshControllers() }
            .onChange(of: selected) { id in
                stopCapture()
                profile = ControllerProfileStore.shared.profile(for: id)
            }
        }
    }

    private var sections: [PadSection] {
        if controllerIDs.isEmpty {
            return [PadSection(title: "", rows: [PadRow(id: "none", title: "Connect a controller (Settings › Bluetooth) to remap its buttons and calibrate its sticks.", kind: .info)])]
        }
        func row(_ a: PadAction) -> PadRow {
            let names = profile.elements(for: a).map(PadElement.displayName)
            return PadRow(id: a.rawValue, title: a.label,
                          subtitle: capturing == a ? "Press a button on the controller… (B cancels)" : (names.isEmpty ? "None" : names.joined(separator: ", ")),
                          kind: .action { startCapture(a) })
        }
        return [
            PadSection(title: "Controller", footer: "Choose an action, then press the button you want. A button can trigger only one action. X clears an action.", rows: [
                PadRow(id: "ctl", title: "Controller", icon: "gamecontroller", kind: .choice(controllerIDs,
                    Binding(get: { controllerIDs.firstIndex(of: selected) ?? 0 }, set: { if controllerIDs.indices.contains($0) { selected = controllerIDs[$0] } }))),
                PadRow(id: "calib", title: "Joystick calibration…", subtitle: "Centre, range, deadzones, curve, D-pad threshold", icon: "scope",
                       chevron: true, kind: .action { stopCapture(); page = "calibrate" }),
            ]),
            PadSection(title: "DS buttons", rows: PadAction.allCases.filter { $0.dsButton != nil }.map(row)),
            PadSection(title: "Shortcuts", rows: PadAction.allCases.filter { $0.dsButton == nil }.map(row)),
            PadSection(title: "Reset", rows: [PadRow(id: "reset", title: "Reset buttons to defaults", icon: "arrow.uturn.backward", destructive: true,
                                                     kind: .action { confirmReset = true })]),
        ]
    }

    private func startCapture(_ action: PadAction) {
        capturing = action
        PadNavigator.shared.suspended = true
        mgr?.captureNextElement = { element in
            profile.map[element] = nil
            profile.assign(element, to: action)
            capturing = nil
            save()
            // Let the pressed button go before navigation resumes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { PadNavigator.shared.suspended = false }
        }
        // Safety: give up after 8 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if capturing == action { stopCapture() } }
    }

    private func stopCapture() {
        capturing = nil
        mgr?.captureNextElement = nil
        PadNavigator.shared.suspended = false
    }

    private func save() {
        guard !selected.isEmpty else { return }
        ControllerProfileStore.shared.set(profile, for: selected)
        mgr?.reloadProfiles()
    }

    private func refreshControllers() {
        let ids = GCController.controllers().filter { $0.extendedGamepad != nil }.map(GameControllerManager.profileID)
        controllerIDs = Array(Set(ids)).sorted()
        if !controllerIDs.contains(selected) { selected = controllerIDs.first ?? "" }
        profile = ControllerProfileStore.shared.profile(for: selected)
    }
}

/// Stick calibration: release (centre), rotate (range), then live preview and settings.
struct StickCalibrationView: View {
    let controllerID: String
    let onBack: () -> Void
    @State private var cal = StickCalibration.standard
    @State private var step = "idle"            // idle, release, rotate
    @State private var progress: Double = 0
    @State private var samples: [(Float, Float, Float, Float)] = []
    @State private var work = StickCalibration.standard
    @State private var raw: (Float, Float, Float, Float) = (0, 0, 0, 0)
    @State private var confirmReset = false
    @State private var previewRight = false
    private let timer = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    private var controller: GCController? {
        GCController.controllers().first { $0.extendedGamepad != nil && GameControllerManager.profileID($0) == controllerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            preview.padding(.vertical, 10)
            PadFormView(sections: sections, scope: "calibration", onBack: onBack)
        }
        .background(Color(.systemGroupedBackground))
        .overlay { stepOverlay }
        .overlay {
            if confirmReset {
                PadDialog(title: "Reset calibration?", message: String(localized: "Back to the default centre, range and settings for \(controllerID)."), buttons: [
                    PadDialogButton(title: "Reset", destructive: true) { cal = .standard; StickCalibrationStore.shared.set(nil, for: controllerID) },
                    PadDialogButton(title: "Cancel", cancel: true) {},
                ]) { confirmReset = false }
            }
        }
        .safeAreaInset(edge: .bottom) { ControllerHintBar(items: [(.up, "Move"), (.a, "Select"), (.left, "Adjust"), (.b, "Back")]) }
        .onAppear { cal = StickCalibrationStore.shared.calibration(for: controllerID) }
        .onChange(of: cal) { StickCalibrationStore.shared.set($0, for: controllerID) }
        .onReceive(timer) { _ in tick() }
    }

    // MARK: Steps

    private func tick() {
        guard let p = controller?.extendedGamepad else { return }
        raw = (p.leftThumbstick.xAxis.value, p.leftThumbstick.yAxis.value, p.rightThumbstick.xAxis.value, p.rightThumbstick.yAxis.value)
        switch step {
        case "release":
            samples.append(raw)
            progress = Double(samples.count) / 60
            if samples.count >= 60 {                 // 1 s of samples: average = centre
                let n = Float(samples.count)
                work.leftX.center = samples.map(\.0).reduce(0, +) / n; work.leftY.center = samples.map(\.1).reduce(0, +) / n
                work.rightX.center = samples.map(\.2).reduce(0, +) / n; work.rightY.center = samples.map(\.3).reduce(0, +) / n
                for k in [\StickCalibration.leftX, \.leftY, \.rightX, \.rightY] {
                    work[keyPath: k].minV = work[keyPath: k].center; work[keyPath: k].maxV = work[keyPath: k].center
                }
                samples = []; progress = 0; step = "rotate"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        case "rotate":
            func grow(_ k: WritableKeyPath<StickCalibration, StickCalibration.Axis>, _ v: Float) {
                work[keyPath: k].minV = min(work[keyPath: k].minV, v); work[keyPath: k].maxV = max(work[keyPath: k].maxV, v)
            }
            grow(\.leftX, raw.0); grow(\.leftY, raw.1); grow(\.rightX, raw.2); grow(\.rightY, raw.3)
            progress = min(1, progress + 1.0 / (60 * 6))   // 6 s, or A to finish early
            if progress >= 1 { finishRotate() }
        default: break
        }
    }

    private func finishRotate() {
        // Keep sane ranges if a stick was not moved.
        for k in [\StickCalibration.leftX, \.leftY, \.rightX, \.rightY] {
            if work[keyPath: k].maxV - work[keyPath: k].center < 0.3 { work[keyPath: k].maxV = 1 }
            if work[keyPath: k].center - work[keyPath: k].minV < 0.3 { work[keyPath: k].minV = -1 }
        }
        cal.leftX = work.leftX; cal.leftY = work.leftY; cal.rightX = work.rightX; cal.rightY = work.rightY
        step = "idle"; progress = 0
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func start() {
        guard controller != nil else { return }
        work = cal; samples = []; progress = 0; step = "release"
    }

    @ViewBuilder private var stepOverlay: some View {
        if step != "idle" {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: step == "release" ? "hand.raised" : "arrow.triangle.2.circlepath").font(.system(size: 40))
                    Text((step == "release" ? "Release both sticks" : "Rotate both sticks in full circles").loc).font(.title3.weight(.bold))
                    Text((step == "release" ? "Don't touch the sticks while the centre is measured."
                                           : "Push each stick to the edge and turn it slowly a few times. Press A when done.").loc)
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ProgressView(value: progress).frame(width: 220)
                    HStack(spacing: 16) {
                        if step == "rotate" { Button("Done") { finishRotate() }.glassButton(prominent: true) }
                        Button("Cancel") { step = "idle" }.glassButton()
                    }
                    ControllerHintBar(items: step == "rotate" ? [(.a, "Done"), (.b, "Cancel")] : [(.b, "Cancel")])
                }
                .padding(24).frame(maxWidth: 340)
                .glassSurface(RoundedRectangle(cornerRadius: 20))
            }
            .padScope("calibration-step") { e in
                if e == .b { step = "idle"; progress = 0 }
                if e == .a && step == "rotate" { finishRotate() }
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        HStack(spacing: 24) {
            stickPad(title: "Left", rx: raw.0, ry: raw.1, right: false)
            stickPad(title: "Right", rx: raw.2, ry: raw.3, right: true)
        }
    }

    private func stickPad(title: String, rx: Float, ry: Float, right: Bool) -> some View {
        let c = cal.apply(x: rx, y: ry, right: right)
        let dirs = cal.directions(x: rx, y: ry, right: right)
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color(.secondarySystemGroupedBackground))
                Circle().stroke(Color.secondary.opacity(0.4))
                Circle().fill(Color.secondary.opacity(0.15)).scaleEffect(CGFloat(cal.deadzone))
                Circle().stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3])).scaleEffect(CGFloat(cal.dpadThreshold))
                dot(Color.gray, rx, ry)
                dot(Color.accentColor, c.x, c.y).shadow(color: .accentColor, radius: 4)
            }
            .frame(width: 120, height: 120)
            Text(title.loc).font(.caption.weight(.semibold))
            Text(dirs.isEmpty ? "centre".loc : dirs.joined(separator: "+")).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(title.loc) stick \(dirs.isEmpty ? "centred".loc : dirs.joined(separator: " "))"))
    }

    private func dot(_ color: Color, _ x: Float, _ y: Float) -> some View {
        GeometryReader { g in
            Circle().fill(color).frame(width: 12, height: 12)
                .position(x: g.size.width / 2 * CGFloat(1 + max(-1, min(1, x))), y: g.size.height / 2 * CGFloat(1 - max(-1, min(1, y))))
        }
    }

    // MARK: Settings

    private var sections: [PadSection] {
        let curves = StickCalibration.Curve.allCases, uses = StickCalibration.StickUse.allCases
        return [
            PadSection(title: "Calibrate", footer: controller == nil ? String(localized: "Connect \(controllerID) to calibrate.") : "Gray dot = raw stick, blue dot = calibrated. The dashed ring is the D-pad threshold.", rows: [
                PadRow(id: "start", title: "Calibrate sticks", subtitle: "1. Release the sticks · 2. Rotate them in full circles", icon: "scope", kind: .action { if Store.gate(.stickCalibration) { start() } }),
            ]),
            PadSection(title: "Response", rows: [
                PadRow(id: "dz", title: "Deadzone", kind: .slider($cal.deadzone, 0...0.5, 0.01)),
                PadRow(id: "odz", title: "Outer deadzone", kind: .slider($cal.outerDeadzone, 0...0.3, 0.01)),
                PadRow(id: "sens", title: "Sensitivity", kind: .slider($cal.sensitivity, 0.5...2, 0.05)),
                PadRow(id: "curve", title: "Response curve", kind: .choice(curves.map(\.label),
                    Binding(get: { curves.firstIndex(of: cal.curve) ?? 0 }, set: { cal.curve = curves[$0] }))),
                PadRow(id: "thr", title: "Stick-to-D-pad threshold", kind: .slider($cal.dpadThreshold, 0.2...0.9, 0.05)),
                PadRow(id: "inv", title: "Invert Y", kind: .toggle($cal.invertY)),
                PadRow(id: "use", title: "D-pad from", subtitle: "Which stick moves the D-pad in games and menus", kind: .choice(uses.map(\.label),
                    Binding(get: { uses.firstIndex(of: cal.stickForDpad) ?? 0 }, set: { cal.stickForDpad = uses[$0] }))),
            ]),
            PadSection(title: "Reset", rows: [
                PadRow(id: "creset", title: "Reset calibration to default", icon: "arrow.uturn.backward", destructive: true, kind: .action { confirmReset = true }),
            ]),
        ]
    }
}
