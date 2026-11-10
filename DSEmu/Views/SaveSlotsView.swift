// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

/// Grid of the auto slot and the 5 manual slots, with thumbnails and timestamps.
struct SaveSlotsView: View {
    let session: EmulatorSession
    @Environment(\.dismiss) private var dismiss
    @State private var infos: [SaveSlotStore.Info] = []
    @State private var confirmOverwrite: Int?
    @State private var focus = 0
    @State private var slotMenu: SaveSlotStore.Info?
    @State private var width: CGFloat = 390
    @ObservedObject private var pad = PadNavigator.shared
    private var cols: Int { max(1, Int((width - 32 + 14) / (150 + 14))) }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Array(infos.enumerated()), id: \.element.id) { i, info in
                        tile(info).padFocus(pad.connected && focus == i).id(i)
                    }
                }
                .padding()
                .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { width = $0 } })
                Text("The auto slot is written when you leave the game or the app goes to the background.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            .onChange(of: focus) { f in withAnimation { proxy.scrollTo(f, anchor: .center) } }
            }
            .overlay { dialogs }
            .safeAreaInset(edge: .bottom) { ControllerHintBar(items: [(.left, "Move"), (.a, "Options"), (.x, "Save"), (.y, "Load"), (.b, "Close")]) }
            .padScope("slots") { e in
                let n = infos.count
                guard n > 0 else { if e == .b { dismiss() }; return }
                func move(_ d: Int) { let f = min(max(focus + d, 0), n - 1); if f != focus { focus = f; UISelectionFeedbackGenerator().selectionChanged() } }
                switch e {
                case .left: move(-1)
                case .right: move(1)
                case .up: move(-cols)
                case .down: move(cols)
                case .a: slotMenu = infos[focus]
                case .x: let i = infos[focus]; if i.slot != SaveSlotStore.autoSlot { if i.isEmpty { save(i.slot) } else { confirmOverwrite = i.slot } }
                case .y: let i = infos[focus]; if !i.isEmpty { session.loadState(slot: i.slot) { ok in if ok { dismiss() } } }
                case .b, .menu: dismiss()
                default: break
                }
            }
            .navigationTitle("Save states")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: reload)
        }
    }

    private func tile(_ info: SaveSlotStore.Info) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
                if let t = info.thumbnail {
                    Image(uiImage: t).resizable().interpolation(.none).scaledToFit().padding(4)
                } else {
                    Text("Empty").foregroundStyle(.secondary)
                }
            }
            .aspectRatio(session.isGBA ? session.singleAspect : 256.0 / 384.0, contentMode: .fit)
            .frame(maxHeight: 220)
            Text(info.title).font(.subheadline.weight(.semibold))
            Text(info.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if info.slot != SaveSlotStore.autoSlot {
                    Button("Save") { if info.isEmpty { save(info.slot) } else { confirmOverwrite = info.slot } }
                        .glassButton(prominent: true)
                }
                Button("Load") { session.loadState(slot: info.slot) { ok in if ok { dismiss() } } }
                    .glassButton().disabled(info.isEmpty)
                Menu {
                    Button("Delete", role: .destructive) { session.slots.delete(slot: info.slot); reload() }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(info.isEmpty)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var dialogs: some View {
        if let s = confirmOverwrite {
            PadDialog(title: "Overwrite this slot?", buttons: [
                PadDialogButton(title: "Overwrite", destructive: true) { save(s) },
                PadDialogButton(title: "Cancel", cancel: true) {},
            ]) { confirmOverwrite = nil }
        } else if let i = slotMenu {
            PadDialog(title: i.title, message: i.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Empty",
                      buttons: slotButtons(i)) { slotMenu = nil }
        }
    }

    private func slotButtons(_ i: SaveSlotStore.Info) -> [PadDialogButton] {
        var b: [PadDialogButton] = []
        if !i.isEmpty { b.append(PadDialogButton(title: "Load") { session.loadState(slot: i.slot) { ok in if ok { dismiss() } } }) }
        if i.slot != SaveSlotStore.autoSlot {
            b.append(PadDialogButton(title: (i.isEmpty ? "Save here" : "Save (overwrite)").loc) {
                if i.isEmpty { save(i.slot) } else { DispatchQueue.main.async { confirmOverwrite = i.slot } } })
        }
        if !i.isEmpty { b.append(PadDialogButton(title: "Delete", destructive: true) { session.slots.delete(slot: i.slot); reload() }) }
        b.append(PadDialogButton(title: "Cancel", cancel: true) {})
        return b
    }

    private func save(_ slot: Int) { session.saveState(slot: slot) { _ in reload() } }
    private func reload() { infos = session.slots.allInfo() }
}
