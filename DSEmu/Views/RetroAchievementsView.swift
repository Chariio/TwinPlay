// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

/// #13 Settings > RetroAchievements: account (username / password, Sign in), mode and status.
struct RetroAchievementsView: View {
    @ObservedObject private var ra = RetroAchievements.shared
    @State private var username = UserDefaults.standard.string(forKey: RetroAchievementsRules.usernameKey) ?? ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case user, pass }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "medal.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.84, blue: 0.3), Color(red: 0.85, green: 0.55, blue: 0.1)],
                                                        startPoint: .top, endPoint: .bottom))
                    Text("RetroAchievements").font(.headline)
                    Text("Earn achievements in Game Boy, Game Boy Color, Game Boy Advance and DS games.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            Section {
                if ra.signedIn {
                    LabeledContent("Signed in as", value: ra.displayName ?? ra.username)
                    LabeledContent("Points", value: "\(ra.score)")
                    Button("Sign out", role: .destructive) { ra.signOut(); password = "" }
                } else {
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .pass }
                    SecureField("Password", text: $password)
                        .textContentType(.password).focused($focus, equals: .pass).submitLabel(.go).onSubmit(signIn)
                    Button(action: signIn) {
                        HStack { Text("Sign in"); if ra.busy { Spacer(); ProgressView() } }
                    }
                    .disabled(ra.busy || !RetroAchievementsRules.canSignIn(username: username, password: password))
                }
                if let e = ra.lastError { Text(e.loc).font(.footnote).foregroundStyle(.red) }
            } header: { Text("Account") } footer: {
                Text("Your password is sent only to RetroAchievements to sign in and is never saved. TwinPlay keeps the sign-in token in the Keychain on this device. No account? Create one for free at retroachievements.org.")
            }
            Section {
                Toggle("Hardcore mode", isOn: $ra.hardcore)
            } header: { Text("Mode") } footer: {
                Text("Softcore (default) allows save states and cheats. Hardcore follows RetroAchievements' rules: cheats and loading save states are turned off while it is on. Hardcore unlocks count only once RetroAchievements approves TwinPlay as an emulator; until then they are recorded as softcore.")
            }
            if let p = ra.gameProgress {
                Section("Current game") { Text(p) }
            }
            Section {
                Text("Uses rcheevos © RetroAchievements.org, MIT licence.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("RetroAchievements")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ra.restore() }
    }

    private func signIn() {
        guard RetroAchievementsRules.canSignIn(username: username, password: password) else { return }
        focus = nil
        ra.signIn(username: username, password: password)
        password = ""      // never kept, not even in this screen's state
    }
}
