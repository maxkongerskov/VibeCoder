//
//  LSPFraming.swift
//  Content-Length framed LSP/JSON-RPC wire encoding.
//

import Foundation

public enum LSPFraming {
    /// Encode a JSON body as an LSP framed message.
    public static func encode(_ body: Data) -> Data {
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    /// Decode zero or more complete framed messages from a buffer.
    /// Returns decoded JSON bodies and leftover incomplete bytes.
    public static func decode(buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { break }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8) else {
                // Corrupt header — drop a byte and continue to avoid stuck loop.
                buffer.removeFirst()
                continue
            }
            var contentLength: Int?
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "content-length" {
                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let length = contentLength, length >= 0 else {
                // Invalid/unparseable Content-Length. Strip the header and
                // skip forward to the next framed boundary. Without a valid
                // length we can't determine where the orphaned body ends, so
                // discard everything up to the next \\r\\n\\r\\n (if any) and
                // leave any leftover payload for the next read cycle.
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            let bodyEndOffset = buffer.distance(from: buffer.startIndex, to: bodyStart) + length
            guard bodyEndOffset <= buffer.count else { break }
            let bodyEnd = buffer.index(buffer.startIndex, offsetBy: bodyEndOffset)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            messages.append(body)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return messages
    }
}
