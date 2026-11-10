// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// #23 Quick menu colours: the Classic DS Menu themes as big swatches, opened from the library's
// view row (Colors pill). A tap applies the theme at once (the menu behind redraws live).
// Touch or controller: D-pad moves, A applies, B closes.
import SwiftUI
import UIKit

struct MenuColorsPicker: View {
    @AppStorage(ClassicMenuTheme.key) private var themeRaw = ClassicMenuTheme.defaultTheme.rawValue
    @ObservedObject private var pad = PadNavigator.shared
    @State private var focus = 0
    var onClose: () -> Void = {}
    static let cols = 4
    private let themes = ClassicMenuTheme.allCases

    private var current: ClassicMenuTheme { ClassicMenuTheme(rawValue: themeRaw) ?? .defaultTheme }

    var body: some View {
        GeometryReader { geo in
            let cols = MenuLayout.colorColumns(width: geo.size.width)
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Label("Menu colors", systemImage: "paintpalette.fill").font(.system(.headline, design: .rounded))
                        Spacer()
                        Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Close")
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols), spacing: 12) {
                        ForEach(Array(themes.enumerated()), id: \.element.id) { i, t in
                            Button { focus = i; columnCount = cols; apply(t) } label: { swatch(t, focused: pad.connected && focus == i) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(t.label + (t == current ? ", selected".loc : ""))
                        }
                    }
                    ColorPicker(selection: customColor, supportsOpacity: false) {
                        Label("Custom color", systemImage: "paintbrush.pointed")
                            .font(.system(.subheadline, design: .rounded))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                    Text((pad.connected ? "D-pad to move · A to apply · B to close" : "Tap a color to apply it. Custom uses the picker.").loc)
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .onAppear { columnCount = cols }
            .onChange(of: cols) { columnCount = $0 }
        }
        .frame(minWidth: 280, idealWidth: 420, maxWidth: 640)
        .frame(minHeight: 320, idealHeight: 460, maxHeight: 640)
        .padScope("menucolors") { handle($0) }
        .onAppear { focus = themes.firstIndex(of: current) ?? 0 }
    }

    @State private var columnCount = MenuColorsPicker.cols

    private var customColor: Binding<Color> {
        Binding(get: {
            let hex = UserDefaults.standard.integer(forKey: ClassicMenuTheme.customColorKey)
            return RGB(hex == 0 ? 0x10566A : UInt32(hex & 0xFFFFFF)).color
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            let hex = (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
            UserDefaults.standard.set(hex, forKey: ClassicMenuTheme.customColorKey)
            themeRaw = ClassicMenuTheme.custom.rawValue
            UISelectionFeedbackGenerator().selectionChanged()
        })
    }

    private func swatch(_ t: ClassicMenuTheme, focused: Bool) -> some View {
        let on = t == current
        return VStack(spacing: 5) {
            ZStack {
                Circle().fill(LinearGradient(colors: [t.screenTop.color, t.bodyBottom.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().fill(t.accent.color).frame(width: 16, height: 16).offset(x: 13, y: 13)
                    .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1).frame(width: 16, height: 16).offset(x: 13, y: 13))
                if on { Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy)).foregroundStyle(t.text.color) }
            }
            .frame(width: 54, height: 54)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .overlay(Circle().stroke(on ? t.accent.color : (focused ? Color.accentColor : .clear), lineWidth: 3).padding(-4))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            Text(t.label).font(.system(size: 11, weight: on ? .bold : .regular, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .contentShape(Rectangle())
    }

    private func apply(_ t: ClassicMenuTheme) {
        guard t != current else { return }
        withAnimation(.easeInOut(duration: 0.2)) { themeRaw = t.rawValue }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func handle(_ e: PadNav) {
        let n = themes.count, c = max(1, columnCount)
        switch e {
        case .left: if focus > 0 { focus -= 1 }
        case .right: if focus < n - 1 { focus += 1 }
        case .up: if focus - c >= 0 { focus -= c }
        case .down: if focus + c < n { focus += c }
        case .a: apply(themes[focus])
        case .b, .menu: onClose()
        default: break
        }
    }
}

extension View {
    /// Small popover on every device (iOS 16.4+); a short sheet before that.
    @ViewBuilder func menuColorsPopover(isPresented: Binding<Bool>) -> some View {
        if #available(iOS 16.4, *) {
            popover(isPresented: isPresented, arrowEdge: .top) {
                MenuColorsPicker { isPresented.wrappedValue = false }.presentationCompactAdaptation(.popover)
            }
        } else {
            sheet(isPresented: isPresented) {
                MenuColorsPicker { isPresented.wrappedValue = false }
                    .presentationDetents([.medium, .large])
            }
        }
    }
}
