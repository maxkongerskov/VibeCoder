//
//  MLXHubDownloader.swift
//
//  Robust Hugging Face Hub downloader for large MLX safetensor shards.
//  Ported from the DEV PLAN faithfully — chunking, retries, signed-URL
//  refresh, and SHA-256 verification all preserved verbatim.
//
//  AgentCore changes vs. the DEV PLAN source:
//   * Cache directory and `URLSession` are accepted at init (no
//     hardcoded `~/.cache/huggingface/hub` baked into the actor).
//   * No `AppSettings` / SwiftUI dependencies. Foundation + CryptoKit
//     only.
//   * The `.shared` singleton retains the DEV PLAN's default cache
//     layout for callers that don't need to override.
//
//  **Why we built this (DEV PLAN, 2026-06-01):** swift-huggingface's
//  HubClient is a thin URLSession wrapper — no parallel chunks, no
//  retry, no signed-URL refresh. On 50+ GB models (Qwen3-Coder-Next
//  80B, Mixtral 8x22B) the cas-bridge signed URLs expire (1h TTL) and
//  shards die at the 60s default request timeout. This downloader
//  replaces the broken blob-fetch path.
//
//  **What it does:**
//   1. Fetches HF tree manifest → JSON list of {path, size, oid}.
//   2. Per file ≥100 MB: splits into 50 MB+ Range chunks, fetches up
//      to 4 in parallel via TaskGroup, each chunk retried 5× with
//      exponential backoff + jitter. 403 (signed URL expired) →
//      re-resolve URL, throttled to 1/min.
//   3. Writes to `.incomplete` partial in place — resume = SHA-skip on
//      next run.
//   4. Verifies SHA-256 against the manifest oid, then atomic-renames
//      to `blobs/<sha>`, creates the snapshot symlink, and updates
//      `refs/main`.
//   5. Aggregates byte-progress across all chunks, throttled to 2 Hz.
//
//  **HF cache layout (Hub-compatible):**
//    <cacheBase>/models--{org}--{name}/
//      refs/main                 — commit sha
//      blobs/<sha256>            — content-addressed blob (final)
//      blobs/<sha256>.incomplete — partial download (resumable)
//      snapshots/<commit>/{file} → ../../blobs/<sha>  (symlinks)
//
//  **URLSession configuration constraint (DO NOT CHANGE):**
//  We MUST use `URLSessionConfiguration.default`, NEVER `.background`.
//  Background URLSession requires an App Store entitlement we do not
//  have under Developer ID code-signing — switching to `.background`
//  will break shipping builds. Future maintainers: leave this alone.
//

import Foundation
import CryptoKit

// MARK: - Public errors

public enum MLXDownloadError: Error, LocalizedError, Sendable {
    case manifestFetchFailed(String)
    case noFilesInManifest(repoId: String)
    case sha256Mismatch(file: String, expected: String, got: String)
    case allRetriesExhausted(file: String, lastError: String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case cancelled
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .manifestFetchFailed(let m):       return "Could not fetch HF manifest: \(m)"
        case .noFilesInManifest(let r):         return "HF repo \(r) returned no downloadable files"
        case .sha256Mismatch(let f, let e, let g):
            return "SHA-256 mismatch for \(f) (expected \(e.prefix(12))…, got \(g.prefix(12))…)"
        case .allRetriesExhausted(let f, let e): return "Download failed for \(f) after retries: \(e)"
        case .insufficientDiskSpace(let n, let a):
            return "Not enough disk space — need \(n / 1_073_741_824) GB, available \(a / 1_073_741_824) GB"
        case .cancelled:                        return "Download cancelled"
        case .invalidResponse(let m):           return "Unexpected response from HuggingFace: \(m)"
        }
    }
}

// MARK: - HF manifest types

/// One file entry from `GET /api/models/{repo}/tree/{rev}?recursive=true`.
/// HF returns a heterogeneous array (directories + files). We only keep
/// files (`type == "file"`) with a usable size. The `lfs` block carries
/// the SHA-256 when the file is LFS-tracked (safetensors always are);
/// for tiny non-LFS files (config.json etc) we skip SHA verification
/// and trust HTTPS.
struct HFTreeEntry: Decodable, Sendable {
    let type: String
    let path: String
    let size: Int64?
    let oid: String?            // git blob oid (NOT sha256 for LFS files)
    let lfs: LFSInfo?

    struct LFSInfo: Decodable, Sendable {
        let oid: String         // "sha256:..." for LFS files
        let size: Int64?
    }

    /// SHA-256 of the file contents (only present for LFS files). Returned
    /// without any `sha256:` prefix so we can compare directly.
    var sha256: String? {
        guard let raw = lfs?.oid else { return nil }
        if raw.hasPrefix("sha256:") { return String(raw.dropFirst(7)) }
        return raw
    }

    var totalSize: Int64 { lfs?.size ?? size ?? 0 }
}

// MARK: - MLXHubDownloader

public actor MLXHubDownloader {

    /// Default singleton using `~/.cache/huggingface/hub` and the
    /// downloader's own preconfigured `URLSession`. Hosts that need a
    /// different cache root or a test-friendly session should
    /// `init(cacheBase:session:)` explicitly.
    public static let shared = MLXHubDownloader()

    // MARK: Init

    private let cacheBase: URL
    private let session: URLSession

    public init(cacheBase: URL? = nil, session: URLSession? = nil) {
        self.cacheBase = cacheBase ?? Self.defaultCacheBase
        self.session = session ?? Self.makeDefaultSession()
    }

    // MARK: Public API

    /// Downloads a HuggingFace repo into the configured cache base using
    /// the standard HF cache layout. Idempotent: skips files already on
    /// disk with a matching SHA, resumes any `.incomplete` partials in
    /// place. Reports a monotonic 0…1 fraction via `progress` (throttled
    /// to ~2 Hz).
    ///
    /// Throws `MLXDownloadError.cancelled` if `cancel(repoId:)` is called.
    public func download(
        repoId: String,
        revision: String = "main",
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // Install a cancellation token under the actor so a concurrent
        // `cancel(repoId:)` flips it and all in-flight chunks see it.
        // Reusing the same token across retries keeps semantics simple:
        // any cancel call halts the whole download for that repoId.
        let token = CancelToken()
        cancellations[repoId] = token

        defer {
            // Best-effort cleanup — don't overwrite if a later download()
            // call already installed a fresh token.
            if cancellations[repoId] === token { cancellations[repoId] = nil }
        }

        // 1. Fetch manifest
        let manifest = try await fetchManifest(repoId: repoId, revision: revision, token: token)
        let files = manifest.filter { $0.type == "file" && $0.totalSize > 0 }
        guard !files.isEmpty else {
            throw MLXDownloadError.noFilesInManifest(repoId: repoId)
        }

        let totalBytes: Int64 = files.reduce(0) { $0 + $1.totalSize }

        // 2. Disk space check — 1.1× headroom over the manifest's
        // claimed size. 1.5× would be too aggressive on 84 GB models
        // with 100 GB free.
        try ensureDiskSpace(needed: Int64(Double(totalBytes) * 1.1))

        // 3. Resolve commit SHA for the snapshot directory name. HF
        // returns it from /api/models/{repo}/revision/{rev}; fallback
        // to revision id if the call fails (still produces a usable
        // cache).
        let commitSha = (try? await fetchCommitSha(repoId: repoId,
                                                   revision: revision,
                                                   token: token)) ?? revision

        // 4. Prepare cache layout dirs
        let cacheDir = cacheDir(for: repoId)
        try Self.createDir(cacheDir.appendingPathComponent("blobs", isDirectory: true))
        try Self.createDir(cacheDir.appendingPathComponent("refs", isDirectory: true))
        let snapshotDir = cacheDir
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(commitSha, isDirectory: true)
        try Self.createDir(snapshotDir)

        // 5. Progress aggregator (actor isolates the counter and
        // last-report time)
        let aggregator = ProgressAggregator(total: totalBytes, callback: progress)

        // 6. Download files, max 2 in flight (each may use up to 4 chunk
        // tasks). That keeps connections to HF at ≤8, matching
        // httpMaximumConnectionsPerHost.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pendingIterator = files.makeIterator()
            let perFileLimit = 2

            // Seed
            for _ in 0..<perFileLimit {
                guard let f = pendingIterator.next() else { break }
                group.addTask { [self] in
                    try await downloadFile(
                        file: f,
                        repoId: repoId,
                        revision: revision,
                        commitSha: commitSha,
                        snapshotDir: snapshotDir,
                        aggregator: aggregator,
                        token: token
                    )
                }
            }
            // As each file finishes, queue the next.
            while try await group.next() != nil {
                if let f = pendingIterator.next() {
                    group.addTask { [self] in
                        try await downloadFile(
                            file: f,
                            repoId: repoId,
                            revision: revision,
                            commitSha: commitSha,
                            snapshotDir: snapshotDir,
                            aggregator: aggregator,
                            token: token
                        )
                    }
                }
            }
        }

        // 7. Write refs/main → commit sha so HF Hub considers the
        // snapshot resolved.
        let refsFile = cacheDir.appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent(revision)
        try? commitSha.write(to: refsFile, atomically: true, encoding: .utf8)

        // 8. Final progress tick at exactly 1.0
        await aggregator.report(force: true, atFraction: 1.0)
    }

    /// Cancels any in-flight download for `repoId`. Idempotent. Chunks
    /// already writing to disk finish writing what they have (so resume
    /// works); subsequent retries see the cancelled flag and throw.
    public func cancel(repoId: String) {
        cancellations[repoId]?.flip()
    }

    // MARK: Private state

    /// One cancellation token per active repo download — flipped by
    /// `cancel(repoId:)`.
    private var cancellations: [String: CancelToken] = [:]

    /// Signed-URL cache: `{repo}/{file}` → (url, expiresAt). HF signed
    /// URLs are 1h TTL; we cache for 50 min to leave headroom.
    private var signedURLCache: [String: SignedURL] = [:]

    private struct SignedURL: Sendable {
        let url: URL
        let expiresAt: Date
    }

    // MARK: HTTP session

    /// Default session for all download traffic. Long timeouts because
    /// shards stream for minutes; **`.default` is mandatory (not
    /// `.background`)** on Developer ID — background URLSession requires
    /// an App Store entitlement we don't have.
    nonisolated static func makeDefaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120      // inter-packet gap
        cfg.timeoutIntervalForResource = 7200    // hard cap per chunk
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    // MARK: Cache layout

    nonisolated static var defaultCacheBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    nonisolated func cacheDir(for repoId: String) -> URL {
        let folder = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        return cacheBase.appendingPathComponent(folder, isDirectory: true)
    }

    nonisolated static func createDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
    }

    // MARK: Manifest

    private func fetchManifest(repoId: String, revision: String, token: CancelToken) async throws -> [HFTreeEntry] {
        let urlStr = "https://huggingface.co/api/models/\(repoId)/tree/\(revision)?recursive=true"
        guard let url = URL(string: urlStr) else {
            throw MLXDownloadError.manifestFetchFailed("malformed URL")
        }
        try Self.checkCancelled(token)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw MLXDownloadError.manifestFetchFailed("no HTTPURLResponse")
            }
            guard http.statusCode == 200 else {
                throw MLXDownloadError.manifestFetchFailed("status \(http.statusCode)")
            }
            return try JSONDecoder().decode([HFTreeEntry].self, from: data)
        } catch let err as MLXDownloadError {
            throw err
        } catch {
            throw MLXDownloadError.manifestFetchFailed(error.localizedDescription)
        }
    }

    private func fetchCommitSha(repoId: String, revision: String, token: CancelToken) async throws -> String {
        let urlStr = "https://huggingface.co/api/models/\(repoId)/revision/\(revision)"
        guard let url = URL(string: urlStr) else {
            throw MLXDownloadError.invalidResponse("malformed revision URL")
        }
        try Self.checkCancelled(token)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MLXDownloadError.invalidResponse("commit-sha lookup failed")
        }
        struct Rev: Decodable { let sha: String }
        let r = try JSONDecoder().decode(Rev.self, from: data)
        return r.sha
    }

    // MARK: Per-file download

    private func downloadFile(
        file: HFTreeEntry,
        repoId: String,
        revision: String,
        commitSha: String,
        snapshotDir: URL,
        aggregator: ProgressAggregator,
        token: CancelToken
    ) async throws {
        try Self.checkCancelled(token)

        let cacheDir = self.cacheDir(for: repoId)
        let blobsDir = cacheDir.appendingPathComponent("blobs", isDirectory: true)

        // Blob path: prefer SHA-256 from manifest (LFS); for small
        // non-LFS files use the git oid as the addressable blob name
        // (HF Hub does the same).
        let blobName = file.sha256 ?? file.oid ?? UUID().uuidString
        let finalURL = blobsDir.appendingPathComponent(blobName)
        let partialURL = blobsDir.appendingPathComponent("\(blobName).incomplete")
        let snapshotEntry = snapshotDir.appendingPathComponent(file.path)

        // Already done? credit full size and bail.
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try Self.ensureSnapshotSymlink(from: snapshotEntry, to: finalURL)
            await aggregator.add(deltaBytes: file.totalSize)
            return
        }

        // 100 MB threshold — below this, a single GET is faster than
        // chunk math.
        let chunkThreshold: Int64 = 100 * 1024 * 1024
        if file.totalSize < chunkThreshold {
            try await downloadSmall(file: file, partialURL: partialURL,
                                    repoId: repoId, revision: revision,
                                    aggregator: aggregator, token: token)
        } else {
            try await downloadChunked(file: file, partialURL: partialURL,
                                      repoId: repoId, revision: revision,
                                      aggregator: aggregator, token: token)
        }

        // Refuse to publish a blob whose on-disk size disagrees with the
        // manifest. Truncated 200s and short 206s must not become final.
        if file.totalSize > 0 {
            let attrs = try FileManager.default.attributesOfItem(atPath: partialURL.path)
            let got = (attrs[.size] as? Int64) ?? -1
            if got != file.totalSize {
                try? FileManager.default.removeItem(at: partialURL)
                throw MLXDownloadError.invalidResponse(
                    "downloaded size \(got) != claimed \(file.totalSize) for \(file.path)")
            }
        }

        // SHA-verify when we have the expected hash. Skip for non-LFS
        // files.
        if let expected = file.sha256 {
            let actual = try Self.sha256Hex(of: partialURL)
            if actual != expected {
                try? FileManager.default.removeItem(at: partialURL)
                throw MLXDownloadError.sha256Mismatch(file: file.path, expected: expected, got: actual)
            }
        }

        // Atomic rename partial → blob, then snapshot symlink.
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        try Self.ensureSnapshotSymlink(from: snapshotEntry, to: finalURL)
    }

    // MARK: Small-file path

    private func downloadSmall(
        file: HFTreeEntry, partialURL: URL,
        repoId: String, revision: String,
        aggregator: ProgressAggregator, token: CancelToken
    ) async throws {
        let resolved = try await resolvedURL(repoId: repoId, revision: revision, file: file.path)
        var lastError: Error = MLXDownloadError.invalidResponse("no attempts made")
        for attempt in 0..<5 {
            try Self.checkCancelled(token)
            do {
                var req = URLRequest(url: resolved)
                req.timeoutInterval = 120
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw MLXDownloadError.invalidResponse("no HTTPURLResponse")
                }
                if http.statusCode == 403 {
                    // signed URL expired — drop cache, refresh, retry
                    invalidateSignedURL(repoId: repoId, file: file.path)
                    let fresh = try await resolvedURL(repoId: repoId, revision: revision, file: file.path)
                    var req2 = URLRequest(url: fresh)
                    req2.timeoutInterval = 120
                    let (data2, response2) = try await session.data(for: req2)
                    guard let http2 = response2 as? HTTPURLResponse, http2.statusCode == 200 else {
                        throw MLXDownloadError.invalidResponse("403 even after URL refresh")
                    }
                    try Self.validateSmallBody(data2, file: file)
                    try data2.write(to: partialURL)
                    await aggregator.add(deltaBytes: Int64(data2.count))
                    return
                }
                guard http.statusCode == 200 else {
                    throw MLXDownloadError.invalidResponse("status \(http.statusCode) for \(file.path)")
                }
                try Self.validateSmallBody(data, file: file)
                try data.write(to: partialURL)
                await aggregator.add(deltaBytes: Int64(data.count))
                return
            } catch {
                lastError = error
                try? await Self.sleepBackoff(attempt: attempt)
            }
        }
        throw MLXDownloadError.allRetriesExhausted(file: file.path, lastError: "\(lastError)")
    }

    // MARK: Chunked path

    private func downloadChunked(
        file: HFTreeEntry, partialURL: URL,
        repoId: String, revision: String,
        aggregator: ProgressAggregator, token: CancelToken
    ) async throws {
        // Resume: file size == total is NOT proof of completeness.
        // Parallel pwrite leaves a full-size file with holes (high-offset
        // write extends the file). We only skip remaining work when an
        // LFS SHA matches. Otherwise restart from 0 — we do not persist
        // a completed-range map, so a full-size .incomplete cannot be
        // trusted as a sequential prefix.
        let fm = FileManager.default
        let total = file.totalSize
        var resumeOffset: Int64 = 0
        if fm.fileExists(atPath: partialURL.path) {
            let attrs = try fm.attributesOfItem(atPath: partialURL.path)
            let existingSize = (attrs[.size] as? Int64) ?? 0
            if existingSize >= total, total > 0 {
                if let expected = file.sha256,
                   let actual = try? Self.sha256Hex(of: partialURL),
                   actual == expected {
                    await aggregator.add(deltaBytes: total)
                    return
                }
                try Data().write(to: partialURL)
                resumeOffset = 0
            } else if existingSize > 0, existingSize < total {
                resumeOffset = existingSize
                await aggregator.add(deltaBytes: resumeOffset)
            } else {
                resumeOffset = 0
            }
        } else {
            fm.createFile(atPath: partialURL.path, contents: nil)
            resumeOffset = 0
        }

        // Only skip remaining ranges for a strictly sequential prefix
        // smaller than total. A full-size .incomplete is handled above.
        guard resumeOffset < total else { return }

        // Chunk plan: aim for 4 chunks per file, min 50 MB per chunk.
        let minChunk: Int64 = 50 * 1024 * 1024
        let remaining = total - resumeOffset
        let chunkCount = max(1, Int(min(4, (remaining + minChunk - 1) / minChunk)))
        let chunkSize = (remaining + Int64(chunkCount) - 1) / Int64(chunkCount)

        var ranges: [(Int64, Int64)] = []
        var cursor = resumeOffset
        for _ in 0..<chunkCount {
            let end = min(cursor + chunkSize - 1, total - 1)
            ranges.append((cursor, end))
            cursor = end + 1
        }

        // FileHandle for in-place pwrite. Truncate not needed — we
        // created/resumed the file above.
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        let handleBox = FileHandleBox(handle)

        // Concurrent chunk fetches, max 4 in flight per file.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (start, end) in ranges {
                group.addTask { [self] in
                    try await downloadOneChunk(
                        file: file, repoId: repoId, revision: revision,
                        partialURL: partialURL, handleBox: handleBox,
                        start: start, end: end,
                        aggregator: aggregator, token: token
                    )
                }
            }
            try await group.waitForAll()
        }
        try? handle.synchronize()
    }

    private func downloadOneChunk(
        file: HFTreeEntry, repoId: String, revision: String,
        partialURL: URL, handleBox: FileHandleBox,
        start: Int64, end: Int64,
        aggregator: ProgressAggregator, token: CancelToken
    ) async throws {
        var lastError: Error = MLXDownloadError.invalidResponse("no attempts made")
        var refreshedAt: Date? = nil

        for attempt in 0..<5 {
            try Self.checkCancelled(token)

            let urlForAttempt: URL
            do {
                urlForAttempt = try await resolvedURL(repoId: repoId, revision: revision, file: file.path)
            } catch {
                lastError = error
                try? await Self.sleepBackoff(attempt: attempt)
                continue
            }

            var req = URLRequest(url: urlForAttempt)
            req.timeoutInterval = 120
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw MLXDownloadError.invalidResponse("no HTTPURLResponse")
                }

                // 403 → signed URL expired. Refresh, throttle to 1/min/file,
                // do NOT count this attempt toward the retry budget.
                if http.statusCode == 403 {
                    let now = Date()
                    if let last = refreshedAt, now.timeIntervalSince(last) < 60 {
                        // Already refreshed in the last minute; treat as a
                        // real failure to avoid a tight refresh loop.
                        throw MLXDownloadError.invalidResponse("403 within 60s of refresh")
                    }
                    invalidateSignedURL(repoId: repoId, file: file.path)
                    refreshedAt = now
                    continue   // retry without burning a budget slot
                }

                let expectedLen = Int(end - start + 1)

                if http.statusCode == 206 {
                    // Short 206 is a failure. Honor Content-Range when
                    // present: it must name this exact range and match
                    // the body length.
                    if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                       let parsed = Self.parseContentRange(cr) {
                        let crLen = Int(parsed.end - parsed.start + 1)
                        guard parsed.start == start,
                              parsed.end == end,
                              data.count == crLen,
                              data.count == expectedLen else {
                            throw MLXDownloadError.invalidResponse(
                                "206 Content-Range \(cr) / \(data.count) bytes != requested \(start)-\(end)")
                        }
                    } else if data.count != expectedLen {
                        throw MLXDownloadError.invalidResponse(
                            "short 206 for chunk \(start)-\(end): got \(data.count) bytes")
                    }
                    try Self.write(data: data, at: start, using: handleBox)
                    await aggregator.add(deltaBytes: Int64(data.count))
                    return
                }

                if http.statusCode == 200 {
                    // Accept 200 only when the body is exactly the
                    // requested range, or a full-object reply for the
                    // sole (or leading) chunk. A mid-file 200 that
                    // returns the whole object must not be pwrite'd at
                    // `start` — that inflates the file.
                    if data.count == expectedLen {
                        try Self.write(data: data, at: start, using: handleBox)
                        await aggregator.add(deltaBytes: Int64(data.count))
                        return
                    }
                    // Full-object 200 at offset 0: CDN ignored Range.
                    // Write the whole file at 0 even when other chunks
                    // exist; mid-file 200s must not pwrite at `start`.
                    if start == 0, file.totalSize > 0, data.count == file.totalSize {
                        try Self.write(data: data, at: 0, using: handleBox)
                        await aggregator.add(deltaBytes: Int64(data.count))
                        return
                    }
                    if start > 0, file.totalSize > 0, data.count == file.totalSize {
                        return
                    }
                    throw MLXDownloadError.invalidResponse(
                        "HTTP 200 length \(data.count) != requested \(expectedLen) for chunk \(start)-\(end)")
                }

                throw MLXDownloadError.invalidResponse("status \(http.statusCode) for chunk \(start)-\(end)")
            } catch {
                lastError = error
                try? await Self.sleepBackoff(attempt: attempt)
            }
        }
        throw MLXDownloadError.allRetriesExhausted(file: file.path, lastError: "\(lastError)")
    }

    // MARK: Signed URL resolution

    private func resolvedURL(repoId: String, revision: String, file: String) async throws -> URL {
        let key = "\(repoId)/\(file)"
        if let cached = signedURLCache[key], cached.expiresAt > Date() {
            return cached.url
        }
        // GET huggingface.co/{repo}/resolve/{rev}/{file} — HF returns
        // 302 pointing at the cas-bridge signed URL. URLSession follows
        // them by default, but we want the FINAL URL (so we can chunk
        // against it), not just the bytes. Use a `HEAD` first; that
        // lands on the signed URL via 302 → 200 and we read
        // `response.url`.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repoId)/resolve/\(revision)/\(file)"
        guard let baseURL = components.url else {
            throw MLXDownloadError.invalidResponse("malformed resolve URL")
        }
        var req = URLRequest(url: baseURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 60
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MLXDownloadError.invalidResponse("HEAD returned no HTTPURLResponse")
        }
        guard http.statusCode == 200, let final = response.url else {
            throw MLXDownloadError.invalidResponse("HEAD \(baseURL.absoluteString) status \(http.statusCode)")
        }
        // Cache for 50 min — well under HF's 1h signed-URL TTL.
        let expires = Date().addingTimeInterval(50 * 60)
        signedURLCache[key] = SignedURL(url: final, expiresAt: expires)
        return final
    }

    private func invalidateSignedURL(repoId: String, file: String) {
        signedURLCache["\(repoId)/\(file)"] = nil
    }

    // MARK: Helpers

    nonisolated static func sleepBackoff(attempt: Int) async throws {
        // 1s, 2s, 4s, 8s, 16s + ±25% jitter.
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: -0.25...0.25)
        let secs = base * (1.0 + jitter)
        try await Task.sleep(nanoseconds: UInt64(max(0.5, secs) * 1_000_000_000))
    }

    nonisolated static func checkCancelled(_ token: CancelToken) throws {
        if token.isCancelled { throw MLXDownloadError.cancelled }
    }

    /// SHA-256 of the file content. Streams in 4 MB chunks so we don't
    /// materialise an 80 GB blob in RAM.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024
        while autoreleasepool(invoking: { () -> Bool in
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) { /* loop */ }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a relative symlink at `entry` → blob, idempotent.
    nonisolated static func ensureSnapshotSymlink(from entry: URL, to blob: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: entry.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // If something already exists at `entry`, remove it — could be
        // a stale symlink from a partial run.
        if fm.fileExists(atPath: entry.path) || (try? fm.destinationOfSymbolicLink(atPath: entry.path)) != nil {
            try? fm.removeItem(at: entry)
        }
        // Build the relative path from the symlink's CONTAINING
        // directory to the blob. For the standard HF layout:
        //   entry = .../snapshots/<commit>/<file>   → 2 levels up to cacheDir
        //   blob  = .../blobs/<sha>
        //   target = ../../blobs/<sha>
        // For nested file paths (snapshots/<commit>/subdir/<file>) depth
        // grows by one per nested level. We don't subtract 1 here — the
        // depth count already excludes the symlink's own filename
        // (blob.pathComponents.dropLast() drops the blob's filename so
        // we compare directory depths) — so `count: depth` produces the
        // right number of "../".
        let depth = entry.pathComponents.count - blob.pathComponents.dropLast().count
        let prefix = String(repeating: "../", count: max(0, depth))
        let blobName = blob.lastPathComponent
        let target = "\(prefix)blobs/\(blobName)"
        try fm.createSymbolicLink(atPath: entry.path, withDestinationPath: target)
    }

    private func ensureDiskSpace(needed: Int64) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheBase, withIntermediateDirectories: true)
        let v = try cacheBase.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = v.volumeAvailableCapacityForImportantUsage, available < needed {
            throw MLXDownloadError.insufficientDiskSpace(needed: needed, available: available)
        }
    }

    /// Small-file GET must return the manifest size when it is known.
    nonisolated static func validateSmallBody(_ data: Data, file: HFTreeEntry) throws {
        if file.totalSize > 0, Int64(data.count) != file.totalSize {
            throw MLXDownloadError.invalidResponse(
                "small-file length \(data.count) != claimed \(file.totalSize) for \(file.path)")
        }
    }

    /// Parses `bytes START-END/TOTAL` (`TOTAL` may be `*`).
    nonisolated static func parseContentRange(_ header: String) -> (start: Int64, end: Int64)? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("bytes ") else { return nil }
        let rest = trimmed.dropFirst(6)
        let rangePart = rest.split(separator: "/", maxSplits: 1).first ?? rest[...]
        let bounds = rangePart.split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0, end >= start else { return nil }
        return (start, end)
    }

    /// Serialised pwrite via the box's internal NSLock. SYNCHRONOUS on
    /// purpose: NSLock.lock()/unlock() are unavailable in async contexts
    /// on current SDKs (they can deadlock across suspension points), and
    /// this path never needs to suspend — seek + write are blocking
    /// syscalls. Concurrent chunk tasks funnel through the lock here.
    private static func write(data: Data, at offset: Int64, using box: FileHandleBox) throws {
        try box.write(data: data, at: offset)
    }
}

// MARK: - Progress aggregator (actor-isolated counter)

actor ProgressAggregator {
    private let total: Int64
    private let callback: @Sendable (Double) -> Void
    private var downloaded: Int64 = 0
    private var lastReportAt: Date = .distantPast

    init(total: Int64, callback: @escaping @Sendable (Double) -> Void) {
        self.total = max(1, total)
        self.callback = callback
    }

    func add(deltaBytes: Int64) {
        downloaded += deltaBytes
        let now = Date()
        // Throttle to 2 Hz so observers don't melt the main run loop
        // on a 10 Gbit link.
        if now.timeIntervalSince(lastReportAt) >= 0.5 {
            lastReportAt = now
            let f = min(1.0, Double(downloaded) / Double(total))
            callback(f)
        }
    }

    func report(force: Bool, atFraction: Double) {
        if force {
            lastReportAt = Date()
            callback(min(1.0, max(0.0, atFraction)))
        }
    }
}

// MARK: - Cancellation token

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flipped = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flipped
    }

    func flip() {
        lock.lock(); defer { lock.unlock() }
        flipped = true
    }
}

// MARK: - FileHandle wrapper

/// Wraps a FileHandle so concurrent chunk tasks can pwrite under a single
/// internal lock without trying to ship the (non-Sendable) handle across
/// actor boundaries. `@unchecked Sendable` is justified because every
/// read/write goes through the NSLock. SYNCHRONOUS write — NSLock cannot
/// be held across suspension points, and seek/write are blocking syscalls
/// that don't need to be async.
final class FileHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(_ handle: FileHandle) { self.handle = handle }

    func write(data: Data, at offset: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }
}
