import Foundation
import ScriptingBridge

// Minimal typed views of Mail's scripting interface. ScriptingBridge resolves
// these members dynamically from Mail's scripting definition at runtime; the
// protocols only exist to satisfy the compiler.
@objc protocol MailApplicationSB {
    @objc optional var inbox: SBObject { get }
}

@objc protocol MailMailboxSB {
    @objc optional func messages() -> SBElementArray
}

@objc protocol MailMessageSB {
    @objc optional var id: Int { get }
    @objc optional var messageId: String { get }
    @objc optional var subject: String { get }
    @objc optional var dateReceived: Date { get }
    @objc optional func mailAttachments() -> SBElementArray
}

@objc protocol MailAttachmentSB {
    @objc optional var id: String { get }
    @objc optional var name: String { get }
    @objc optional var fileSize: Int { get }
}

extension SBApplication: MailApplicationSB {}
extension SBObject: MailMailboxSB, MailMessageSB, MailAttachmentSB {}

struct InboxAttachment {
    let id: String
    let name: String
    let fileSize: Int

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

struct InboxMessage {
    let id: Int
    let messageID: String
    let subject: String
    let dateReceived: Date
    let attachments: [InboxAttachment]
}

enum MailBridgeError: LocalizedError {
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .scriptError(let message): return message
        }
    }
}

@MainActor
enum MailBridge {

    static var isMailRunning: Bool {
        SBApplication(bundleIdentifier: "com.apple.mail")?.isRunning ?? false
    }

    // MARK: - Reading (ScriptingBridge)

    /// Snapshots inbox messages received after the given date.
    static func inboxMessages(receivedAfter date: Date) -> [InboxMessage] {
        guard let app = SBApplication(bundleIdentifier: "com.apple.mail"), app.isRunning,
              let inbox = (app as MailApplicationSB).inbox,
              let messages = (inbox as MailMailboxSB).messages?()
        else { return [] }

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

    // MARK: - Mutations (parameterized AppleScript)
    // ScriptingBridge is unreliable for Mail's save/delete/set-content
    // commands, so these go through small NSAppleScript snippets instead.

    static func saveAttachment(messageID: Int, attachmentID: String, toFolder folder: URL) throws {
        try run("""
        tell application "Mail"
            set theMessage to first message of inbox whose id is \(messageID)
            set theAttachment to first mail attachment of theMessage whose id is \(quoted(attachmentID))
            save theAttachment in ((POSIX file \(quoted(folder.path + "/"))) as alias)
        end tell
        """)
    }

    static func deleteAttachment(messageID: Int, attachmentID: String) throws {
        try run("""
        tell application "Mail"
            set theMessage to first message of inbox whose id is \(messageID)
            delete (first mail attachment of theMessage whose id is \(quoted(attachmentID)))
        end tell
        """)
    }

    static func messageContent(messageID: Int) throws -> String {
        let result = try run("""
        tell application "Mail"
            set theMessage to first message of inbox whose id is \(messageID)
            return content of theMessage
        end tell
        """)
        return result.stringValue ?? ""
    }

    static func setMessageContent(messageID: Int, content: String) throws {
        try run("""
        tell application "Mail"
            set theMessage to first message of inbox whose id is \(messageID)
            set content of theMessage to \(quoted(content))
        end tell
        """)
    }

    // MARK: - Helpers

    /// Escapes a Swift string into an AppleScript string literal.
    private static func quoted(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        + "\""
    }

    @discardableResult
    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw MailBridgeError.scriptError("Could not compile Mail script.")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown Mail scripting error."
            throw MailBridgeError.scriptError(message)
        }
        return result
    }
}
