// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation
import Security

/// #13 RetroAchievements account and per-game session (rcheevos rc_client via RAClient).
/// The password is only sent to RetroAchievements to sign in; TwinPlay keeps the returned
/// token in the Keychain (this device only) and the username in UserDefaults.
@MainActor final class RetroAchievements: ObservableObject {
    static let shared = RetroAchievements()

    @Published private(set) var username: String = UserDefaults.standard.string(forKey: RetroAchievementsRules.usernameKey) ?? ""
    @Published private(set) var signedIn = false
    @Published private(set) var displayName: String?
    @Published private(set) var score = 0
    @Published private(set) var busy = false
    @Published var lastError: String?
    /// Current game: "3 of 40 unlocked", nil when no game or the game has no set.
    @Published private(set) var gameProgress: String?
    @Published var hardcore: Bool = RetroAchievementsRules.hardcore {
        didSet {
            UserDefaults.standard.set(hardcore, forKey: RetroAchievementsRules.hardcoreKey)
            RAClient.shared.hardcore = hardcore
        }
    }

    /// Unlock / mastery messages for the game screen.
    var onToast: ((String) -> Void)?

    private init() {
        RAClient.shared.hardcore = hardcore
        RAClient.shared.onEvent = { [weak self] kind, title, detail, points in
            self?.handle(kind, title: title, detail: detail, points: points)
        }
    }

    var hasSavedLogin: Bool { !username.isEmpty && Keychain.token(for: username) != nil }

    func signIn(username: String, password: String) {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard RetroAchievementsRules.canSignIn(username: user, password: password) else {
            lastError = String(localized: "Enter your RetroAchievements username and password."); return
        }
        busy = true; lastError = nil
        RAClient.shared.login(withUsername: user, password: password) { [weak self] token, error in
            Task { @MainActor in self?.finishSignIn(user: user, token: token, error: error) }
        }
    }

    /// Signs back in with the saved token (app start / before a game). No password involved.
    func restore() {
        guard !signedIn, !busy, !username.isEmpty, let token = Keychain.token(for: username) else { return }
        busy = true
        RAClient.shared.login(withUsername: username, token: token) { [weak self] newToken, error in
            Task { @MainActor in
                guard let self else { return }
                if newToken == nil, let error, error.lowercased().contains("token") {
                    Keychain.deleteToken(for: self.username)     // expired / revoked: ask to sign in again
                }
                self.finishSignIn(user: self.username, token: newToken, error: error)
            }
        }
    }

    private func finishSignIn(user: String, token: String?, error: String?) {
        busy = false
        guard let token else { signedIn = false; lastError = error ?? String(localized: "Sign-in failed."); return }
        Keychain.setToken(token, for: user)
        UserDefaults.standard.set(user, forKey: RetroAchievementsRules.usernameKey)
        username = user
        signedIn = true
        displayName = RAClient.shared.displayName ?? user
        score = RAClient.shared.score
        lastError = nil
        pendingGame.map { startGame(path: $0.0, system: $0.1, core: $0.2) }
    }

    func signOut() {
        RAClient.shared.logout()
        Keychain.deleteToken(for: username)
        UserDefaults.standard.removeObject(forKey: RetroAchievementsRules.usernameKey)
        username = ""; signedIn = false; displayName = nil; score = 0; gameProgress = nil
    }

    // MARK: Game session

    private var pendingGame: (String, GameSystem, DSCoreBridge)?

    func startGame(path: String, system: GameSystem, core: DSCoreBridge) {
        guard hasSavedLogin else { return }
        RAClient.shared.core = core
        guard signedIn else { pendingGame = (path, system, core); restore(); return }
        pendingGame = nil
        let console = RAConsole(rawValue: RetroAchievementsRules.console(for: system)) ?? .gameBoy
        RAClient.shared.loadGame(atPath: path, console: console) { [weak self] title, unlocked, total, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil || total == 0 { self.gameProgress = nil; return }
                self.gameProgress = String(localized: "\(unlocked) of \(total) unlocked")
                self.onToast?("🏅 RetroAchievements: \(unlocked)/\(total)" + (self.hardcore ? " · " + String(localized: "Hardcore") : ""))
                _ = title
            }
        }
    }

    /// Only for the session that started the current game (a new game may already be loading).
    func stopGame(core: DSCoreBridge) {
        guard RAClient.shared.core === core || RAClient.shared.core == nil else { return }
        pendingGame = nil
        RAClient.shared.unloadGame()
        RAClient.shared.core = nil
        gameProgress = nil
    }

    private func handle(_ kind: RAEventKind, title: String, detail: String, points: Int) {
        switch kind {
        case .unlocked:
            onToast?("🏅 \(title) (\(points))")
            refreshProgress()
        case .mastered: onToast?(String(localized: "🏆 Mastered \(title)!"))
        case .serverError: lastError = detail
        case .disconnected: onToast?(String(localized: "RetroAchievements: offline, unlocks will be sent later"))
        case .reconnected: onToast?(String(localized: "RetroAchievements: unlocks sent"))
        case .resetRequested: onToast?(String(localized: "Hardcore turned on: restart the game to earn hardcore unlocks"))
        @unknown default: break
        }
    }

    private func refreshProgress() {
        let total = RAClient.shared.achievementCount
        gameProgress = total > 0 ? String(localized: "\(RAClient.shared.unlockedCount) of \(total) unlocked") : nil
        score = RAClient.shared.score
    }
}

/// Generic-password Keychain item per RetroAchievements user (this device only, after first unlock).
enum Keychain {
    private static let service = "com.charlie.dsemu.retroachievements"

    static func token(for user: String) -> String? {
        var q = base(user)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func setToken(_ token: String, for user: String) {
        deleteToken(for: user)
        var q = base(user)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func deleteToken(for user: String) { SecItemDelete(base(user) as CFDictionary) }

    private static func base(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: user]
    }
}
