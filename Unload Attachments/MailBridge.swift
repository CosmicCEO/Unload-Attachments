import Foundation
import ScriptingBridge

// Minimal typed views of Mail's scripting interface. ScriptingBridge resolves
// these members dynamically from Mail's scripting definition at runtime; the
// protocols only exist to satisfy the compiler.
@objc nonisolated protocol MailApplicationSB {
    @objc optional var inbox: SBObject { get }
}

@objc nonisolated protocol MailMailboxSB {
    @objc optional func messages() -> SBElementArray
}

@objc nonisolated protocol MailMessageSB {
    @objc optional var id: Int { get }
    @objc optional var messageId: String { get }
    @objc optional var subject: String { get }
    @objc optional var dateReceived: Date { get }
    @objc optional var source: String { get }
    @objc optional var flaggedStatus: Bool { get }
    @objc optional func setFlaggedStatus(_ flagged: Bool)
    @objc optional func setFlagIndex(_ index: Int)
    @objc optional func mailAttachments() -> SBElementArray
}

@objc nonisolated protocol MailAttachmentSB {
    @objc optional var id: String { get }
    @objc optional var name: String { get }
    @objc optional var fileSize: Int { get }
}

extension SBApplication: MailApplicationSB {}
extension SBObject: MailMailboxSB, MailMessageSB, MailAttachmentSB {}

nonisolated struct InboxAttachment: Sendable {
    let id: String
    let name: String
    let fileSize: Int

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

nonisolated struct InboxMessage: Sendable {
    let id: Int
    let messageID: String
    let subject: String
    let dateReceived: Date
    let attachments: [InboxAttachment]
}

nonisolated enum MailBridgeError: LocalizedError {
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .scriptError(let message): return message
        }
    }
}

/// Owns all ScriptingBridge access to Mail on its own executor, so Apple-event
/// round trips (which can take seconds on a large inbox) never block the main
/// thread and the menu bar UI.
actor MailWorker {

    static let shared = MailWorker()

    func isMailRunning() -> Bool {
        SBApplication(bundleIdentifier: "com.apple.mail")?.isRunning ?? false
    }

    /// Snapshots inbox messages received after the given date.
    func newMessages(receivedAfter date: Date) -> [InboxMessage] {
        guard let messages = inboxMessagesArray() else { return [] }

        let recent = messages.filtered(using: NSPredicate(format: "dateReceived > %@", date as NSDate))

        var result: [InboxMessage] = []
        for case let message as SBObject in recent {
            let m = message as MailMessageSB
            guard let id = m.id, let received = m.dateReceived else { continue }

            var attachments: [InboxAttachment] = []
            if let sbAttachments = m.mailAttachments?() {
                for case let attachment as SBObject in sbAttachments {
                    let a = attachment as MailAttachmentSB
                    guard let attachmentID = a.id, let name = a.name else { continue }
                    attachments.append(InboxAttachment(id: attachmentID, name: name, fileSize: a.fileSize ?? 0))
                }
            }

            result.append(InboxMessage(
                id: id,
                messageID: m.messageId ?? String(id),
                subject: m.subject ?? "(no subject)",
                dateReceived: received,
                attachments: attachments
            ))
        }
        return result.sorted { $0.dateReceived < $1.dateReceived }
    }

    /// Saves the message's Office/PDF attachments and reports the outcome.
    /// The message itself is never modified: modern Mail rejects all scripted
    /// modifications of received messages, so attachments are extracted from
    /// the raw message source instead.
    func unload(_ message: InboxMessage) -> ProcessResult {
        guard let source = messageSource(messageID: message.id), !source.isEmpty else {
            let reason = "Could not read the raw source of “\(message.subject)” from Mail."
            return ProcessResult(subject: message.subject, savedCount: 0, failedCount: 1,
                                 savedFiles: [], failureReasons: [reason])
        }
        return AttachmentUnloader.process(message, source: source)
    }

    /// Flags the message (green) to show its attachments were unloaded.
    /// Flag status is message metadata, which Mail still allows scripts to
    /// change — unlike message content. Returns false if Mail rejected it.
    func flagMessage(messageID: Int) -> Bool {
        guard let message = inboxMessage(withID: messageID) else { return false }
        let m = message as MailMessageSB
        m.setFlaggedStatus?(true)
        m.setFlagIndex?(3) // green
        // ScriptingBridge setters fail silently, so read back to verify.
        return m.flaggedStatus ?? false
    }

    // MARK: - Private

    private func inboxMessage(withID messageID: Int) -> SBObject? {
        guard let messages = inboxMessagesArray() else { return nil }
        let matches = messages.filtered(using: NSPredicate(format: "id == %d", messageID))
        return matches.first as? SBObject
    }

    private func inboxMessagesArray() -> SBElementArray? {
        guard let app = SBApplication(bundleIdentifier: "com.apple.mail"), app.isRunning,
              let inbox = (app as MailApplicationSB).inbox
        else { return nil }
        return (inbox as MailMailboxSB).messages?()
    }

    private func messageSource(messageID: Int) -> String? {
        guard let message = inboxMessage(withID: messageID) else { return nil }
        return (message as MailMessageSB).source
    }
}
