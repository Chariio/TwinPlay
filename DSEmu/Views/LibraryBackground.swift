// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Library backgrounds: six original bundled scenes (no logos), "None", or a custom picture
// from Photos / Files, with blur and dim controls. Everything is stored on the device.
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum LibraryBackgrounds {
    static let builtIn: [(id: String, name: String)] = [
        ("bedroom", "Gamer Bedroom"), ("livingroom", "Retro Living Room"), ("gamestore", "Game Store Wall"),
        ("arcade", "Arcade"), ("rooftop", "Neon Rooftop"), ("beach", "Sunset Beach"),
    ]
    static var customURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("library-background.jpg")
    }
    private static let cache = NSCache<NSString, UIImage>()

    static func image(id: String, portrait: Bool) -> UIImage? {
        let key = "\(id)-\(portrait)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var img: UIImage?
        if id == "custom" { img = UIImage(contentsOfFile: customURL.path) }
        else if let url = Bundle.main.url(forResource: "bg_\(id)_\(portrait ? "portrait" : "landscape")", withExtension: "jpg") {
            img = UIImage(contentsOfFile: url.path)
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
    /// Free: "None" and the default scene. Plus: every scene. Pro: your own picture.
    static func allowed(_ id: String) -> Bool {
        if id == "none" || id == "bedroom" { return true }
        return Store.allows(id == "custom" ? .customBackground : .libraryBackgrounds)
    }
    static func effective(_ id: String) -> String { allowed(id) ? id : "bedroom" }
    static func forgetCustom() { cache.removeObject(forKey: "custom-true"); cache.removeObject(forKey: "custom-false") }

    static func saveCustom(_ image: UIImage) -> Bool {
        // Downscale big photos so the library stays light.
        let maxSide: CGFloat = 2400
        let s = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return false }
        do { try data.write(to: customURL, options: .atomic) } catch { return false }
        forgetCustom()
        return true
    }
}

/// Full-bleed background behind the library (Cover Flow and grid).
struct LibraryBackgroundView: View {
    @AppStorage("libraryBackground") private var bg = "bedroom"
    @AppStorage("libraryBackgroundBlur") private var blur = 14.0
    @AppStorage("libraryBackgroundDim") private var dim = 0.45
    @AppStorage("libraryBackgroundVersion") private var version = 0      // bumps when a custom image changes

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height >= geo.size.width
            let bg = LibraryBackgrounds.effective(bg)
            if bg != "none", let img = LibraryBackgrounds.image(id: bg, portrait: portrait) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: blur, opaque: true)
                    .overlay(Color.black.opacity(dim))
                    .clipped()
                    .id("\(bg)-\(version)-\(portrait)")
                    .drawingGroup()
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Settings > Library Background.
struct LibraryBackgroundSettings: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("libraryBackground") private var bg = "bedroom"
    @AppStorage("libraryBackgroundBlur") private var blur = 14.0
    @AppStorage("libraryBackgroundDim") private var dim = 0.45
    @AppStorage("libraryBackgroundVersion") private var version = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var error: String?
    private let cols = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack { LibraryBackgroundView().frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("Preview").font(.headline).foregroundStyle(.white) }
                        .frame(height: 160).listRowInsets(EdgeInsets())
                }
                Section("Background") {
                    LazyVGrid(columns: cols, spacing: 12) {
                        tile(id: "none", name: "None") { Color(.systemGroupedBackground) }
                        ForEach(LibraryBackgrounds.builtIn, id: \.id) { item in
                            tile(id: item.id, name: item.name) {
                                if let img = LibraryBackgrounds.image(id: item.id, portrait: false) { Image(uiImage: img).resizable().scaledToFill() }
                            }
                        }
                        if FileManager.default.fileExists(atPath: LibraryBackgrounds.customURL.path) {
                            tile(id: "custom", name: "My Picture") {
                                if let img = LibraryBackgrounds.image(id: "custom", portrait: false) { Image(uiImage: img).resizable().scaledToFill() }
                            }
                            .id(version)
                        }
                    }
                    .padding(.vertical, 6)
                    if Store.allows(.customBackground) {
                        PhotosPicker(selection: $photoItem, matching: .images) { Label("Choose from Photos", systemImage: "photo") }
                        Button { showFiles = true } label: { Label("Choose from Files", systemImage: "folder") }
                    } else {
                        Button { Store.gate(.customBackground) } label: { Label("Use your own picture (Pro)", systemImage: "lock.fill") }
                    }
                    Button("Use Default") { bg = "bedroom"; blur = 14; dim = 0.45 }
                }
                Section("Look") {
                    VStack(alignment: .leading) { Text("Blur \(Int(blur))"); Slider(value: $blur, in: 0...40) }
                    VStack(alignment: .leading) { Text("Dim \(Int(dim * 100))%"); Slider(value: $dim, in: 0...0.85) }
                }
                if let error { Text(error.loc).foregroundStyle(.red) }
                Section { Text("Built-in scenes are original artwork. A custom picture is copied into the app and never leaves this device.")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            .safeAreaInset(edge: .bottom) { ControllerHintBar(items: [(.left, "Background"), (.up, "Dim"), (.l, "Blur"), (.b, "Done")]) }
            .padScope("background") { e in
                let ids = ["none"] + LibraryBackgrounds.builtIn.map(\.id)
                    + (FileManager.default.fileExists(atPath: LibraryBackgrounds.customURL.path) ? ["custom"] : [])
                let i = ids.firstIndex(of: bg) ?? 0
                switch e {
                case .left: let n = ids[(i + ids.count - 1) % ids.count]; if LibraryBackgrounds.allowed(n) || Store.gate(.libraryBackgrounds) { bg = n }
                case .right: let n = ids[(i + 1) % ids.count]; if LibraryBackgrounds.allowed(n) || Store.gate(.libraryBackgrounds) { bg = n }
                case .up: dim = max(0, dim - 0.05)
                case .down: dim = min(0.85, dim + 0.05)
                case .l: blur = max(0, blur - 2)
                case .r: blur = min(40, blur + 2)
                case .a, .b, .menu: dismiss()
                default: return
                }
                UISelectionFeedbackGenerator().selectionChanged()
            }
            .navigationTitle("Library Background")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { use(img) }
                    else { error = "Couldn't load that photo." }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { use(img) } else { error = "Couldn't open that image." }
            }
        }
    }

    private func use(_ img: UIImage) {
        if LibraryBackgrounds.saveCustom(img) { version += 1; bg = "custom"; error = nil } else { error = "Couldn't save the picture." }
    }

    private func tile<C: View>(id: String, name: String, @ViewBuilder content: () -> C) -> some View {
        Button { if LibraryBackgrounds.allowed(id) || Store.gate(id == "custom" ? .customBackground : .libraryBackgrounds) { bg = id } } label: {
            VStack(spacing: 4) {
                content().frame(height: 78).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(bg == id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: bg == id ? 3 : 1))
                Text(name.loc).font(.caption).foregroundStyle(.primary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
