//
//  SettingsViewModel.swift
//  Happy
//
//  Created by Happy Engineering
//  Copyright © 2024 Enflame Media. All rights reserved.
//

import Foundation

/// ViewModel for the settings/preferences view.
///
/// Manages user preferences and connected account information.
@Observable
final class SettingsViewModel {
    // MARK: - State

    /// The authenticated account, if any.
    var account: AuthenticatedAccount?

    /// The connected machine, if any.
    var machine: ConnectedMachine?

    /// Whether the user is authenticated.
    var isAuthenticated: Bool {
        authService.state == .authenticated
    }

    /// Selected settings tab.
    var selectedTab: SettingsTab = .general

    // MARK: - Preferences

    /// Whether to show notifications for new messages.
    var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }

    /// Whether to play sounds for events.
    var soundsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "soundsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "soundsEnabled") }
    }

    /// Whether to launch at login.
    var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: "launchAtLogin") }
        set {
            UserDefaults.standard.set(newValue, forKey: "launchAtLogin")
            updateLoginItem(enabled: newValue)
        }
    }

    /// Theme preference.
    var themePreference: ThemePreference {
        get {
            ThemePreference(rawValue: UserDefaults.standard.string(forKey: "themePreference") ?? "system") ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "themePreference") }
    }

    /// Server URL (for development/testing).
    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? "https://api.happy.engineering" }
        set { UserDefaults.standard.set(newValue, forKey: "serverURL") }
    }

    // MARK: - Privacy Settings (HAP-727)

    /// Whether to show online status to friends.
    /// When disabled, user appears offline to all friends.
    var showOnlineStatus: Bool {
        get {
            // Default to true if not set
            if UserDefaults.standard.object(forKey: "showOnlineStatus") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "showOnlineStatus")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "showOnlineStatus")
            // Sync to server when authenticated
            Task { await syncPrivacySettingsToServer() }
        }
    }

    /// Whether privacy settings are being synced.
    var isSyncingPrivacy: Bool = false

    /// Error message if privacy sync fails.
    var privacySyncError: String?

    // MARK: - Private Properties

    private let authService: AuthService

    // MARK: - Initialization

    init(authService: AuthService = .shared) {
        self.authService = authService
        loadAccountInfo()
    }

    // MARK: - Public Methods

    /// Load current account and machine info.
    func loadAccountInfo() {
        account = authService.account
        machine = authService.machine
    }

    /// Log out and disconnect.
    func logout() {
        authService.logout()
        account = nil
        machine = nil
    }

    /// Reset all settings to defaults.
    func resetToDefaults() {
        notificationsEnabled = true
        soundsEnabled = true
        launchAtLogin = false
        themePreference = .system
        serverURL = "https://api.happy.engineering"
        showOnlineStatus = true
    }

    /// Load privacy settings from server.
    func loadPrivacySettings() async {
        guard isAuthenticated else { return }

        isSyncingPrivacy = true
        privacySyncError = nil

        do {
            let settings = try await fetchPrivacySettings()
            await MainActor.run {
                // Update local cache without triggering sync
                UserDefaults.standard.set(settings.showOnlineStatus, forKey: "showOnlineStatus")
                self.isSyncingPrivacy = false
            }
        } catch {
            await MainActor.run {
                self.privacySyncError = error.localizedDescription
                self.isSyncingPrivacy = false
            }
        }
    }

    // MARK: - Private Methods

    private func updateLoginItem(enabled: Bool) {
        // TODO: Use SMAppService or LSSharedFileList to manage login items
        // This requires proper entitlements
    }

    /// Sync privacy settings to server.
    private func syncPrivacySettingsToServer() async {
        guard isAuthenticated else { return }

        await MainActor.run { isSyncingPrivacy = true }

        do {
            let settings = PrivacySettings(showOnlineStatus: showOnlineStatus)
            _ = try await updatePrivacySettings(settings)
            await MainActor.run {
                self.privacySyncError = nil
                self.isSyncingPrivacy = false
            }
        } catch {
            await MainActor.run {
                self.privacySyncError = error.localizedDescription
                self.isSyncingPrivacy = false
            }
        }
    }

    /// Fetch privacy settings from server.
    private func fetchPrivacySettings() async throws -> PrivacySettings {
        guard let token = authService.account?.token else {
            throw APIError.invalidResponse
        }

        let url = URL(string: "\(serverURL)/v1/users/me/privacy")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try JSONDecoder().decode(PrivacySettings.self, from: data)
    }

    /// Update privacy settings on server.
    private func updatePrivacySettings(_ settings: PrivacySettings) async throws -> PrivacySettings {
        guard let token = authService.account?.token else {
            throw APIError.invalidResponse
        }

        let url = URL(string: "\(serverURL)/v1/users/me/privacy")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(settings)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try JSONDecoder().decode(PrivacySettings.self, from: data)
    }
}

// MARK: - Privacy Settings (HAP-727)

/// Privacy settings structure for API communication.
struct PrivacySettings: Codable {
    let showOnlineStatus: Bool
}

// MARK: - Supporting Types

/// Available settings tabs.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case account = "Account"
    case subscription = "Subscription"
    case privacy = "Privacy"
    case notifications = "Notifications"
    case advanced = "Advanced"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .account: return "person.circle"
        case .subscription: return "creditcard"
        case .privacy: return "eye.slash"
        case .notifications: return "bell"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

/// Theme preference options.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
