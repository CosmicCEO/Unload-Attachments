import Foundation
import OSLog

nonisolated enum MailWorkerError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No mail account configured — choose “Mail Account…” from the menu."
        }
    }
}

/// Owns the IMAP session and the whole per-message pipeline on its own
/// executor, so network round trips never block the main thread.
actor MailWorker {

    static let shared = MailWorker()

    private static let originalsMailbox = "Unloaded Originals"

    private let client = IMAPClient()
    private let logger = Logger(subsystem: "com.jerfiss.Unload-Attachments", category: "imap")
    private var loggedIn = false
    private var originalsMailboxEnsured = false

    /// Scans the inbox for messages newer than the UID checkpoint and
    /// processes each one. Returns one result per rewritten message.
    func checkNewMail() async throws -> [ProcessResult] {
        try await ensureConnected()

        let inbox: MailboxStatus
        do {
            inbox = try await client.selectInbox()
        } catch {
            // Stale session — reconnect once, then let errors propagate.
            loggedIn = false
            try await ensureConnected()
            inbox = try await client.selectInbox()
        }

        let defaults = UserDefaults.standard
        let storedValidity = defaults.integer(forKey: SettingsKeys.imapUIDValidity)
        var lastSeen = defaults.integer(forKey: SettingsKeys.imapLastSeenUID)

        // First run (or the server reset its UID space): start from "now"
        // so mail history is never processed.
        if storedValidity != inbox.uidValidity || lastSeen == 0 {
            defaults.set(inbox.uidValidity, forKey: SettingsKeys.imapUIDValidity)
            defaults.set(max(inbox.uidNext - 1, 1), forKey: SettingsKeys.imapLastSeenUID)
            return []
        }

        let uids = try await client.uidSearch("UID \(lastSeen + 1):*")
            .filter { $0 > lastSeen }
            .sorted()

        var results: [ProcessResult] = []
        for uid in uids {
            do {
                if let result = try await process(uid: uid) {
                    results.append(result)
                }
            } catch {
                logger.error("Failed to process message UID \(uid): \(error.localizedDescription, privacy: .public)")
                results.append(ProcessResult(subject: "message \(uid)", savedCount: 0, failedCount: 1,
                                             savedFiles: [], failureReasons: [error.localizedDescription]))
            }
            lastSeen = uid
            defaults.set(lastSeen, forKey: SettingsKeys.imapLastSeenUID)
        }
        return results
    }

    // MARK: - Pipeline

    /// Full pipeline for one message. Returns nil when the message needs no
    /// processing (no Office/PDF attachments, or it's our own slimmed copy).
    private func process(uid: Int) async throws -> ProcessResult? {
        guard let fetched = try await client.uidFetchMessage(uid: uid) else { return nil }
        let message = MIMEMessage(raw: fetched.raw)

        // Never reprocess a message this app produced.
        guard message.headerValue("X-Unloaded-By") == nil else { return nil }

        let attachments = message.attachmentParts
        guard attachments.contains(where: { AttachmentUnloader.officeExtensions.contains($0.fileExtension) })
        else { return nil }

        let received = Self.parseInternalDate(fetched.internalDate) ?? Date()
        let formatter = ByteCountFormatter()

        var records: [AttachmentRecord] = []
        var savedFiles: [URL] = []
        var failureReasons: [String] = []
        var removedPaths: Set<[Int]> = []
        var savedCount = 0
        var failedCount = 0

        for attachment in attachments {
            let data = attachment.decodedData
            let sizeText = formatter.string(fromByteCount: Int64(data?.count ?? 0))

            guard AttachmentUnloader.officeExtensions.contains(attachment.fileExtension) else {
                records.append(AttachmentRecord(name: attachment.filename, sizeText: sizeText, status: .leftInPlace))
                continue
            }

            do {
                guard let data else { throw UnloadError.extractionFailed(attachment.filename) }
                let fileURL = try AttachmentUnloader.save(data: data, originalName: attachment.filename, receivedAt: received)
                let published = await AttachmentUnloader.publishedURL(for: fileURL)
                records.append(AttachmentRecord(name: attachment.filename, sizeText: sizeText,
                                                status: .saved(fileURL, publishedURL: published)))
                removedPaths.insert(attachment.path)
                savedFiles.append(fileURL)
                savedCount += 1
            } catch {
                let reason = "\(attachment.filename): \(error.localizedDescription)"
                logger.error("Failed to unload \(reason, privacy: .public)")
                records.append(AttachmentRecord(name: attachment.filename, sizeText: sizeText,
                                                status: .failed(error.localizedDescription)))
                failureReasons.append(reason)
                failedCount += 1
            }
        }

        if savedCount > 0 {
            let slimmed = message.rebuiltRemoving(
                paths: removedPaths,
                summaryHTML: AttachmentUnloader.summaryTable(for: records),
                summaryPlain: AttachmentUnloader.plainSummary(for: records))

            var flags = fetched.flags
            if AppSettings.flagProcessedMessages && !flags.contains("\\Flagged") {
                flags.append("\\Flagged")
            }

            switch AppSettings.originalMessagePolicy {
            case .archive:
                // Preserve the original before anything replaces it.
                try await ensureOriginalsMailbox()
                try await client.uidMove(uid: uid, to: Self.originalsMailbox)
                try await client.append(mailbox: "INBOX", flags: flags,
                                        internalDate: fetched.internalDate, message: slimmed)
            case .delete:
                // Only remove the original once the slimmed copy is safely stored.
                try await client.append(mailbox: "INBOX", flags: flags,
                                        internalDate: fetched.internalDate, message: slimmed)
                try await client.uidDelete(uid: uid)
            }
        }

        return ProcessResult(subject: message.subject, savedCount: savedCount, failedCount: failedCount,
                             savedFiles: savedFiles, failureReasons: failureReasons)
    }

    // MARK: - Push (IDLE)

    /// Suspends inside IMAP IDLE until the inbox changes or the window
    /// elapses. Returns false when push isn't available (not connected, or
    /// the connection dropped) so the caller can fall back to interval polling.
    func waitForNewMail(window: TimeInterval) async -> Bool {
        guard loggedIn else { return false }
        do {
            try await client.idleWait(maxSeconds: window)
            return true
        } catch {
            logger.notice("IDLE ended: \(error.localizedDescription, privacy: .public)")
            loggedIn = false
            await client.disconnect()
            return false
        }
    }

    /// Ends the current IDLE wait early so a fresh check runs immediately.
    func wakeIdle() async {
        await client.interruptIdle()
    }

    // MARK: - Session

    private func ensureConnected() async throws {
        if loggedIn, (try? await client.noop()) != nil { return }
        loggedIn = false
        originalsMailboxEnsured = false

        let username = AppSettings.imapUsername
        guard !username.isEmpty, let password = KeychainStore.password(account: username) else {
            throw MailWorkerError.notConfigured
        }
        try await client.connect(host: AppSettings.imapHost, username: username, password: password)
        loggedIn = true
    }

    private func ensureOriginalsMailbox() async throws {
        guard !originalsMailboxEnsured else { return }
        await client.ensureMailbox(Self.originalsMailbox)
        originalsMailboxEnsured = true
    }

    // MARK: - Helpers

    /// Parses an IMAP INTERNALDATE like `20-Aug-2026 09:48:12 -0500`.
    private static func parseInternalDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }
}
