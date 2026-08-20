import Foundation
import OSLog

nonisolated struct AttachmentRecord: Sendable {
    enum Status: Sendable {
        case saved(URL, publishedURL: URL?)
        case failed(String)
        case leftInPlace
    }

    let name: String
    let sizeText: String
    let status: Status
}

nonisolated struct ProcessResult: Sendable {
    let subject: String
    let savedCount: Int
    let failedCount: Int
    let savedFiles: [URL]
    let failureReasons: [String]
}

nonisolated enum UnloadError: LocalizedError {
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let name): return "Could not decode \(name) from the message."
        }
    }
}

/// Files extracted attachments and builds the email summary. Runs off the
/// main thread (called from MailWorker); must not touch main-actor state.
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

    // MARK: - Saving

    /// Writes decoded attachment data to its destination and returns the URL.
    static func save(data: Data, originalName: String, receivedAt date: Date) throws -> URL {
        let fileExtension = (originalName as NSString).pathExtension.lowercased()
        let destination = try destinationFolder(for: fileExtension, receivedAt: date)
        let finalName = timestamp(for: date) + "_" + cleanedFileName(originalName)
        let finalURL = uniqueURL(in: destination, fileName: finalName)
        try data.write(to: finalURL, options: [.withoutOverwriting])
        logger.notice("Saved \(finalURL.path, privacy: .public)")
        return finalURL
    }

    // MARK: - iCloud link publishing

    /// Waits for the file's iCloud upload and returns an emailable https
    /// download URL, or nil when publishing isn't possible (local folder,
    /// no iCloud, timeout). Note: published links expire after ~1 month;
    /// the location text in the summary is the permanent pointer.
    static func publishedURL(for fileURL: URL, timeout: TimeInterval = 45) async -> URL? {
        let fileManager = FileManager.default
        guard fileManager.isUbiquitousItem(at: fileURL) else { return nil }

        // Wait for the upload by quietly probing the resource key — calling
        // the publish API before the upload finishes logs system errors on
        // every attempt.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let values = try? fileURL.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
            if values?.ubiquitousItemIsUploaded == true { break }
            try? await Task.sleep(for: .seconds(2))
        }
        return try? fileManager.url(forPublishingUbiquitousItemAt: fileURL, expiration: nil)
    }

    // MARK: - Summary rendering

    static func summaryTable(for records: [AttachmentRecord]) -> String {
        let cellStyle = "padding:4px 8px; border:1px solid #ccc;"
        let headerStyle = "background:#f0f0f0; \(cellStyle) text-align:left;"

        var rows = ""
        for record in records {
            let statusText: String
            let linksText: String
            switch record.status {
            case .saved(let fileURL, let publishedURL):
                statusText = "✓ Saved &amp; removed"
                var links = "<a href='\(fileURL.absoluteString)'>Open on this Mac</a>"
                if let publishedURL {
                    links += " &nbsp;|&nbsp; <a href='\(publishedURL.absoluteString)'>Download (any device)</a>"
                }
                links += "<br><small>\(locationText(for: fileURL))</small>"
                linksText = links
            case .failed(let reason):
                statusText = "⚠ Error — left in email (\(reason))"
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

        return "<table style='border-collapse:collapse; font-family:sans-serif; font-size:12px; margin:12px 0;'>"
            + "<tr><th style='\(headerStyle)'>Attachment</th><th style='\(headerStyle)'>Size</th>"
            + "<th style='\(headerStyle)'>Status</th><th style='\(headerStyle)'>Links</th></tr>"
            + rows + "</table>"
    }

    /// Plain-text fallback. Deliberately omits the (very long) published
    /// iCloud URLs — those live only behind the HTML table's link text, so
    /// plain-text clients aren't flooded with 600-character URLs.
    static func plainSummary(for records: [AttachmentRecord]) -> String {
        var lines = ["[Unload Attachments] Attachments moved out of this email:"]
        for record in records {
            switch record.status {
            case .saved(let fileURL, _):
                lines.append("• \(record.name) (\(record.sizeText)) — \(locationText(for: fileURL))")
            case .failed(let reason):
                lines.append("• \(record.name) (\(record.sizeText)) — error, left in email: \(reason)")
            case .leftInPlace:
                lines.append("• \(record.name) (\(record.sizeText)) — left in place")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func locationText(for fileURL: URL) -> String {
        let components = fileURL.pathComponents
        if let index = components.firstIndex(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + components[(index + 1)...]).joined(separator: " ▸ ")
        }
        return fileURL.path
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
