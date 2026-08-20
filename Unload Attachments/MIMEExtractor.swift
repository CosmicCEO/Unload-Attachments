import Foundation

/// Extracts attachment data from a raw RFC 822 message source. Mail's
/// scripted `save` command fails with "AppleEvent handler failed" (-10000)
/// on modern macOS versions, so this is how attachments are saved.
nonisolated enum MIMEExtractor {

    /// Finds the MIME part whose filename matches and returns its decoded data.
    static func attachmentData(named fileName: String, inSource source: String) -> Data? {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        // Find the header line that names this attachment
        // (Content-Disposition: ... filename="X" or Content-Type: ... name="X").
        guard let nameLineIndex = lines.firstIndex(where: { line in
            let lowered = line.lowercased()
            return (lowered.contains("filename") || lowered.contains("name=")) && line.contains(fileName)
        }) else { return nil }

        // Walk back to this part's boundary line, then forward through its
        // headers to the blank line, noting the transfer encoding.
        var partStart = nameLineIndex
        while partStart > 0 && !lines[partStart].hasPrefix("--") { partStart -= 1 }

        var encoding = "base64"
        var index = partStart
        while index < lines.count && !lines[index].isEmpty {
            let lowered = lines[index].lowercased()
            if lowered.hasPrefix("content-transfer-encoding:") {
                encoding = lowered
                    .replacingOccurrences(of: "content-transfer-encoding:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            index += 1
        }
        guard index < lines.count else { return nil }

        // Collect the body until the next boundary. Base64's alphabet never
        // starts a line with "--", so this cleanly stops at the boundary.
        var bodyLines: [String] = []
        index += 1
        while index < lines.count && !lines[index].hasPrefix("--") {
            bodyLines.append(lines[index])
            index += 1
        }

        switch encoding {
        case "base64":
            return Data(base64Encoded: bodyLines.joined(), options: .ignoreUnknownCharacters)
        case "quoted-printable":
            return decodeQuotedPrintable(bodyLines.joined(separator: "\n"))
        case "7bit", "8bit", "binary", "":
            return bodyLines.joined(separator: "\n").data(using: .utf8)
        default:
            return nil
        }
    }

    private static func decodeQuotedPrintable(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        var result = Data()
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "=") {
                if i + 2 < bytes.count, let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                    result.append(high << 4 | low)
                    i += 3
                } else if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\n") {
                    i += 2 // soft line break
                } else {
                    i += 1
                }
            } else if bytes[i] == UInt8(ascii: "\n") {
                result.append(contentsOf: [0x0D, 0x0A])
                i += 1
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
