import Foundation
import Network

nonisolated enum IMAPError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case server(String)
    case badResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the mail server."
        case .connectionFailed(let detail): return "Connection failed: \(detail)"
        case .server(let detail): return "The mail server rejected the request: \(detail)"
        case .badResponse(let detail): return "Unexpected server response: \(detail)"
        case .cancelled: return "The connection was cancelled."
        }
    }
}

/// One logical IMAP response line. `{N}` literals are collected in order into
/// `literals`; the marker text remains in `text` at the position it occurred.
nonisolated struct IMAPResponse: Sendable {
    let text: String
    let literals: [Data]
}

nonisolated struct MailboxStatus: Sendable {
    let uidValidity: Int
    let uidNext: Int
    let messageCount: Int
}

/// Resumes a continuation exactly once even if NWConnection fires its state
/// handler multiple times.
private final class Resumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Minimal IMAP4rev1 client over TLS. Implements only the commands this app
/// needs, against a single well-behaved server (iCloud Mail).
actor IMAPClient {

    private var connection: NWConnection?
    private var buffer = Data()
    private var tagCounter = 0

    var isConnected: Bool { connection != nil }

    // MARK: - Session

    func connect(host: String, username: String, password: String) async throws {
        disconnect()

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 993, using: .tls)
        connection = conn
        buffer.removeAll()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = Resumer(continuation)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.resume(with: .success(()))
                case .failed(let error):
                    resumer.resume(with: .failure(IMAPError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    resumer.resume(with: .failure(IMAPError.cancelled))
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "com.jerfiss.unload-attachments.imap"))
        }
        conn.stateUpdateHandler = nil

        let greeting = try await readResponse()
        guard greeting.text.hasPrefix("* OK") || greeting.text.hasPrefix("* PREAUTH") else {
            throw IMAPError.badResponse(greeting.text)
        }

        try await command("LOGIN \(quoted(username)) \(quoted(password))")
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        disconnect()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    func noop() async throws {
        try await command("NOOP")
    }

    // MARK: - Mailboxes

    func selectInbox() async throws -> MailboxStatus {
        try await select(mailbox: "INBOX")
    }

    func select(mailbox: String) async throws -> MailboxStatus {
        let responses = try await command("SELECT \(quoted(mailbox))")
        var uidValidity = 0
        var uidNext = 0
        var messageCount = 0
        for response in responses {
            if let value = firstInt(in: response.text, pattern: #"UIDVALIDITY (\d+)"#) { uidValidity = value }
            if let value = firstInt(in: response.text, pattern: #"UIDNEXT (\d+)"#) { uidNext = value }
            if let value = firstInt(in: response.text, pattern: #"^\* (\d+) EXISTS"#) { messageCount = value }
        }
        return MailboxStatus(uidValidity: uidValidity, uidNext: uidNext, messageCount: messageCount)
    }

    // MARK: - Command plumbing

    /// Sends a tagged command and collects untagged responses until the
    /// tagged completion. Throws on NO/BAD.
    @discardableResult
    func command(_ text: String) async throws -> [IMAPResponse] {
        tagCounter += 1
        let tag = String(format: "A%04d", tagCounter)
        try await send("\(tag) \(text)\r\n")

        var responses: [IMAPResponse] = []
        while true {
            let response = try await readResponse()
            if response.text.hasPrefix("\(tag) ") {
                let status = String(response.text.dropFirst(tag.count + 1))
                if status.hasPrefix("OK") {
                    responses.append(response)
                    return responses
                }
                throw IMAPError.server(status)
            }
            responses.append(response)
        }
    }

    // MARK: - Wire I/O

    private func send(_ text: String) async throws {
        try await sendRaw(Data(text.utf8))
    }

    private func sendRaw(_ data: Data) async throws {
        guard let connection else { throw IMAPError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    /// Reads one logical response line, transparently consuming `{N}` literals.
    private func readResponse() async throws -> IMAPResponse {
        var text = ""
        var literals: [Data] = []
        while true {
            let line = try await readLine()
            text += line
            if let size = trailingLiteralSize(of: line) {
                literals.append(try await readBytes(size))
                continue
            }
            return IMAPResponse(text: text, literals: literals)
        }
    }

    /// Returns N when the line ends with an IMAP literal marker `{N}`.
    private func trailingLiteralSize(of line: String) -> Int? {
        guard line.hasSuffix("}"),
              let openBrace = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: openBrace)..<line.index(before: line.endIndex)])
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            try await receiveMore()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await receiveMore()
        }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    private func receiveMore() async throws {
        guard let connection else { throw IMAPError.notConnected }
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: IMAPError.connectionFailed("The server closed the connection."))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
        buffer.append(chunk)
    }

    // MARK: - Helpers

    /// IMAP quoted-string form.
    private func quoted(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
    }

    private func firstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }
}
