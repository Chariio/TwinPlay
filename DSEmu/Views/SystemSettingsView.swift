// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Settings > System: optional user BIOS / firmware, and the FPS overlay.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum FPSCorner: String, CaseIterable, Identifiable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .topLeading: return "Top left"
        case .topTrailing: return "Top right"
        case .bottomLeading: return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        }
    }
    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

/// FPS settings rows (shared by Settings > System and the pause menu).
struct FPSSettingsRows: View {
    @AppStorage("showFPS") private var showFPS = false
    @AppStorage("fpsCorner") private var corner = FPSCorner.topLeading.rawValue
    @AppStorage("fpsFrameTime") private var frameTime = false
    var body: some View {
        Toggle((Store.allows(.fpsOverlay) ? "Show FPS" : "Show FPS (Pro)").loc, isOn: Binding(get: { showFPS && Store.allows(.fpsOverlay) },
                                         set: { if !$0 || Store.gate(.fpsOverlay) { showFPS = $0 } }))
        if showFPS && Store.allows(.fpsOverlay) {
            Picker("Corner", selection: $corner) { ForEach(FPSCorner.allCases) { Text($0.label).tag($0.rawValue) } }
            Toggle("Show frame time", isOn: $frameTime)
        }
    }
}

/// Small corner overlay with emulated FPS (and frame time).
struct FPSOverlay: View {
    @ObservedObject var session: EmulatorSession
    @AppStorage("showFPS") private var showFPS = false
    @AppStorage("fpsCorner") private var corner = FPSCorner.topLeading.rawValue
    @AppStorage("fpsFrameTime") private var frameTime = false
    var body: some View {
        if showFPS && Store.allows(.fpsOverlay) {
            let c = FPSCorner(rawValue: corner) ?? .topLeading
            let fps = session.emulatedFPS
            Text(frameTime ? String(format: "%.0f FPS · %.1f ms", fps, session.frameTimeMs) : String(format: "%.0f FPS", fps))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(fps >= 57 ? Color.green : (fps >= 45 ? Color.yellow : Color.red))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: c.alignment)
                .allowsHitTesting(false)
                .accessibilityLabel(String(format: "%.0f frames per second", fps))
        }
    }
}

struct SystemSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BIOSStore.shared
    @State private var importing: BIOSStore.Kind?          // which row asked; nil = "Import files…" (auto-detect)
    @State private var showImporter = false
    @State private var message: String?
    @State private var confirmRemove: BIOSStore.Kind?
    @State private var showSkins = false
    @AppStorage("lidOnPause") private var lidOnPause = true
    @AppStorage("lidOnDuoClose") private var lidOnTwinClose = true
    @AppStorage("libraryStyle") private var libraryStyle = "classicDS"
    @AppStorage(TouchSettings.hapticsKey) private var touchHaptics = true
    @AppStorage(ClassicMenuTheme.key) private var classicTheme = ClassicMenuTheme.defaultTheme.rawValue
    @AppStorage(ClassicMenuTheme.customColorKey) private var menuCustomHex = 0
    @AppStorage("gbPalette") private var gbPalette = "green"
    @AppStorage("gbColorCorrection") private var gbColorCorrection = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showSkins = true } label: {
                        HStack(spacing: 14) {
                            SkinPreview(skin: Skin.current(for: .ds, raw: UserDefaults.standard.string(forKey: "skin")))
                                .frame(width: 30, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skins").font(.headline).foregroundStyle(.primary)
                                Text("Colour of the play area, controls and lid").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    Picker(selection: $classicTheme) {
                        ForEach(ClassicMenuTheme.allCases) { t in
                            Text(t.label).tag(t.rawValue)
                        }
                        Text("Custom").tag(ClassicMenuTheme.custom.rawValue)
                    } label: {
                        Label("Menu colors", systemImage: "paintpalette")
                    }
                    ColorPicker("Custom menu color", selection: Binding(
                        get: { RGB(menuCustomHex == 0 ? 0x10566A : UInt32(menuCustomHex & 0xFFFFFF)).color },
                        set: { color in
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                            menuCustomHex = (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
                            classicTheme = ClassicMenuTheme.custom.rawValue
                        }
                    ), supportsOpacity: false)
                }
                Section {
                    AppIconStrip()
                } header: {
                    Text("App Icon")
                } footer: {
                    Text("Glass Violet is the icon on the Home Screen until you pick another. Alternate icons can be changed back here.")
                }
                Section {
                    Toggle("Use my own BIOS/firmware", isOn: $store.enabled)
                    Button { importing = nil; showImporter = true } label: { Label("Import BIOS / firmware files…", systemImage: "square.and.arrow.down") }
                } footer: {
                    Text("Select several files at once; TwinPlay recognizes each by size and checksum (any name or extension, e.g. biosnds7.rom). Off (default): TwinPlay's built-in BIOS replacement is used and no files are needed. On: your own dumps are used when present; anything missing falls back to the built-in BIOS. TwinPlay never includes or downloads BIOS or firmware files.")
                }
                Section("DS") {
                    row(.ds9); row(.ds7); row(.dsFirmware)
                    Toggle("Boot through the firmware", isOn: $store.bootFirmware).disabled(store.info[.dsFirmware] == nil)
                    statusLine(store.dsReady ? (store.info[.dsFirmware] != nil && store.bootFirmware
                                                 ? "Ready: real BIOS, firmware boot screen (experimental)" : "Ready: real BIOS, direct boot")
                                             : "Needs bios9.bin and bios7.bin; using built-in BIOS", ok: store.dsReady)
                }
                Section("Game Boy Advance") {
                    row(.gba)
                    statusLine(store.gbaReady ? "Ready: real BIOS with boot intro" : "Using built-in BIOS", ok: store.gbaReady)
                }
                Section {
                    row(.gbBoot); row(.gbcBoot)
                    statusLine(store.info[.gbBoot] != nil || store.info[.gbcBoot] != nil ? "Ready: boot ROM logo before the game" : "Direct boot (no file needed)",
                               ok: store.info[.gbBoot] != nil || store.info[.gbcBoot] != nil)
                    Picker("Game Boy shades", selection: $gbPalette) {
                        Text("Green").tag("green")
                        Text("Gray").tag("gray")
                    }
                    Toggle("Game Boy Color colour correction", isOn: $gbColorCorrection)
                } header: { Text("Game Boy / Game Boy Color") } footer: {
                    Text("Shades apply to original Game Boy games. Colour correction makes Game Boy Color games look like the handheld's screen instead of overly saturated. Takes effect the next time a game starts, or right away from the in-game menu.")
                }
                Section {
                    Picker("Library style", selection: $libraryStyle) {
                        Text("Standard").tag("standard")
                        Text("Classic DS Menu").tag("classicDS")
                    }
                } header: { Text("Library") } footer: {
                    Text("Classic DS Menu shows the selected game on the top screen and a carousel of game icons on the bottom (touch) screen. On an open dual-screen iPhone the two halves sit on either side of the hinge. Menu colors apply to Classic and to the Standard game info card. The choice you make on first launch can be changed here.")
                }
                GamesFolderSection()
                Section {
                    AudioSettingsRows()
                } header: { Text("Audio") } footer: {
                    Text("Smooths DS sound (music, voices, movies) instead of the raw, slightly gritty hardware output. Applies the next time a game starts.")
                }
                ICloudSavesSection()
                Section {
                    Toggle("Haptic feedback", isOn: $touchHaptics)
                } header: { Text("Controls") } footer: {
                    Text("A light tap every time you press an on-screen button. Also in the in-game menu.")
                }
                Section {
                    NavigationLink { RetroAchievementsView() } label: {
                        Label { Text("RetroAchievements") } icon: { Image(systemName: "medal.fill").foregroundStyle(.yellow) }
                    }
                }
                Section("Performance overlay") { FPSSettingsRows() }
                Section {
                    Toggle("Show lid when face-down or folded shut", isOn: $lidOnPause)
                    Toggle("Show lid when folded shut", isOn: $lidOnTwinClose)
                } header: { Text("Lid") } footer: {
                    Text("On iPhone, the TwinPlay lid closes over the game when it is paused or the phone is placed face-down, and opens when you resume. On a dual-screen iPhone, \"Show lid when folded shut\" makes the lid follow the hinge and pauses the game when shut; turn it off to keep playing on the closed screen.")
                }
                #if DEBUG
                ForceTestAdsSection()
                #endif
                if let message { Section { Text(message.loc).font(.footnote) } }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSkins) { SkinPickerView() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // The kind is kept in its own state: with an isPresented binding derived from `importing`,
            // SwiftUI cleared it on dismissal *before* calling this handler, so every import was dropped.
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item],
                          allowsMultipleSelection: importing == nil) { result in
                let k = importing
                importing = nil
                switch result {
                case .success(let urls):
                    if let k, let url = urls.first { message = store.importFile(url, as: k).message }
                    else { message = store.importDetected(urls) }
                case .failure(let e): message = e.localizedDescription
                }
            }
            .confirmationDialog("Remove this file?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let k = confirmRemove { store.remove(k); message = String(localized: "\(k.title) removed.") }; confirmRemove = nil }
            }
            .padScope("system") { e in if e == .b || e == .menu { dismiss() } }
            .safeAreaInset(edge: .bottom) { ControllerHintBar(items: [(.b, "Close")]) }
        }
    }

    private func row(_ k: BIOSStore.Kind) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(k.title)  ").font(.body) + Text(k.rawValue).font(.caption.monospaced()).foregroundColor(.secondary)
                if let i = store.info[k] {
                    Text(String(format: "%@ · CRC32 %08X%@", ByteCountFormatter.string(fromByteCount: Int64(i.size), countStyle: .binary), i.crc,
                                k == .dsFirmware ? "" : (i.verified ? " · verified" : " · unrecognized")))
                        .font(.caption).foregroundStyle(i.verified || k == .dsFirmware ? Color.green : Color.orange)
                } else {
                    Text("Not imported (\(k.sizeText))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.info[k] != nil {
                Button(role: .destructive) { confirmRemove = k } label: { Text("Remove") }.glassButton()
            }
            Button { importing = k; showImporter = true } label: { Text((store.info[k] == nil ? "Import" : "Replace").loc) }.glassButton()
        }
    }

    private func statusLine(_ text: String, ok: Bool) -> some View {
        Label(text.loc, systemImage: ok ? "checkmark.seal.fill" : "info.circle").font(.footnote).foregroundStyle(ok ? .green : .secondary)
    }
}

#if DEBUG
/// Debug builds only. Compiled out of Release, so the App Store binary has no switch and no key.
private struct ForceTestAdsSection: View {
    @AppStorage(AdConfig.forceTestAdsKey) private var forceTestAds = false
    var body: some View {
        Section {
            Toggle("Force test ads (ignore Pro)", isOn: $forceTestAds)
                .onChange(of: forceTestAds) { on in if on { AdConfig.start() } }
        } header: { Text("Debug") } footer: {
            Text("Shows Google's test banner even when this Apple ID has Pro. This switch is not in the App Store build.")
        }
    }
}
#endif

/// #19 Settings › iCloud saves: on/off switch and sync status.
struct ICloudSavesSection: View {
    @ObservedObject private var sync = CloudSaveSync.shared

    var body: some View {
        Section {
            Toggle(isOn: $sync.enabled) {
                Label { Text("iCloud saves") } icon: { Image(systemName: "icloud.fill").foregroundStyle(.blue) }
            }
            HStack(alignment: .firstTextBaseline) {
                Label(sync.statusText, systemImage: sync.status == .syncing ? "arrow.triangle.2.circlepath"
                      : (sync.statusIsGood ? "checkmark.icloud" : "exclamationmark.icloud"))
                    .font(.footnote).foregroundStyle(sync.statusIsGood ? Color.green : Color.secondary)
                Spacer()
                if sync.enabled {
                    Button("Sync now") { sync.syncNow() }.font(.footnote).disabled(sync.status == .syncing)
                }
            }
        } header: { Text("iCloud") } footer: {
            Text("Game saves and save states (with their pictures) sync through your iCloud to your other iPhones and iPads. Your saves always stay on this device too. If two devices changed the same save, the newest one is kept and the other is copied to the \"iCloud Backups\" folder (Files app › On My iPhone › TwinPlay).")
        }
    }
}

/// Settings › Games folder: the Files folder TwinPlay imports from (subfolders included).
struct GamesFolderSection: View {
    @EnvironmentObject private var library: ROMLibrary
    @AppStorage(ROMFolder.nameKey) private var folderName = ""
    @State private var picking = false
    @State private var scanning = false

    var body: some View {
        Section {
            Button { picking = true } label: {
                HStack {
                    Label((folderName.isEmpty ? "Choose games folder…" : "Games folder").loc, systemImage: "folder")
                    Spacer()
                    if !folderName.isEmpty { Text(folderName).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                guard case .success(let folder) = result else { return }
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                try? ROMFolder.remember(folder)
                scan()
            }
            if !folderName.isEmpty {
                Button { scan() } label: {
                    HStack { Label("Find new games now", systemImage: "arrow.clockwise"); if scanning { Spacer(); ProgressView() } }
                }
                .disabled(scanning)
                Button(role: .destructive) { ROMFolder.forget() } label: { Label("Forget this folder", systemImage: "folder.badge.minus") }
            }
        } header: { Text("Games folder") } footer: {
            Text("iOS lets apps see only folders you pick. Choose the folder with your .nds, .gba, .gb and .gbc files, for example On My iPhone › Downloads; TwinPlay imports the games in it and in its subfolders and skips the ones it already has. Your files stay where they are.")
        }
    }

    private func scan() {
        guard let url = ROMFolder.resolve() else { return }
        scanning = true
        library.importFolder(url) { _ in scanning = false }
    }
}

struct AudioSettingsRows: View {
    @AppStorage("highQualityAudio") private var highQualityAudio = true
    var body: some View {
        Toggle("High quality audio", isOn: $highQualityAudio)
    }
}
