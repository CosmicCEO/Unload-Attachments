import Foundation

/// One node of a parsed MIME message. Header and body text are kept verbatim
/// (LF-normalized) so untouched parts are reproduced byte-for-byte on rebuild.
nonisolated struct MIMEPart: Sendable {
    var headerText: String
    var bodyText: String
    var subparts: [MIMEPart]
    var boundary: String?
    var preamble: String
    var epilogue: String

    var isMultipart: Bool { boundary != nil }

    func headerValue(_ name: String) -> String? { MIME.headerValue(name, in: headerText) }

    var contentType: String { headerValue("Content-Type") ?? "text/plain" }

    var mediaType: String {
        contentType.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
    }

    var transferEncoding: String {
        (headerValue("Content-Transfer-Encoding") ?? "7bit")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    var filename: String? {
        if let disposition = headerValue("Content-Disposition"),
           let name = MIME.parameter("filename", in: disposition) { return name }
        if let name = MIME.parameter("name", in: contentType) { return name }
        return nil
    }

    /// Decoded body bytes for a leaf part.
    var decodedBody: Data? {
        switch transferEncoding {
        case "base64":
            return Data(base64Encoded: bodyText, options: .ignoreUnknownCharacters)
        case "quoted-printable":
            return MIME.decodeQuotedPrintable(bodyText)
        default:
            return bodyText.data(using: .isoLatin1) ?? Data(bodyText.utf8)
        }
    }

    /// Decoded body as text using the part's declared charset.
    var decodedText: String? {
        guard let data = decodedBody else { return nil }
        let charset = (MIME.parameter("charset", in: contentType) ?? "utf-8").lowercased()
        let encoding: String.Encoding
        switch charset {
        case "utf-8", "us-ascii": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }
}

/// A parsed RFC 822 message that can be rebuilt with attachment parts removed
/// and a summary injected — while preserving every original header (including
/// Message-ID, In-Reply-To, and References, so threading survives).
nonisolated struct MIMEMessage: Sendable {

    let root: MIMEPart

    init(raw: Data) {
        let text = (String(data: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self))
            .replacingOccurrences(of: "\r\n", with: "\n")
        if let split = text.range(of: "\n\n") {
            root = MIME.parsePart(headerText: String(text[..<split.lowerBound]),
                                  bodyText: String(text[split.upperBound...]))
        } else {
            root = MIME.parsePart(headerText: text, bodyText: "")
        }
    }

    func headerValue(_ name: String) -> String? { root.headerValue(name) }

    var subject: String {
        MIME.decodeEncodedWords(headerValue("Subject") ?? "(no subject)")
    }

    struct AttachmentPart: Sendable {
        let path: [Int]
        let filename: String
        let part: MIMEPart

        var fileExtension: String { (filename as NSString).pathExtension.lowercased() }
        var decodedData: Data? { part.decodedBody }
    }

    /// All leaf parts that carry a filename, with their tree position.
    var attachmentParts: [AttachmentPart] {
        var found: [AttachmentPart] = []
        collect(root, path: [], into: &found)
        return found
    }

    private func collect(_ part: MIMEPart, path: [Int], into found: inout [AttachmentPart]) {
        if part.isMultipart {
            for (index, sub) in part.subparts.enumerated() {
                collect(sub, path: path + [index], into: &found)
            }
        } else if let filename = part.filename {
            found.append(AttachmentPart(path: path, filename: MIME.decodeEncodedWords(filename), part: part))
        }
    }

    // MARK: - Rebuild

    /// Returns the raw message without the given parts and with the summary
    /// injected at the top of the body. All original headers are preserved
    /// verbatim; only `X-Unloaded-By` is added.
    func rebuiltRemoving(paths: Set<[Int]>, summaryHTML: String, summaryPlain: String) -> Data {
        var newRoot: MIMEPart

        if let kept = Self.removing(part: root, path: [], toRemove: paths), Self.hasLeaf(kept) {
            newRoot = kept
            let htmlPath = Self.firstTextLeafPath(ofType: "text/html", in: newRoot, path: [])
            let plainPath = Self.firstTextLeafPath(ofType: "text/plain", in: newRoot, path: [])

            if let htmlPath {
                // The message already has an HTML alternative — inject the
                // table there, and a short note into the plain part if present.
                Self.mutateLeaf(at: htmlPath, of: &newRoot) { leaf in
                    let original = leaf.decodedText ?? ""
                    let combined: String
                    if let bodyTag = original.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                        combined = original.replacingCharacters(in: bodyTag, with: original[bodyTag] + summaryHTML)
                    } else {
                        combined = summaryHTML + original
                    }
                    Self.replaceContent(of: &leaf, type: "text/html", text: combined)
                }
                if let plainPath {
                    Self.mutateLeaf(at: plainPath, of: &newRoot) { leaf in
                        let original = leaf.decodedText ?? ""
                        Self.replaceContent(of: &leaf, type: "text/plain", text: summaryPlain + "\n\n" + original)
                    }
                }
            } else if let plainPath, !plainPath.isEmpty {
                // Plain-text-only body: upgrade it to multipart/alternative so
                // the formatted table renders, keeping a clean plain fallback.
                Self.mutateLeaf(at: plainPath, of: &newRoot) { leaf in
                    let original = leaf.decodedText ?? ""
                    let html = summaryHTML
                        + "<pre style=\"font-family:-apple-system,sans-serif; white-space:pre-wrap;\">"
                        + Self.escapeHTML(original) + "</pre>"
                    leaf = Self.alternativePart(plainText: summaryPlain + "\n\n" + original, htmlText: html)
                }
            } else if newRoot.isMultipart {
                // Parts kept but no text body — add the summary as an HTML part.
                newRoot.subparts.insert(Self.htmlLeaf(summaryHTML), at: 0)
            } else {
                Self.replaceContent(of: &newRoot, type: "text/html", text: summaryHTML)
            }
        } else {
            // The message body consisted only of the removed attachment(s):
            // replace the body with the summary itself.
            newRoot = root
            newRoot.subparts = []
            newRoot.boundary = nil
            newRoot.preamble = ""
            newRoot.epilogue = ""
            Self.replaceContent(of: &newRoot, type: "text/html", text: summaryHTML)
        }

        newRoot.headerText += "\nX-Unloaded-By: Unload Attachments"

        let text = MIME.serialize(newRoot).replacingOccurrences(of: "\n", with: "\r\n")
        return text.data(using: .isoLatin1) ?? Data(text.utf8)
    }

    private static func removing(part: MIMEPart, path: [Int], toRemove: Set<[Int]>) -> MIMEPart? {
        if toRemove.contains(path) { return nil }
        guard part.isMultipart else { return part }
        var copy = part
        copy.subparts = part.subparts.enumerated().compactMap {
            removing(part: $0.element, path: path + [$0.offset], toRemove: toRemove)
        }
        return copy
    }

    private static func hasLeaf(_ part: MIMEPart) -> Bool {
        guard part.isMultipart else { return true }
        return part.subparts.contains { hasLeaf($0) }
    }

    private static func firstTextLeafPath(ofType type: String, in part: MIMEPart, path: [Int]) -> [Int]? {
        if part.isMultipart {
            for (index, sub) in part.subparts.enumerated() {
                if let found = firstTextLeafPath(ofType: type, in: sub, path: path + [index]) { return found }
            }
            return nil
        }
        return (part.mediaType == type && part.filename == nil) ? path : nil
    }

    private static func mutateLeaf(at path: [Int], of part: inout MIMEPart, _ mutate: (inout MIMEPart) -> Void) {
        if path.isEmpty {
            mutate(&part)
            return
        }
        var sub = part.subparts[path[0]]
        mutateLeaf(at: Array(path.dropFirst()), of: &sub, mutate)
        part.subparts[path[0]] = sub
    }

    /// Re-types a leaf as UTF-8 base64 content — the only header surgery the
    /// rebuild performs, and only on the text part receiving the summary.
    private static func replaceContent(of leaf: inout MIMEPart, type: String, text: String) {
        leaf.headerText = MIME.replacingContentHeaders(in: leaf.headerText,
                                                       contentType: "\(type); charset=utf-8",
                                                       transferEncoding: "base64")
        leaf.bodyText = MIME.base64Body(text)
    }

    /// A standalone UTF-8 base64 body part of the given media type.
    private static func leaf(type: String, text: String) -> MIMEPart {
        MIMEPart(headerText: "Content-Type: \(type); charset=utf-8\nContent-Transfer-Encoding: base64",
                 bodyText: MIME.base64Body(text),
                 subparts: [], boundary: nil, preamble: "", epilogue: "")
    }

    private static func htmlLeaf(_ html: String) -> MIMEPart {
        leaf(type: "text/html", text: html)
    }

    /// A `multipart/alternative` wrapping a plain-text and an HTML rendering.
    private static func alternativePart(plainText: String, htmlText: String) -> MIMEPart {
        let boundary = "Unload-Alt-\(UUID().uuidString)"
        return MIMEPart(headerText: "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
                        bodyText: "",
                        subparts: [leaf(type: "text/plain", text: plainText), htmlLeaf(htmlText)],
                        boundary: boundary, preamble: "", epilogue: "")
    }

    private static func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Low-level MIME utilities shared by the parser and rebuilder.
nonisolated enum MIME {

    // MARK: - Parsing

    static func parsePart(headerText: String, bodyText: String) -> MIMEPart {
        let contentType = headerValue("Content-Type", in: headerText) ?? "text/plain"
        guard contentType.lowercased().contains("multipart/"),
              let boundary = parameter("boundary", in: contentType) else {
            return MIMEPart(headerText: headerText, bodyText: bodyText,
                            subparts: [], boundary: nil, preamble: "", epilogue: "")
        }

        let marker = "--" + boundary
        var preamble = ""
        var epilogue = ""
        var chunks: [String] = []
        var current = ""
        var state = 0 // 0 = preamble, 1 = inside parts, 2 = epilogue

        func finishChunk() {
            chunks.append(current.hasSuffix("\n") ? String(current.dropLast()) : current)
            current = ""
        }

        for line in bodyText.components(separatedBy: "\n") {
            // .whitespacesAndNewlines: boundary lines may carry stray CRs.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == marker {
                if state == 1 { finishChunk() }
                state = 1
            } else if trimmed == marker + "--" {
                if state == 1 { finishChunk() }
                state = 2
            } else {
                switch state {
                case 0: preamble += line + "\n"
                case 1: current += line + "\n"
                default: epilogue += line + "\n"
                }
            }
        }
        // A truncated message may lack its closing boundary — keep the chunk.
        if state == 1 && !current.isEmpty { finishChunk() }

        guard !chunks.isEmpty else {
            // Declared multipart but no boundaries found — treat as a leaf so
            // the rebuild reproduces it untouched.
            return MIMEPart(headerText: headerText, bodyText: bodyText,
                            subparts: [], boundary: nil, preamble: "", epilogue: "")
        }

        let subparts = chunks.map { chunk -> MIMEPart in
            if let split = chunk.range(of: "\n\n") {
                return parsePart(headerText: String(chunk[..<split.lowerBound]),
                                 bodyText: String(chunk[split.upperBound...]))
            }
            return parsePart(headerText: chunk, bodyText: "")
        }

        return MIMEPart(headerText: headerText, bodyText: "", subparts: subparts,
                        boundary: boundary, preamble: preamble, epilogue: epilogue)
    }

    static func serialize(_ part: MIMEPart) -> String {
        guard let boundary = part.boundary else {
            return part.headerText + "\n\n" + part.bodyText
        }
        var out = part.headerText + "\n\n" + part.preamble
        for sub in part.subparts {
            out += "--\(boundary)\n" + serialize(sub) + "\n"
        }
        out += "--\(boundary)--\n" + part.epilogue
        return out
    }

    // MARK: - Headers

    static func headerValue(_ name: String, in headerText: String) -> String? {
        var value: String?
        for line in headerText.components(separatedBy: "\n") {
            if value != nil {
                if line.first == " " || line.first == "\t" {
                    value! += " " + line.trimmingCharacters(in: .whitespaces)
                    continue
                }
                return value
            }
            if let colon = line.firstIndex(of: ":"),
               line[..<colon].caseInsensitiveCompare(name) == .orderedSame {
                value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    /// Extracts a header parameter, handling quoted values, bare tokens, and
    /// single-segment RFC 2231 extended syntax (`name*=charset''pct-encoded`).
    static func parameter(_ name: String, in headerValue: String) -> String? {
        if let raw = firstCapture(in: headerValue, pattern: "(?i)(?:^|[;\\s])\(name)\\*=\"?([^\";]+)\"?") {
            let pieces = raw.components(separatedBy: "'")
            let encoded = pieces.count >= 3 ? pieces[2...].joined(separator: "'") : raw
            return encoded.removingPercentEncoding ?? encoded
        }
        if let quoted = firstCapture(in: headerValue, pattern: "(?i)(?:^|[;\\s])\(name)=\"([^\"]*)\"") {
            return decodeEncodedWords(quoted)
        }
        if let bare = firstCapture(in: headerValue, pattern: "(?i)(?:^|[;\\s])\(name)=([^;\\s]+)") {
            return decodeEncodedWords(bare)
        }
        return nil
    }

    /// Removes Content-Type / Content-Transfer-Encoding / Content-Disposition
    /// (with their folded continuation lines) and appends fresh ones.
    static func replacingContentHeaders(in headerText: String,
                                        contentType: String,
                                        transferEncoding: String) -> String {
        var lines: [String] = []
        var skipping = false
        for line in headerText.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t" {
                if !skipping { lines.append(line) }
                continue
            }
            let lowered = line.lowercased()
            skipping = lowered.hasPrefix("content-type:")
                || lowered.hasPrefix("content-transfer-encoding:")
                || lowered.hasPrefix("content-disposition:")
            if !skipping { lines.append(line) }
        }
        lines.append("Content-Type: \(contentType)")
        lines.append("Content-Transfer-Encoding: \(transferEncoding)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Encodings

    static func base64Body(_ text: String) -> String {
        Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
    }

    /// Decodes RFC 2047 encoded-words (=?charset?B/Q?...?=) within a string.
    static func decodeEncodedWords(_ text: String) -> String {
        guard text.contains("=?"),
              let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#) else { return text }
        var result = text
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let whole = Range(match.range, in: result),
              let charsetRange = Range(match.range(at: 1), in: result),
              let kindRange = Range(match.range(at: 2), in: result),
              let payloadRange = Range(match.range(at: 3), in: result) {
            let charset = result[charsetRange].lowercased()
            let isBase64 = result[kindRange].uppercased() == "B"
            let payload = String(result[payloadRange])
            let data = isBase64
                ? Data(base64Encoded: payload)
                : decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
            let encoding: String.Encoding = charset.contains("8859") ? .isoLatin1 : .utf8
            let decoded = data.flatMap { String(data: $0, encoding: encoding) } ?? "?"
            result.replaceSubrange(whole, with: decoded)
        }
        return result
    }

    static func decodeQuotedPrintable(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        var result = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "=") {
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2]) {
                    result.append(high << 4 | low)
                    index += 3
                } else if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") {
                    index += 2 // soft line break
                } else {
                    index += 1
                }
            } else if bytes[index] == UInt8(ascii: "\n") {
                result.append(contentsOf: [0x0D, 0x0A])
                index += 1
            } else {
                result.append(bytes[index])
                index += 1
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

    static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
