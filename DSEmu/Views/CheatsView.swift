// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

/// Per-game cheat list: add, enable/disable, edit and delete user-entered codes.
struct CheatsView: View {
    @ObservedObject var session: EmulatorSession
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CheatEntry?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if session.cheats.isEmpty {
                        Text("No cheats yet. Tap + to add a code you have.").foregroundStyle(.secondary)
                    }
                    ForEach(session.cheats) { c in
                        Toggle(isOn: Binding(get: { c.enabled }, set: { on in update(c.id) { $0.enabled = on } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name.isEmpty ? String(localized: "Untitled cheat") : c.name)
                                Text(c.code.replacingOccurrences(of: "\n", with: "  ")).font(.caption.monospaced())
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contextMenu { Button("Edit") { editing = c } }
                        .swipeActions { Button("Delete", role: .destructive) { session.setCheats(session.cheats.filter { $0.id != c.id }) }
                                        Button("Edit") { editing = c } }
                    }
                } footer: {
                    Text(CheatStore.formatHint(session.system) + " " + String(localized: "Cheats can crash games or corrupt saves; make a save state first."))
                }
            }
            .navigationTitle("Cheats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add cheat") }
            }
            .sheet(isPresented: $adding) {
                CheatEditor(system: session.system, entry: CheatEntry(name: "", code: "")) { session.setCheats(session.cheats + [$0]) }
            }
            .sheet(item: $editing) { c in
                CheatEditor(system: session.system, entry: c) { new in update(c.id) { $0 = new } }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout CheatEntry) -> Void) {
        var list = session.cheats
        if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]); session.setCheats(list) }
    }
}

private struct CheatEditor: View {
    let system: GameSystem
    @State var entry: CheatEntry
    let onSave: (CheatEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    private var error: String? {
        entry.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
            : DSCoreBridge.cheatError(code: entry.code, system: CheatStore.coreSystem(system))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("e.g. Infinite health", text: $entry.name) }
                Section {
                    TextEditor(text: $entry.code).font(.body.monospaced()).frame(minHeight: 140)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } header: { Text("Code") } footer: {
                    if let error { Text(error).foregroundStyle(.red) } else { Text(CheatStore.formatHint(system)) }
                }
            }
            .navigationTitle((entry.code.isEmpty ? "Add Cheat" : "Edit Cheat").loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(entry); dismiss() }
                        .disabled(error != nil || entry.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
