// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// "Edit Layout": move and resize each screen and each on-screen control for this console and
// orientation, with snap guides. Drawn over the running (paused) game; the real controls keep
// their look, the editor only adds outlines, handles and a glass panel.
import SwiftUI

struct LayoutEditItem: Identifiable, Equatable {
    enum Kind: Equatable { case screen(String), control(LayoutControl) }
    var kind: Kind
    var rect: CGRect
    var scale: Double = 1          // controls: the current scale
    var label: String
    var id: String {
        switch kind { case .screen(let k): return "screen.\(k)"; case .control(let c): return "ctl.\(c.rawValue)" }
    }
}

struct LayoutEditorOverlay: View {
    let full: CGSize
    let frame: CGRect                       // safe area
    let items: [LayoutEditItem]
    @Binding var draft: CustomLayout
    @Binding var integerSnap: Bool
    let onCancel: () -> Void
    let onDone: () -> Void

    @AppStorage("layoutSnapGuides") private var snapOn = true
    @State private var selected: String?
    @State private var panelOnTop = false
    @State private var dragBase: LayoutEditItem?
    @State private var pinchBase: LayoutEditItem?
    @State private var handleBase: LayoutEditItem?
    @State private var guides = LayoutMath.Snap()

    private var ordered: [LayoutEditItem] {   // screens first so smaller controls on top win the touch
        items.filter { if case .screen = $0.kind { return true } else { return false } }
            + items.filter { if case .control = $0.kind { return true } else { return false } }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.30)
                .contentShape(Rectangle())
                .onTapGesture { selected = nil }
            centerLines
            ForEach(ordered) { item in itemView(item) }
            if let it = items.first(where: { $0.id == selected }) { handle(for: it) }
            guideLines
            panel
        }
        .frame(width: full.width, height: full.height)
        .ignoresSafeArea()
        .onAppear { if selected == nil, let s = items.first(where: { if case .screen = $0.kind { return true } else { return false } }) { selected = s.id } }
    }

    // MARK: Items

    private func itemView(_ item: LayoutEditItem) -> some View {
        let isSel = selected == item.id
        let r = item.rect
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSel ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.001))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSel ? Color.accentColor : Color.white.opacity(0.85),
                              style: StrokeStyle(lineWidth: isSel ? 2.5 : 1.5, dash: isSel ? [] : [6, 4])))
            .overlay(alignment: .topLeading) {
                if isSel || r.width >= 90 {
                    Text(item.label.loc).font(.caption2.weight(.bold)).foregroundStyle(.primary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .glassSurface(Capsule()).padding(4)
                }
            }
            .frame(width: r.width, height: r.height)
            .contentShape(Rectangle())
            .position(x: r.midX, y: r.midY)
            .gesture(moveGesture(item))
            .simultaneousGesture(pinchGesture(item))
            .accessibilityLabel(Text(item.label.loc))
            .accessibilityHint(Text("Drag to move. Drag the corner handle or pinch to resize."))
    }

    private func handle(for it: LayoutEditItem) -> some View {
        let p = CGPoint(x: min(it.rect.maxX, full.width - 18), y: min(it.rect.maxY, full.height - 18))
        return Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 13, weight: .bold))
            .frame(width: 36, height: 36)
            .glassSurface(Circle(), interactive: true, tint: Color.accentColor.opacity(0.55))
            .contentShape(Circle())
            .position(p)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if handleBase == nil { handleBase = it }
                    guard let b = handleBase else { return }
                    let c = CGPoint(x: b.rect.midX, y: b.rect.midY)
                    let start = CGPoint(x: b.rect.maxX, y: b.rect.maxY)
                    let now = CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height)
                    let d0 = max(hypot(start.x - c.x, start.y - c.y), 1)
                    resize(b, ratio: hypot(now.x - c.x, now.y - c.y) / d0)
                }
                .onEnded { _ in handleBase = nil })
            .accessibilityLabel(Text("Resize"))
    }

    // MARK: Gestures

    private func moveGesture(_ item: LayoutEditItem) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBase == nil { dragBase = item; selected = item.id }
                guard let b = dragBase else { return }
                var r = b.rect.offsetBy(dx: v.translation.width, dy: v.translation.height)
                if snapOn {
                    let others = items.filter { $0.id != b.id }.map(\.rect)
                    let xs = [full.width / 2, frame.minX + 8, frame.maxX - 8] + others.flatMap { [$0.minX, $0.midX, $0.maxX] }
                    let ys = [full.height / 2, frame.minY + 8, frame.maxY - 8] + others.flatMap { [$0.minY, $0.midY, $0.maxY] }
                    let s = LayoutMath.snap(r, xs: xs, ys: ys)
                    r = r.offsetBy(dx: s.dx, dy: s.dy); guides = s
                }
                commit(b, rect: LayoutMath.clamp(r, in: bounds(for: b)), scale: b.scale)
            }
            .onEnded { _ in dragBase = nil; guides = .init() }
    }

    private func pinchGesture(_ item: LayoutEditItem) -> some Gesture {
        MagnificationGesture()
            .onChanged { m in
                if pinchBase == nil { pinchBase = item; selected = item.id }
                if let b = pinchBase { resize(b, ratio: Double(m)) }
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func bounds(for item: LayoutEditItem) -> CGRect {
        if case .control(.menu) = item.kind { return frame.insetBy(dx: 4, dy: 4) }   // never under the island / home bar
        return CGRect(origin: .zero, size: full)
    }

    /// Scales the item about its centre by `ratio` of its size when the gesture started.
    private func resize(_ b: LayoutEditItem, ratio: Double) {
        let c = CGPoint(x: b.rect.midX, y: b.rect.midY)
        switch b.kind {
        case .screen:
            let aspect = b.rect.width / b.rect.height
            let maxW = min(full.width, full.height * aspect)
            let w = min(max(b.rect.width * CGFloat(ratio), full.width * CGFloat(LayoutStore.minScreenWidthFraction)), maxW)
            let r = CGRect(x: c.x - w / 2, y: c.y - w / aspect / 2, width: w, height: w / aspect)
            commit(b, rect: LayoutMath.clamp(r, in: bounds(for: b)), scale: b.scale)
        case .control(let ctl):
            let k = min(max(b.scale * ratio, ctl.scaleRange.lowerBound), ctl.scaleRange.upperBound)
            let f = CGFloat(k / b.scale)
            let r = CGRect(x: c.x - b.rect.width * f / 2, y: c.y - b.rect.height * f / 2, width: b.rect.width * f, height: b.rect.height * f)
            commit(b, rect: LayoutMath.clamp(r, in: bounds(for: b)), scale: k)
        }
    }

    private func commit(_ item: LayoutEditItem, rect r: CGRect, scale: Double) {
        let p = ItemPlacement(cx: Double(r.midX / full.width), cy: Double(r.midY / full.height),
                              size: { if case .screen = item.kind { return Double(r.width / full.width) } else { return scale } }())
        switch item.kind {
        case .screen(let k): draft.screens[k] = p
        case .control(let c): draft.controls[c.rawValue] = p
        }
    }

    // MARK: Guides and panel

    private var centerLines: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: full.height).position(x: full.width / 2, y: full.height / 2)
            Rectangle().fill(.white.opacity(0.18)).frame(width: full.width, height: 1).position(x: full.width / 2, y: full.height / 2)
        }.allowsHitTesting(false)
    }

    private var guideLines: some View {
        ZStack {
            ForEach(guides.vGuides, id: \.self) { x in
                Rectangle().fill(Color.yellow).frame(width: 1.5, height: full.height).position(x: x, y: full.height / 2)
            }
            ForEach(guides.hGuides, id: \.self) { y in
                Rectangle().fill(Color.yellow).frame(width: full.width, height: 1.5).position(x: full.width / 2, y: y)
            }
        }.allowsHitTesting(false)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if !panelOnTop { Spacer(minLength: 0) }
            VStack(spacing: 10) {
                HStack {
                    Text("Edit Layout").font(.headline)
                    Spacer()
                    Button { withAnimation { panelOnTop.toggle() } } label: {
                        Image(systemName: panelOnTop ? "chevron.down" : "chevron.up").frame(width: 36, height: 36)
                    }
                    .glassButton()
                    .accessibilityLabel(Text("Move this panel"))
                }
                Text("Drag to move. Drag the corner handle or pinch to resize.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Snap guides", isOn: $snapOn)
                Toggle("Integer scaling (pixel-perfect)", isOn: $integerSnap)
                Text("The menu button always stays on screen.").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button("Reset to Default", role: .destructive) { draft = CustomLayout(); selected = nil }
                        .glassButton()
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel).glassButton()
                    Button("Done", action: onDone).glassButton(prominent: true)
                }
            }
            .padding(14)
            .frame(maxWidth: 420)
            .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 12)
            if panelOnTop { Spacer(minLength: 0) }
        }
        .padding(.top, frame.minY + 6)
        .padding(.bottom, max(full.height - frame.maxY, 0) + 6)
        .frame(width: full.width, height: full.height)
    }
}
