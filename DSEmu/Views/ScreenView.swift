// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI
import UIKit

/// Displays one DS screen. Uses the session's Metal FramePresenter when available
/// (both screens from one texture, one display link); otherwise falls back to the
/// Core Graphics path below.
struct ScreenView: View {
    let session: EmulatorSession
    let screen: Int

    var body: some View {
        if let presenter = session.presenter {
            MetalScreenView(presenter: presenter, screen: screen)
        } else {
            CGScreenView(core: session.core, screen: screen)
        }
    }
}

struct MetalScreenView: UIViewRepresentable {
    let presenter: FramePresenter
    let screen: Int

    func makeUIView(context: Context) -> MetalScreenLayerView {
        let v = MetalScreenLayerView()
        v.configure(presenter: presenter, screen: screen)
        return v
    }

    func updateUIView(_ uiView: MetalScreenLayerView, context: Context) {
        uiView.configure(presenter: presenter, screen: screen)
    }

    static func dismantleUIView(_ uiView: MetalScreenLayerView, coordinator: ()) {
        uiView.detachFromPresenter()
    }
}

/// Fallback: a CADisplayLink pulls the newest frame from the core and assigns it to a
/// CALayer (Core Graphics path, nearest-neighbour scaling).
struct CGScreenView: UIViewRepresentable {
    let core: DSCoreBridge
    let screen: Int

    func makeUIView(context: Context) -> ScreenLayerView {
        let v = ScreenLayerView()
        v.configure(core: core, screen: screen)
        return v
    }

    func updateUIView(_ uiView: ScreenLayerView, context: Context) {
        uiView.configure(core: core, screen: screen)
    }

    static func dismantleUIView(_ uiView: ScreenLayerView, coordinator: ()) {
        uiView.stopDisplayLink()
    }
}

final class ScreenLayerView: UIView {
    private var core: DSCoreBridge?
    private var screen = 0
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .linear
        layer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(core: DSCoreBridge, screen: Int) {
        self.core = core
        self.screen = screen
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
    }

    private func startDisplayLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        if #available(iOS 15.0, *) {
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stopDisplayLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func refresh() {
        guard let core, let image = core.copyScreenImage(screen) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }
}

/// Breaks the CADisplayLink -> target retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var view: ScreenLayerView?
    init(_ view: ScreenLayerView) { self.view = view }
    @objc func tick() { view?.refresh() }
}
