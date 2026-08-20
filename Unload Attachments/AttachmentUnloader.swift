import Foundation
import OSLog

nonisolated struct ProcessResult: Sendable {
    let subject: String
    let savedCount: Int
    let failedCount: Int
    let savedFiles: [URL]
    let failureReasons: [String]
}

/// Pure helpers for extracting and filing attachments. Runs off the main
/// thread (called from MailWorker); must not touch main-actor state.
nonisolated enum AttachmentUnloader {

    private static let logger = Logger(subsystem: "com.jerfiss.Unload-Attachments", category: "unloader")

    /// File types that are saved out of incoming messages.
    static let officeExtensions: Set<String> = ["xls", "xlsx", "doc", "docx", "ppt", "pptx", "pdf"]

    private static let typeFolderNames: [String: String] = [
        "pdf": "pdf",
        "doc": "word", "docx": "word",
        "xls": "excel", "xlsx": "excel",
        "ppt": "powerpoint", "pptx": "powerpoint",
    ]

    // MARK: - Folders

    /// iCloud Drive ▸ Documents, or nil when iCloud Drive is unavailable.
    static var iCloudDriveDocumentsURL: URL? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return root.appendingPathComponent("Documents", isDirectory: true)
    }

    /// The parent folder that holds all unloaded attachments. Prefers the
    /// user-chosen override, then iCloud Drive, then local Documents (which
    /// is itself iCloud-synced when Desktop & Documents sync is on).
    static var parentFolder: URL {
        if let override = AppSettings.parentFolderOverride { return override }
        if let icloud = iCloudDriveDocumentsURL {
            return icloud.appendingPathComponent("unloader-files", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/unloader-files", isDirectory: true)
    }

    /// First-launch setup: make sure the parent folder exists.
    @discardableResult
    static func ensureFoldersExist() throws -> URL {
        try FileManager.default.createDirectory(at: parentFolder, withIntermediateDirectories: true)
        return parentFolder
    }

    /// Subfolder for one file according to the active organization scheme.
    static func destinationFolder(for fileExtension: String, receivedAt date: Date) throws -> URL {
        let subfolder: String
        switch AppSettings.folderScheme {
        case .byYear:
            subfolder = String(Calendar.current.component(.year, from: date))
        case .byType:
            subfolder = typeFolderNames[fileExtension] ?? fileExtension
        }
        let folder = parentFolder.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Processing

    /// Extracts each Office/PDF attachment from the raw message source and
    /// writes it to the destination folder.
    static func process(_ message: InboxMessage, source: String) -> ProcessResult {
        var savedCount = 0
        var failedCount = 0
        var savedFiles: [URL] = []
        var failureReasons: [String] = []

        for attachment in message.attachments where officeExtensions.contains(attachment.fileExtension) {
            do {
                let destination = try destinationFolder(for: attachment.fileExtension, receivedAt: message.dateReceived)
                guard let data = MIMEExtractor.attachmentData(named: attachment.name, inSource: source) else {
                    throw MailBridgeError.scriptError("Could not extract \(attachment.name) from the raw message.")
                }

                let finalName = timestamp(for: message.dateReceived) + "_" + cleanedFileName(attachment.name)
                let finalURL = uniqueURL(in: destination, fileName: finalName)
                try data.write(to: finalURL, options: [.withoutOverwriting])

                logger.notice("Saved \(finalURL.path, privacy: .public)")
                savedFiles.append(finalURL)
                savedCount += 1
            } catch {
                let reason = "\(attachment.name): \(error.localizedDescription)"
                logger.error("Failed to unload \(reason, privacy: .public)")
                failureReasons.append(reason)
                failedCount += 1
            }
        }

        return ProcessResult(subject: message.subject, savedCount: savedCount,
                             failedCount: failedCount, savedFiles: savedFiles,
                             failureReasons: failureReasons)
    }

    // MARK: - Naming

    /// Removes the characters the original AppleScript disallowed, including spaces.
    static func cleanedFileName(_ name: String) -> String {
        let disallowed = Set(":;,'/|!@#$%^&*()- ")
        let cleaned = String(name.filter { !disallowed.contains($0) })
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: date)
    }

    private static func uniqueURL(in folder: URL, fileName: String) -> URL {
        var candidate = folder.appendingPathComponent(fileName)
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = folder.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}
