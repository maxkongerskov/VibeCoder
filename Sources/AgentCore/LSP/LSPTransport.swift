//
//  LSPTransport.swift
//  Duplex byte transport for LSP JSON-RPC (process pipes or mock).
//

import Foundation

/// Minimal duplex transport. Implementations must be safe for concurrent send;
/// receive is driven by the client reader loop.
public protocol LSPTransport: Sendable {
    func write(_ data: Data) async throws
    /// Read available bytes (may block until data or EOF). Empty Data = EOF.
    func read() async throws -> Data
    func close() async
}

/// In-memory transport for unit tests.
///
/// Scripted responses are released **one per client request** (JSON body with
/// an `id`). Notifications (no `id`) do not consume a response. This avoids
/// races where a pre-queued response is read before the client registers
/// its pending continuation.
public actor MockLSPTransport: LSPTransport {
    private var writeLog: [Data] = []
    private var responseQueue: [Data] = []
    private var deliverable: [Data] = []
    private var pendingReads: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    public init() {}

    /// Enqueue a framed LSP message body (use `LSPFraming.encode`).
    public func enqueueResponse(_ data: Data) {
        responseQueue.append(data)
    }

    public func enqueueJSONResponse(_ object: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        enqueueResponse(LSPFraming.encode(body))
    }

    public func writtenBodies() -> [Data] {
        writeLog.compactMap { raw -> Data? in
            var buf = raw
            return LSPFraming.decode(buffer: &buf).first
        }
    }

    public func write(_ data: Data) async throws {
        if closed { throw LSPError.transportClosed }
        writeLog.append(data)
        // Only pair responses with real JSON-RPC requests (have `id`).
        if messageHasRequestId(data), !responseQueue.isEmpty {
            let next = responseQueue.removeFirst()
            if let cont = pendingReads.first {
                pendingReads.removeFirst()
                cont.resume(returning: next)
            } else {
                deliverable.append(next)
            }
        }
    }

    public func read() async throws -> Data {
        if closed { return Data() }
        if !deliverable.isEmpty {
            return deliverable.removeFirst()
        }
        return try await withCheckedThrowingContinuation { cont in
            pendingReads.append(cont)
        }
    }

    public func close() async {
        closed = true
        let waiters = pendingReads
        pendingReads.removeAll()
        for w in waiters {
            w.resume(returning: Data())
        }
    }

    private func messageHasRequestId(_ data: Data) -> Bool {
        var buf = data
        guard let body = LSPFraming.decode(buffer: &buf).first,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              obj["id"] != nil else {
            return false
        }
        return true
    }
}
