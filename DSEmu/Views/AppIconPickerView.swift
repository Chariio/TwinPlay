// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Alternate home-screen icons, chosen from Settings or the library. Touch or controller:
// D-pad/stick moves, A picks, B closes. The primary icon is passed as nil.
import SwiftUI
import UIKit

struct AppIconOption: Identifiable {
    let id: String          // asset name; "AppIcon" = primary
    let title: String
    var alternateName: String? { id == "AppIcon" ? nil : id }
    /// Icons whose preview is actually in the asset catalog. The primary icon is always listed.
    static var all: [AppIconOption] {
        listed.filter { $0.id == "AppIcon" || UIImage(named: "IconPreview-\($0.id)") != nil }
    }
    static let listed: [AppIconOption] = [
        .init(id: "AppIcon", title: "Glass Violet (Default)"),
        .init(id: "AppIcon-Violet", title: "Violet"),
        .init(id: "AppIcon-A2bOcean", title: "Ocean"),
        .init(id: "AppIcon-Fire", title: "Fire"),
        .init(id: "AppIcon-A2bLime", title: "Lime"),
        .init(id: "AppIcon-NeonDark", title: "Neon Dark"),
        .init(id: "AppIcon-ClearGlass", title: "Clear Glass"),
        .init(id: "AppIcon-Classic", title: "Classic"),
        .init(id: "AppIcon-Advance", title: "Advance"),
        .init(id: "AppIcon-Midnight", title: "Midnight"),
        .init(id: "AppIcon-Pixel", title: "Pixel"),
        .init(id: "AppIcon-Crimson", title: "Crimson"),
        .init(id: "AppIcon-Ocean", title: "Ocean"),
        .init(id: "AppIcon-Lime", title: "Lime"),
        .init(id: "AppIcon-Analog", title: "Analog"),
        .init(id: "AppIcon-Clamshell", title: "Clamshell"),
        .init(id: "AppIcon-Retro8Gray", title: "Retro 8-bit Gray"),
        .init(id: "AppIcon-Retro8Red", title: "Retro 8-bit Red"),
        .init(id: "AppIcon-Retro8Black", title: "Retro 8-bit Black"),
        .init(id: "AppIcon-Retro8White", title: "Retro 8-bit White"),
        .init(id: "AppIcon-Retro8Blue", title: "Retro 8-bit Blue"),
        .init(id: "AppIcon-Retro16Gray", title: "Retro 16-bit Gray"),
        .init(id: "AppIcon-Retro16Color", title: "Retro 16-bit Color"),
        .init(id: "AppIcon-Retro16Black", title: "Retro 16-bit Black"),
        .init(id: "AppIcon-Retro16Purple", title: "Retro 16-bit Purple"),
        .init(id: "AppIcon-Retro16Teal", title: "Retro 16-bit Teal"),
    ]

    /// Asks iOS to switch icons. The primary icon is nil. `onResult` receives the asset id, or an error.
    @MainActor
    static func apply(_ o: AppIconOption, currentID: String, onResult: @escaping (Result<String, Error>) -> Void) {
        guard UIApplication.shared.supportsAlternateIcons, o.id != currentID else { return }
        guard o.alternateName == nil || Store.gate(.appIcons) else { return }
        UIApplication.shared.setAlternateIconName(o.alternateName) { err in
            DispatchQueue.main.async {
                if let err { onResult(.failure(err)) }
                else { onResult(.success(o.id)) }
            }
        }
    }
}

/// Thumbnail used by Settings and the full picker. The checkmark marks the icon iOS is using.
struct AppIconThumb: View {
    let option: AppIconOption
    var selected: Bool
    var focused: Bool = false
    var side: CGFloat = 72

    var body: some View {
        VStack(spacing: 6) {
            Image("IconPreview-\(option.id)").resizable().aspectRatio(1, contentMode: .fit)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.title3)
                            .foregroundStyle(.white, Color.accentColor).offset(x: 4, y: 4)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: side * 0.22 + 4, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: focused ? 3 : (selected ? 2 : 0)).padding(-3))
                .scaleEffect(focused ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
            Text(option.title.loc)
                .font(.caption2.weight(selected ? .bold : .regular))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: side + 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title.loc)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Picker embedded in Settings. A plain grid (not a nested scroll view) so it
/// lays out on iPhone and iPad in every orientation.
struct AppIconStrip: View {
    @State private var current: String = UIApplication.shared.alternateIconName ?? "AppIcon"
    @State private var message: String?
    private let options = AppIconOption.all
    private let columns = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { start in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(options[start..<min(start + columns, options.count)])) { o in
                        Button {
                            AppIconOption.apply(o, currentID: current) { result in
                                switch result {
                                case .failure(let err): message = String(localized: "Couldn't change icon: \(err.localizedDescription)")
                                case .success(let id): current = id; message = nil; UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
                            }
                        } label: {
                            AppIconThumb(option: o, selected: current == o.id, side: 64)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<max(0, columns - (min(start + columns, options.count) - start)), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if !UIApplication.shared.supportsAlternateIcons {
                Text("This device doesn't support alternate icons.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { current = UIApplication.shared.alternateIconName ?? "AppIcon" }
    }
}

struct AppIconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pad = PadNavigator.shared
    @State private var current: String = UIApplication.shared.alternateIconName ?? "AppIcon"
    @State private var focus = 0
    @State private var message: String?
    private let cols = 3
    private let options = AppIconOption.all

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: cols), spacing: 18) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                            AppIconThumb(option: o, selected: current == o.id, focused: pad.connected && focus == i, side: 96)
                                .id(o.id)
                                .onTapGesture {
                                    focus = i
                                    AppIconOption.apply(o, currentID: current) { result in
                                        switch result {
                                        case .failure(let err): message = String(localized: "Couldn't change icon: \(err.localizedDescription)")
                                        case .success(let id): current = id; message = nil; UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        }
                                    }
                                }
                        }
                    }
                    .padding()
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                    if !UIApplication.shared.supportsAlternateIcons {
                        Text("This device doesn't support alternate icons.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: focus) { f in withAnimation { proxy.scrollTo(options[f].id, anchor: .center) } }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .padScope("appicon") { handle($0) }
        .onAppear { current = UIApplication.shared.alternateIconName ?? "AppIcon"; focus = options.firstIndex { $0.id == current } ?? 0 }
    }

    private func handle(_ e: PadNav) {
        let n = options.count
        func tick() { UISelectionFeedbackGenerator().selectionChanged() }
        switch e {
        case .left: if focus > 0 { focus -= 1; tick() }
        case .right: if focus < n - 1 { focus += 1; tick() }
        case .up: if focus - cols >= 0 { focus -= cols; tick() }
        case .down: if focus + cols < n { focus += cols; tick() } else if focus / cols < (n - 1) / cols { focus = n - 1; tick() }
        case .a:
            AppIconOption.apply(options[focus], currentID: current) { result in
                switch result {
                case .failure(let err): message = String(localized: "Couldn't change icon: \(err.localizedDescription)")
                case .success(let id): current = id; message = nil; UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        case .b, .menu: dismiss()
        default: break
        }
    }
}
