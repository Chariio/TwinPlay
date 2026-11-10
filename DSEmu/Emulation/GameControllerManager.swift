// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import GameController

/// Reads every connected controller (MFi / Xbox / PlayStation / Switch, via the GameController
/// framework) and maps it through its saved ControllerProfile to DS buttons and shortcut
/// actions. Callbacks arrive on the main queue.
final class GameControllerManager {
    private(set) var pressed: DSButton = []
    private(set) var actions: Set<PadAction> = []
    /// Left stick and right stick, each axis -1...1, y positive up. N64 and 3DS read these.
    private(set) var analog: (Float, Float) = (0, 0)
    private(set) var cStick: (Float, Float) = (0, 0)
    private var triggerZ = false
    /// When false, the sticks are analog instead of extra D-pad directions.
    var useStickAsDpad = true
    /// N64: left/right triggers press Z (shoulders stay L/R). Off for other systems.
    var zOnTriggers = false
    /// Called when DS buttons or shortcut actions change.
    var onChange: (() -> Void)?
    /// Called when a controller connects or disconnects.
    var onConnectionChange: ((Bool) -> Void)?
    /// When set, the next pressed element is reported here instead of being played (remapping).
    var captureNextElement: ((String) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var pressedByController: [ObjectIdentifier: Set<String>] = [:]

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
            self?.onConnectionChange?(true)
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            if let c = n.object as? GCController { self.pressedByController[ObjectIdentifier(c)] = nil }
            self.recompute()
            self.onConnectionChange?(self.isConnected)
        })
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        GCController.stopWirelessControllerDiscovery()
    }

    var isConnected: Bool { GCController.controllers().contains { $0.extendedGamepad != nil } }
    var connectedName: String? { GCController.controllers().first { $0.extendedGamepad != nil }.map(Self.profileID) }

    /// Profile key for a controller model.
    static func profileID(_ c: GCController) -> String {
        if let v = c.vendorName, !v.isEmpty { return v }
        return c.productCategory
    }

    /// Reloads the profiles (after the remapping screen saved changes).
    func reloadProfiles() { recompute() }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let id = ObjectIdentifier(controller)
        pad.valueChangedHandler = { [weak self, weak controller] pad, _ in
            guard let self, let controller else { return }
            // The GameController callback is already on the main queue; don't hop again (that's a frame of stick lag).
            if Thread.isMainThread { self.update(controller: controller, id: id, pad: pad) }
            else { DispatchQueue.main.async { self.update(controller: controller, id: id, pad: pad) } }
        }
        update(controller: controller, id: id, pad: pad)
    }

    private func update(controller: GCController, id: ObjectIdentifier, pad: GCExtendedGamepad) {
        var now = Set<String>()
        let profile = controller.physicalInputProfile
        for (name, button) in profile.buttons where button.isPressed { now.insert(name) }
        // Two fingers on the PlayStation touchpad.
        if let ds = pad as? GCDualShockGamepad,
           ds.touchpadPrimary.xAxis.value != 0 || ds.touchpadPrimary.yAxis.value != 0,
           ds.touchpadSecondary.xAxis.value != 0 || ds.touchpadSecondary.yAxis.value != 0 { now.insert(PadElement.touchpadTwoFinger) }
        if let ds = pad as? GCDualSenseGamepad,
           ds.touchpadPrimary.xAxis.value != 0 || ds.touchpadPrimary.yAxis.value != 0,
           ds.touchpadSecondary.xAxis.value != 0 || ds.touchpadSecondary.yAxis.value != 0 { now.insert(PadElement.touchpadTwoFinger) }
        if let ds = pad as? GCDualSenseGamepad, ds.touchpadButton.isPressed { now.insert(GCInputDualShockTouchpadButton) }
        if let ds = pad as? GCDualShockGamepad, ds.touchpadButton.isPressed { now.insert(GCInputDualShockTouchpadButton) }
        if let x = pad as? GCXboxGamepad, x.buttonShare?.isPressed == true { now.insert(GCInputButtonShare) }
        let cal = StickCalibrationStore.shared.calibration(for: controller)
        if useStickAsDpad {
            for d in cal.stickDirections(pad) { now.insert(PadElement.dir(GCInputLeftThumbstick, d)) }
        }
        analog = (pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
        cStick = (pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        let leftTrig = pad.leftTrigger.isPressed || pad.leftTrigger.value >= 0.3
        let rightTrig = pad.rightTrigger.isPressed || pad.rightTrigger.value >= 0.3
        triggerZ = zOnTriggers && (leftTrig || rightTrig)
        for (name, dpad) in profile.dpads {
            if name == GCInputLeftThumbstick || name == GCInputRightThumbstick { continue }
            if dpad.up.isPressed || dpad.yAxis.value > 0.5 { now.insert(PadElement.dir(name, "up")) }
            if dpad.down.isPressed || dpad.yAxis.value < -0.5 { now.insert(PadElement.dir(name, "down")) }
            if dpad.left.isPressed || dpad.xAxis.value < -0.5 { now.insert(PadElement.dir(name, "left")) }
            if dpad.right.isPressed || dpad.xAxis.value > 0.5 { now.insert(PadElement.dir(name, "right")) }
        }
        let before = pressedByController[id] ?? []
        if let capture = captureNextElement, let newElement = now.subtracting(before).sorted().first {
            captureNextElement = nil
            pressedByController[id] = now
            capture(newElement)
            return
        }
        pressedByController[id] = now
        controllerIDs[id] = Self.profileID(controller)
        recompute()
    }

    private var controllerIDs: [ObjectIdentifier: String] = [:]

    private func recompute() {
        var b: DSButton = []
        var acts = Set<PadAction>()
        if captureNextElement == nil {
            for (id, elements) in pressedByController {
                let profile = ControllerProfileStore.shared.profile(for: controllerIDs[id] ?? "")
                let r = profile.resolve(elements)
                b.formUnion(r.buttons); acts.formUnion(r.actions)
                for e in PadElement.pauseDefaults where elements.contains(e) && profile.map[e] == nil { acts.insert(.pauseMenu) }
                // Profiles saved before the screen-mode shortcut existed: left-stick click cycles it.
                if elements.contains(GCInputLeftThumbstickButton) && profile.map[GCInputLeftThumbstickButton] == nil { acts.insert(.screenMode) }
            }
        }
        if zOnTriggers && triggerZ { b.insert(.z) }
        let analogChanged = true  // caller only recomputes after a pad event; always push so the stick is not stale
        if b != pressed || acts != actions || analogChanged { pressed = b; actions = acts; onChange?() }
    }
}
