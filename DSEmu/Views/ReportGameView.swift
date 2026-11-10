// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// "Report a game that doesn't work": a short form that opens a pre-filled email draft to
// support. Nothing is sent automatically; the user reviews and sends it from Mail.
import SwiftUI
import UIKit
import MessageUI

enum Support {
    /// The one place the support address lives.
    // The only place the app has the support address (About, Report a Game, paywall use this).
    static let email = "twinplay.support@gmail.com"
    static var mailtoURL: URL { URL(string: "mailto:\(email)?subject=TwinPlay%20Support")! }
    /// Public support and privacy pages (also entered in App Store Connect).
    static let supportPageURL = URL(string: "https://chariio.github.io/support/")!
    static let privacyPageURL = URL(string: "https://chariio.github.io/privacy/")!
}

/// The experimental-core notice, shown on the empty library and as the library footer.
struct ExperimentalNotice: View {
    var compact = false
    var onReport: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text("This app does not include any games, BIOS, firmware or cover art. Use only games you own. The emulation core is experimental and some games do not run correctly yet.",
                 comment: "Library disclaimer")
                .font(compact ? .caption2 : .footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let onReport {
                Button(action: onReport) {
                    Label(String(localized: "Report a game that doesn't work", comment: "Library footer button"), systemImage: "exclamationmark.bubble")
                        .font(.footnote.weight(.semibold))
                }
                .glassButton()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 520)
    }
}

struct ReportGameView: View {
    @Environment(\.dismiss) private var dismiss
    let games: [ReportableGame]
    @State private var selected: Int = 0
    @State private var title = ""
    @State private var gameID = ""
    @State private var system = "DS"
    @State private var details = ""
    @State private var includeDevice = true
    @State private var showMail = false
    @State private var noMail = false

    struct ReportableGame: Hashable { let title: String; let id: String; let system: String }

    private let systems = ["DS", "Game Boy Advance", "Game Boy", "Game Boy Color"]

    var body: some View {
        NavigationStack {
            Form {
                if !games.isEmpty {
                    Section {
                        Picker(String(localized: "Game", comment: "Report form"), selection: $selected) {
                            ForEach(games.indices, id: \.self) { Text(games[$0].title).tag($0) }
                        }
                        .onChange(of: selected) { fill($0) }
                    }
                }
                Section(String(localized: "Game", comment: "Report form")) {
                    TextField(String(localized: "Title", comment: "Report form"), text: $title)
                    TextField(String(localized: "Game ID (optional)", comment: "Report form"), text: $gameID)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Picker(String(localized: "System", comment: "Report form"), selection: $system) {
                        ForEach(systems, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section(String(localized: "What goes wrong?", comment: "Report form")) {
                    TextEditor(text: $details).frame(minHeight: 120)
                }
                Section {
                    Toggle(String(localized: "Include device info", comment: "Report form"), isOn: $includeDevice)
                } footer: {
                    Text(includeDevice ? deviceInfo : String(localized: "Only the details above are included.", comment: "Report form"))
                }
            }
            .navigationTitle(String(localized: "Report a Game", comment: "Report form title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create Email", comment: "Report form")) { compose() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if !games.isEmpty { fill(selected) } }
            .sheet(isPresented: $showMail) {
                MailComposer(to: Support.email, subject: subject, body: bodyText) { showMail = false; dismiss() }
                    .ignoresSafeArea()
            }
            .alert(String(localized: "Mail isn't set up", comment: "Report form"), isPresented: $noMail) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please email \(Support.email) with the details.", comment: "Report form fallback")
            }
        }
    }

    private func fill(_ i: Int) {
        guard games.indices.contains(i) else { return }
        title = games[i].title; gameID = games[i].id; system = games[i].system
    }

    private var subject: String { "TwinPlay game report: \(title)" + (gameID.isEmpty ? "" : " [\(gameID)]") }

    private var deviceInfo: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var sys = utsname(); uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        return "TwinPlay \(v) (\(b)) · \(model) · iOS \(UIDevice.current.systemVersion)"
    }

    private var bodyText: String {
        var s = "Game: \(title)\nGame ID: \(gameID.isEmpty ? "-" : gameID)\nSystem: \(system)\n\nWhat goes wrong:\n\(details)\n"
        if includeDevice { s += "\n\(deviceInfo)\n" }
        return s
    }

    private func compose() {
        if MFMailComposeViewController.canSendMail() { showMail = true; return }
        var c = URLComponents(); c.scheme = "mailto"; c.path = Support.email
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: bodyText)]
        if let url = c.url, UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url); dismiss() } else { noMail = true }
    }
}

/// Mail's own compose sheet: the user reviews and sends (or cancels) the draft.
struct MailComposer: UIViewControllerRepresentable {
    let to: String, subject: String, body: String
    let done: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([to]); vc.setSubject(subject); vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func mailComposeController(_ c: MFMailComposeViewController, didFinishWith r: MFMailComposeResult, error: Error?) { done() }
    }
}
