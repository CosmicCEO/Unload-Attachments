import Foundation
import OSLog

struct AttachmentRecord {
    enum Status {
        case saved(URL, publishedURL: URL?, removed: Bool)
        case failed(String)
        case leftInPlace
    }

    let name: String
    let sizeText: String
    let status: Status
}

struct ProcessResult {
    let subject: String
    let savedCount: Int
    let failedCount: Int
    let failureReasons: [String]
}

@MainActor
enum AttachmentUnloader {

    private static let logger = Logger(subsystem: "com.jerfiss.Unload-Attachments", category: "unloader")

    /// File types that are saved out of the message and removed from it.
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
    /// user-chosen override, then iCloud Drive, then local Documents.
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

    /// Saves each Office/PDF attachment of the message to the destination
    /// folder, removes it from the message, and prepends an HTML summary
    /// table with links to the saved files.
    static func process(_ message: InboxMessage) async -> ProcessResult {
        let formatter = ByteCountFormatter()
        var records: [AttachmentRecord] = []
        var savedCount = 0
        var failedCount = 0
        var failureReasons: [String] = []
        var messageSourceCache: String?

        for attachment in message.attachments {
            let sizeText = formatter.string(fromByteCount: Int64(attachment.fileSize))
            guard officeExtensions.contains(attachment.fileExtension) else {
                records.append(AttachmentRecord(name: attachment.name, sizeText: sizeText, status: .leftInPlace))
                continue
            }

            do {
                let destination = try destinationFolder(for: attachment.fileExtension, receivedAt: message.dateReceived)

                // Mail saves with the attachment's original name, so stage in
                // a private temp folder to avoid clobbering earlier saves.
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("unloader-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }

                let stagedFile = staging.appendingPathComponent(attachment.name)
                do {
                    try MailBridge.saveAttachment(messageID: message.id, attachmentID: attachment.id, toFile: stagedFile)
                } catch {
                    // Mail's scripted save is broken on modern macOS (-10000);
                    // extract the attachment from the raw message source instead.
                    logger.notice("Scripted save failed for \(attachment.name, privacy: .public); extracting from raw source")
                    if messageSourceCache == nil {
                        messageSourceCache = try MailBridge.messageSource(messageID: message.id)
                    }
                    guard let source = messageSourceCache,
                          let data = MIMEExtractor.attachmentData(named: attachment.name, inSource: source) else {
                        throw MailBridgeError.scriptError("Could not extract \(attachment.name) from the raw message.")
                    }
                    try data.write(to: stagedFile)
                }
                guard FileManager.default.fileExists(atPath: stagedFile.path) else {
                    throw MailBridgeError.scriptError("Mail did not write \(attachment.name).")
                }

                let finalName = timestamp(for: message.dateReceived) + "_" + cleanedFileName(attachment.name)
                let finalURL = uniqueURL(in: destination, fileName: finalName)
                try FileManager.default.moveItem(at: stagedFile, to: finalURL)

                // The file is safe now — a removal failure downgrades the row
                // instead of losing the save.
                var removed = true
                do {
                    try MailBridge.deleteAttachment(messageID: message.id, attachmentID: attachment.id)
                } catch {
                    removed = false
                    let reason = "\(attachment.name) was saved, but could not be removed from the email: \(error.localizedDescription)"
                    logger.error("\(reason, privacy: .public)")
                    failureReasons.append(reason)
                }

                let published = await publishedURL(for: finalURL)
                records.append(AttachmentRecord(name: attachment.name, sizeText: sizeText,
                                                status: .saved(finalURL, publishedURL: published, removed: removed)))
                savedCount += 1
            } catch {
                let reason = "\(attachment.name): \(error.localizedDescription)"
                logger.error("Failed to unload \(reason, privacy: .public)")
                failureReasons.append(reason)
                records.append(AttachmentRecord(name: attachment.name, sizeText: sizeText,
                                                status: .failed(error.localizedDescription)))
                failedCount += 1
            }
        }

        if savedCount > 0 {
            let original = (try? MailBridge.messageContent(messageID: message.id)) ?? ""
            let table = summaryTable(for: records)
            do {
                try MailBridge.setMessageContent(messageID: message.id, content: table + "<br>" + original)
            } catch {
                let reason = "Could not add the summary table to the email: \(error.localizedDescription)"
                logger.error("\(reason, privacy: .public)")
                failureReasons.append(reason)
            }
        }

        return ProcessResult(subject: message.subject, savedCount: savedCount,
                             failedCount: failedCount, failureReasons: failureReasons)
    }

    // MARK: - iCloud link publishing

    /// Waits for the file's iCloud upload and returns an emailable https
    /// download URL, or nil when publishing isn't possible (local folder,
    /// no iCloud, timeout).
    static func publishedURL(for fileURL: URL, timeout: TimeInterval = 45) async -> URL? {
        let fileManager = FileManager.default
        guard fileManager.isUbiquitousItem(at: fileURL) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                return try fileManager.url(forPublishingUbiquitousItemAt: fileURL, expiration: nil)
            } catch {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        return nil
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

    // MARK: - HTML summary

    private static func summaryTable(for records: [AttachmentRecord]) -> String {
        let cellStyle = "padding:4px 8px; border:1px solid #ccc;"
        let headerStyle = "background:#f0f0f0; \(cellStyle) text-align:left;"

        var rows = ""
        for record in records {
            let statusText: String
            let linksText: String
            switch record.status {
            case .saved(let fileURL, let publishedURL, let removed):
                statusText = removed ? "✓ Saved & removed" : "✓ Saved — attachment left in email"
                var links = "<a href='\(fileURL.absoluteString)'>Open on this Mac</a>"
                if let publishedURL {
                    links += " &nbsp;|&nbsp; <a href='\(publishedURL.absoluteString)'>Download (any device)</a>"
                }
                links += "<br><small>\(locationText(for: fileURL))</small>"
                linksText = links
            case .failed(let reason):
                statusText = "⚠ Error — not removed (\(reason))"
                linksText = ""
            case .leftInPlace:
                statusText = "— left in place"
                linksText = ""
            }
            rows += "<tr><td style='\(cellStyle)'>\(record.name)</td>"
                + "<td style='\(cellStyle)'>\(record.sizeText)</td>"
                + "<td style='\(cellStyle)'>\(statusText)</td>"
                + "<td style='\(cellStyle)'>\(linksText)</td></tr>"
        }

        return "<table style='border-collapse:collapse; font-family:sans-serif; font-size:12px; margin-bottom:12px;'>"
            + "<tr><th style='\(headerStyle)'>Attachment</th><th style='\(headerStyle)'>Size</th>"
            + "<th style='\(headerStyle)'>Status</th><th style='\(headerStyle)'>Links</th></tr>"
            + rows + "</table>"
    }

    private static func locationText(for fileURL: URL) -> String {
        let components = fileURL.pathComponents
        if let index = components.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + components[(index + 1)...]).joined(separator: " ▸ ")
        }
        return fileURL.path
    }
}
