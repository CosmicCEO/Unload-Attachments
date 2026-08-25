import Foundation

/// How saved attachments are organized under the parent folder.
nonisolated enum FolderScheme: String, CaseIterable, Identifiable {
    case byYear
    case byType

    var id: String { rawValue }

    var label: String {
        switch self {
        case .byYear: return "By Year"
        case .byType: return "By Type"
        }
    }
}

/// What happens to the original message once its slimmed copy is in place.
nonisolated enum OriginalMessagePolicy: String, CaseIterable, Identifiable {
    case archive
    case delete

    var id: String { rawValue }

    var label: String {
        switch self {
        case .archive: return "Archive to “Unloaded Originals”"
        case .delete: return "Delete Permanently"
        }
    }
}

nonisolated enum SettingsKeys {
    static let monitoringEnabled = "monitoringEnabled"
    static let pollInterval = "pollInterval"
    static let folderScheme = "folderScheme"
    static let parentFolderOverride = "parentFolderOverride"
    static let flagProcessedMessages = "flagProcessedMessages"
    static let originalsPolicy = "originalsPolicy"
    static let imapUsername = "imapUsername"
    static let imapHost = "imapHost"
    static let imapUIDValidity = "imapUIDValidity"
    static let imapLastSeenUID = "imapLastSeenUID"
}

// UserDefaults is thread-safe, so these reads are safe from any executor.
nonisolated enum AppSettings {
    static var pollInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: SettingsKeys.pollInterval)
        return value > 0 ? value : 30
    }

    static var folderScheme: FolderScheme {
        FolderScheme(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.folderScheme) ?? "") ?? .byYear
    }

    static var parentFolderOverride: URL? {
        guard let path = UserDefaults.standard.string(forKey: SettingsKeys.parentFolderOverride),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var flagProcessedMessages: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.flagProcessedMessages) as? Bool ?? true
    }

    static var originalMessagePolicy: OriginalMessagePolicy {
        OriginalMessagePolicy(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.originalsPolicy) ?? "") ?? .archive
    }

    static var imapUsername: String {
        UserDefaults.standard.string(forKey: SettingsKeys.imapUsername) ?? ""
    }

    static var imapHost: String {
        let value = UserDefaults.standard.string(forKey: SettingsKeys.imapHost) ?? ""
        return value.isEmpty ? "imap.mail.me.com" : value
    }
}
