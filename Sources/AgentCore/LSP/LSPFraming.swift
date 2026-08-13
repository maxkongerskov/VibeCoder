//
//  LSPFraming.swift
//  Content-Length framed LSP/JSON-RPC wire encoding.
//

import Foundation

public enum LSPFraming {
    /// Hard cap so a hostile/corrupt Content-Length cannot pin the decoder
    /// waiting for Int.max bytes, and so header+length addition cannot trap.
    public static let maxContentLength = 64 * 1024 * 1024

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
            let bodyStart = headerEnd.upperBound
            guard let length = contentLength, length >= 0, length <= maxContentLength else {
                // Invalid, unparseable, or absurd Content-Length. Strip the
                // header so we do not wait forever / overflow on Int.max.
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let headerBytes = buffer.distance(from: buffer.startIndex, to: bodyStart)
            let (bodyEndOffset, overflow) = headerBytes.addingReportingOverflow(length)
            if overflow {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            guard bodyEndOffset <= buffer.count else { break }
            let bodyEnd = buffer.index(buffer.startIndex, offsetBy: bodyEndOffset)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            messages.append(body)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return messages
    }
}
