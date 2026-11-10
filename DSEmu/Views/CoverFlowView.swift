// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original 3D carousel ("Cover Flow" style) for the library: the centre cover faces the user,
// neighbours turn away in 3D, with floor reflections, snapping and haptics.
import SwiftUI
import UIKit

struct CoverFlowView: View {
    let entries: [ROMLibrary.Entry]
    let style: (ROMLibrary.Entry) -> TileStyle
    let onPlay: (ROMLibrary.Entry) -> Void
    let menu: (ROMLibrary.Entry) -> AnyView
    /// Centred cover index, shared with the library so a game controller can move it.
    @Binding var focus: Int

    /// Fractional index of the cover in the centre.
    @State private var position: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var lastHapticIndex = 0
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            // Short stage (landscape phone): bigger share of the height for covers, one-line caption.
            let compact = geo.size.height < 420
            let size = compact ? max(60, min(geo.size.width * 0.42, (geo.size.height - 40) / 1.1, 300))
                               : min(geo.size.width * 0.46, geo.size.height * 0.52, 300)
            let spacing = size * 0.30                    // gap between side covers
            let sideOffset = size * 0.70                 // distance of the first side cover from the centre
            let centerIndex = clampIndex(Int(position.rounded()))
            VStack(spacing: compact ? 4 : 10) {
                ZStack {
                    ForEach(visibleRange(centerIndex), id: \.self) { i in
                        let e = entries[i]
                        let d = CGFloat(i) - position
                        let a = min(abs(d), 1)
                        let x = d == 0 ? 0 : (d > 0 ? 1 : -1) * (sideOffset * a + max(abs(d) - 1, 0) * spacing)
                        CoverItem(entry: e, style: style(e), size: size)
                            .rotation3DEffect(.degrees(Double(-d.clamped(-1, 1)) * 62), axis: (x: 0, y: 1, z: 0),
                                              anchor: .center, perspective: 0.45)
                            .scaleEffect(1 - 0.18 * a)
                            .offset(x: x)
                            .zIndex(-Double(abs(d)))
                            .onTapGesture {
                                if i == centerIndex { onPlay(e) } else { snap(to: i) }
                            }
                            .contextMenu { menu(e) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(e.name)
                            .accessibilityHint((i == centerIndex ? "Double tap to play" : "Double tap to bring to the centre").loc)
                    }
                }
                .frame(width: geo.size.width, height: size * (compact ? 1.1 : 1.55), alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            if dragStart == nil {
                                // Leave mostly vertical drags to the library's scroll view.
                                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                                dragStart = position; haptic.prepare()
                            }
                            let p = (dragStart ?? 0) - v.translation.width / (spacing * 1.6)
                            position = p.clamped(-0.4, CGFloat(max(entries.count - 1, 0)) + 0.4)
                            tick()
                        }
                        .onEnded { v in
                            guard dragStart != nil else { return }
                            let projected = (dragStart ?? position) - v.predictedEndTranslation.width / (spacing * 1.6)
                            dragStart = nil
                            snap(to: clampIndex(Int(projected.rounded())))
                        }
                )

                if entries.indices.contains(centerIndex) {
                    let e = entries[centerIndex]
                    if compact {
                        HStack(spacing: 10) {
                            SystemBadge(system: e.system)
                            Text(e.name).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                            Button { onPlay(e) } label: { Label("Play", systemImage: "play.fill") }
                                .glassButton(prominent: true).controlSize(.small)
                        }
                        .padding(.horizontal)
                        .frame(width: geo.size.width)
                    } else {
                    VStack(spacing: 4) {
                        Text(e.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            SystemBadge(system: e.system)
                            Text(e.system.longName).font(.caption).foregroundStyle(.secondary)
                        }
                        Button { onPlay(e) } label: { Label("Play", systemImage: "play.fill") }
                            .glassButton(prominent: true).padding(.top, 4)
                    }
                    .padding(.horizontal)
                    .frame(width: geo.size.width)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: entries.map(\.id)) { _ in
            position = CGFloat(clampIndex(Int(position.rounded())))
            focus = clampIndex(Int(position.rounded()))
        }
        .onChange(of: focus) { f in
            let i = clampIndex(f)
            if i != f { focus = i }
            if dragStart == nil && Int(position.rounded()) != i { snap(to: i) }
        }
        .onAppear { position = CGFloat(clampIndex(focus)); lastHapticIndex = clampIndex(focus) }
    }

    private func clampIndex(_ i: Int) -> Int { entries.isEmpty ? 0 : min(max(i, 0), entries.count - 1) }

    private func visibleRange(_ c: Int) -> [Int] {
        guard !entries.isEmpty else { return [] }
        return Array(max(0, c - 7)...min(entries.count - 1, c + 7))
    }

    private func tick() {
        let i = clampIndex(Int(position.rounded()))
        if i != lastHapticIndex { lastHapticIndex = i; haptic.selectionChanged() }
    }

    private func snap(to i: Int) {
        withAnimation(.interactiveSpring(response: 0.45, dampingFraction: 0.82)) { position = CGFloat(i) }
        if focus != i { focus = i }
        if i != lastHapticIndex { lastHapticIndex = i; haptic.selectionChanged() }
    }
}

/// One cover with its floor reflection.
private struct CoverItem: View {
    let entry: ROMLibrary.Entry
    let style: TileStyle
    let size: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            art
            art
                .scaleEffect(x: 1, y: -1)
                .frame(height: size * 0.45, alignment: .top)
                .clipped()
                .mask(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        }
        .frame(width: size)
    }

    private var art: some View {
        Group {
            if style == .cartridge {
                GameArtwork(entry: entry, style: .cartridge, depth3D: true)
            } else {
                GameArtwork(entry: entry, style: style)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
            }
        }
        .frame(width: size, height: size)
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
