// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// A settings list that works the same with touch and with a game controller:
// up/down = focus (highlighted, auto-scrolled), A = toggle/activate, left/right = change a
// choice or slider, L/R = previous/next section, B = back/close. Plus a controller-friendly
// confirmation / alert overlay.
import SwiftUI

struct PadRow: Identifiable {
    enum Kind {
        case action(() -> Void)
        case toggle(Binding<Bool>)
        case choice([String], Binding<Int>)
        case slider(Binding<Float>, ClosedRange<Float>, Float)
        case info
    }
    let id: String
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var destructive = false
    var chevron = false
    var kind: Kind
    var focusable: Bool { if case .info = kind { return false }; return true }
}

struct PadSection: Identifiable {
    var id: String { title }
    var title: String
    var footer: String? = nil
    var rows: [PadRow]
}

struct PadFormView: View {
    @Environment(\.padFormGlass) private var padGlass
    let sections: [PadSection]
    let scope: String
    var onBack: () -> Void
    /// Extra events (e.g. Menu) the owner wants; return true if handled.
    var onOther: ((PadNav, PadRow?) -> Bool)? = nil
    @State private var focus = 0
    @ObservedObject private var pad = PadNavigator.shared

    private var flat: [(section: Int, row: PadRow)] {
        sections.enumerated().flatMap { s in s.element.rows.filter(\.focusable).map { (s.offset, $0) } }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { si, sec in
                        if !sec.title.isEmpty {
                            Text(sec.title.loc.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.top, si == 0 ? 4 : 14)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(sec.rows.enumerated()), id: \.element.id) { ri, row in
                                rowView(row, focused: pad.connected && currentID == row.id)
                                    .id(row.id)
                                if ri < sec.rows.count - 1 { Divider().padding(.leading, 14) }
                            }
                        }
                        .modifier(PadCardBackground(glass: padGlass))
                        if let f = sec.footer { Text(f.loc).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6) }
                    }
                }
                .padding(.horizontal).padding(.bottom, 24)
                .frame(maxWidth: MenuLayout.readableWidth(760))
                .frame(maxWidth: .infinity)
            }
            .background(padGlass ? Color.clear : Color(.systemGroupedBackground))
            .onChange(of: focus) { _ in if let id = currentID { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) } } }
        }
        .padScope(scope) { handle($0) }
    }

    private var currentID: String? { let f = flat; return f.indices.contains(focus) ? f[focus].row.id : nil }

    private func handle(_ e: PadNav) {
        let f = flat
        guard !f.isEmpty else { if e == .b { onBack() } else { _ = onOther?(e, nil) }; return }
        if focus >= f.count { focus = f.count - 1 }
        let row = f[focus].row
        func tick() { UISelectionFeedbackGenerator().selectionChanged() }
        switch e {
        case .up: if focus > 0 { focus -= 1; tick() }
        case .down: if focus < f.count - 1 { focus += 1; tick() }
        case .l, .r:
            let s = f[focus].section
            if e == .r, let i = f.firstIndex(where: { $0.section > s }) { focus = i; tick() }
            if e == .l {
                let target = f[focus].section == f.first?.section ? s : (f.last(where: { $0.section < s })?.section ?? s)
                // first row of the current section if not already there, else of the previous one
                let firstOfCurrent = f.firstIndex(where: { $0.section == s }) ?? 0
                focus = focus != firstOfCurrent ? firstOfCurrent : (f.firstIndex(where: { $0.section == target }) ?? 0); tick()
            }
        case .left, .right: change(row, by: e == .right ? 1 : -1)
        case .a: activate(row)
        case .b: onBack()
        default: _ = onOther?(e, row)
        }
    }

    private func change(_ row: PadRow, by d: Int) {
        switch row.kind {
        case .choice(let opts, let sel):
            guard !opts.isEmpty else { return }
            sel.wrappedValue = min(max(sel.wrappedValue + d, 0), opts.count - 1)
            UISelectionFeedbackGenerator().selectionChanged()
        case .slider(let v, let r, let step):
            v.wrappedValue = min(max(v.wrappedValue + Float(d) * step, r.lowerBound), r.upperBound)
            UISelectionFeedbackGenerator().selectionChanged()
        case .toggle(let b): b.wrappedValue = d > 0
        default: break
        }
    }

    private func activate(_ row: PadRow) {
        switch row.kind {
        case .action(let run): run()
        case .toggle(let b): b.wrappedValue.toggle(); UISelectionFeedbackGenerator().selectionChanged()
        case .choice(let opts, let sel): if !opts.isEmpty { sel.wrappedValue = (sel.wrappedValue + 1) % opts.count }
        default: break
        }
    }

    @ViewBuilder private func rowView(_ row: PadRow, focused: Bool) -> some View {
        let content = HStack(spacing: 12) {
            if let icon = row.icon { Image(systemName: icon).frame(width: 24).foregroundStyle(row.destructive ? Color.red : Color.accentColor) }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title.loc).foregroundStyle(row.destructive ? Color.red : Color.primary)
                    .lineLimit(2).minimumScaleFactor(0.8)
                if let s = row.subtitle { Text(s.loc).font(.caption).foregroundStyle(.secondary) }
                if case .slider(let v, let r, _) = row.kind {
                    Slider(value: v, in: r)
                }
            }
            Spacer(minLength: 8)
            trailing(row)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Color.accentColor.opacity(0.22) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: focused ? 2 : 0).padding(2))
        .contentShape(Rectangle())
        switch row.kind {
        case .action, .choice:
            content.onTapGesture {
                if let i = flat.firstIndex(where: { $0.row.id == row.id }) { focus = i }
                activate(row)
            }
        default: content
        }
    }

    @ViewBuilder private func trailing(_ row: PadRow) -> some View {
        switch row.kind {
        case .toggle(let b): Toggle("", isOn: b).labelsHidden()
        case .choice(let opts, let sel):
            HStack(spacing: 6) {
                Button { change(row, by: -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    .disabled(sel.wrappedValue <= 0)
                Text(opts.indices.contains(sel.wrappedValue) ? opts[sel.wrappedValue].loc : "—")
                    .foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 60)
                Button { change(row, by: 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                    .disabled(sel.wrappedValue >= opts.count - 1)
            }
        case .slider(let v, _, _):
            Text(String(format: "%.2f", v.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
        default:
            if row.chevron { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
    }
}

/// Controller-friendly replacement for alerts / confirmation dialogs.
struct PadDialogButton: Identifiable {
    let id = UUID()
    let title: String
    var destructive = false
    var cancel = false
    let run: () -> Void
}

struct PadDialog: View {
    let title: String
    var message: String? = nil
    var text: Binding<String>? = nil
    let buttons: [PadDialogButton]
    let dismiss: () -> Void
    @State private var focus = 0
    @ObservedObject private var pad = PadNavigator.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { cancel() }
            VStack(spacing: 14) {
                Text(title.loc).font(.headline).multilineTextAlignment(.center)
                if let message { Text(message.loc).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if let text { TextField("Name", text: text).textFieldStyle(.roundedBorder) }
                VStack(spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.element.id) { i, b in
                        Button { choose(i) } label: {
                            Text(b.title.loc).fontWeight(b.cancel ? .regular : .semibold)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .foregroundStyle(b.destructive ? Color.red : Color.accentColor)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: pad.connected && focus == i ? 2.5 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ControllerHintBar(items: [(.up, "Move"), (.a, "Choose"), (.b, "Cancel")])
            }
            .padding(20)
            .frame(maxWidth: 340)
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(30)
        }
        .padScope("dialog-\(title)") { e in
            switch e {
            case .up, .left: focus = max(0, focus - 1); UISelectionFeedbackGenerator().selectionChanged()
            case .down, .right: focus = min(buttons.count - 1, focus + 1); UISelectionFeedbackGenerator().selectionChanged()
            case .a: choose(focus)
            case .b: cancel()
            default: break
            }
        }
        .onAppear { focus = buttons.firstIndex(where: { !$0.cancel }) ?? 0 }
        .transition(.opacity)
    }

    private func choose(_ i: Int) { let b = buttons[i]; dismiss(); b.run() }
    private func cancel() { if let c = buttons.first(where: { $0.cancel }) { dismiss(); c.run() } else { dismiss() } }
}


private struct PadFormGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside the in-game pause menu: cards become Liquid Glass over the paused game.
    var padFormGlass: Bool { get { self[PadFormGlassKey.self] } set { self[PadFormGlassKey.self] = newValue } }
}

private struct PadCardBackground: ViewModifier {
    let glass: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if glass { content.glassSurface(shape) }
        else { content.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
    }
}

/// Presents a sheet with a clear background so the paused game shows through the glass.
struct GlassSheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.environment(\.padFormGlass, true)
                .presentationBackground(.clear)
                .presentationDetents([.fraction(0.62), .large])
                .presentationBackgroundInteraction(.disabled)
        } else {
            content
        }
    }
}
