import CryptoKit
import XCTest
@testable import AgentCore

/// Verification-first audit of `MLXHubDownloader` download correctness.
/// Uses a `URLProtocol` stub so we exercise the real actor, not a reimplementation.
final class MLXHubDownloaderDownloadAuditTests: XCTestCase {

    final class MockHFProtocol: URLProtocol {
        struct Response {
            var status: Int
            var headers: [String: String]
            var body: Data
        }

        nonisolated(unsafe) static var handler: ((URLRequest) throws -> Response)?
        nonisolated(unsafe) static var requests: [URLRequest] = []
        private static let lock = NSLock()

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            handler = nil
            requests = []
        }

        static func record(_ req: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(req)
        }

        static func snapshotRequests() -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.record(request)
            do {
                guard let handler = Self.handler else {
                    throw URLError(.badServerResponse)
                }
                let resp = try handler(request)
                let http = HTTPURLResponse(
                    url: request.url!,
                    statusCode: resp.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: resp.headers
                )!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: resp.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private var cacheDir: URL!
    private var downloader: MLXHubDownloader!

    override func setUp() {
        super.setUp()
        MockHFProtocol.reset()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-dl-audit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHFProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 15
        downloader = MLXHubDownloader(cacheBase: cacheDir, session: URLSession(configuration: cfg))
    }

    override func tearDown() {
        MockHFProtocol.reset()
        if let cacheDir {
            try? FileManager.default.removeItem(at: cacheDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private let hundredMB: Int64 = 100 * 1024 * 1024

    private func treeJSON(path: String, size: Int64, oid: String, sha256: String? = nil) -> Data {
        var lfs = "null"
        if let sha256 {
            lfs = "{\"oid\":\"sha256:\(sha256)\",\"size\":\(size)}"
        }
        let json = """
        [{"type":"file","path":"\(path)","size":\(size),"oid":"\(oid)","lfs":\(lfs)}]
        """
        return Data(json.utf8)
    }

    private func installBasicHFHandler(
        repo: String,
        filePath: String,
        size: Int64,
        oid: String,
        sha256: String? = nil,
        fileBody: Data? = nil,
        rangeMode: RangeMode = .honorRange
    ) {
        let tree = treeJSON(path: filePath, size: size, oid: oid, sha256: sha256)
        let rev = Data("{\"sha\":\"cafebabe\"}".utf8)
        let body = fileBody ?? Data(repeating: 0xAB, count: Int(size))
        MockHFProtocol.handler = { req in
            let url = req.url!
            let path = url.path
            let method = req.httpMethod ?? "GET"
            if path.contains("/tree/") {
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: tree)
            }
            if path.contains("/revision/") {
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: rev)
            }
            if method == "HEAD" {
                return .init(status: 200, headers: ["Content-Length": "\(size)"], body: Data())
            }
            // GET
            switch rangeMode {
            case .honorRange:
                if let range = req.value(forHTTPHeaderField: "Range"),
                   let parsed = parseRange(range, total: body.count) {
                    let slice = body.subdata(in: parsed.lowerBound..<parsed.upperBound)
                    return .init(
                        status: 206,
                        headers: [
                            "Content-Range": "bytes \(parsed.lowerBound)-\(parsed.upperBound - 1)/\(body.count)",
                            "Content-Length": "\(slice.count)"
                        ],
                        body: slice
                    )
                }
                return .init(status: 200, headers: ["Content-Length": "\(body.count)"], body: body)
            case .ignoreRangeReturnFull200:
                return .init(status: 200, headers: ["Content-Length": "\(body.count)"], body: body)
            case .truncated(let n):
                let slice = Data(body.prefix(n))
                return .init(status: 200, headers: ["Content-Length": "\(slice.count)"], body: slice)
            }
        }
    }

    private enum RangeMode {
        case honorRange
        case ignoreRangeReturnFull200
        case truncated(Int)
    }

    private func blobURL(repo: String, blobName: String) -> URL {
        let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        return cacheDir
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(blobName)
    }

    private func incompleteURL(repo: String, blobName: String) -> URL {
        blobURL(repo: repo, blobName: blobName).appendingPathExtension("incomplete")
    }

    // MARK: - Tests

    /// Incomplete file whose *size* equals the manifest size is treated as done,
    /// even when the middle was never written (parallel chunk hole).
    /// Without LFS SHA this is accepted as a successful download.
    func testChunkedResumeTreatsSparseFullSizeFileAsComplete() async throws {
        let repo = "audit/hole-resume"
        let oid = "blob-hole"
        let size = hundredMB
        installBasicHFHandler(
            repo: repo,
            filePath: "weights.bin",
            size: size,
            oid: oid,
            fileBody: Data(repeating: 0xAB, count: Int(size))
        )

        // Simulate an out-of-order chunk write: last 1 MB present, the rest zeros.
        // File size == total, which is what FileHandle produces after a high-offset pwrite.
        let partial = incompleteURL(repo: repo, blobName: oid)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: UInt64(size - 1024 * 1024))
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 1024 * 1024))
        try handle.close()

        try await downloader.download(repoId: repo) { _ in }

        let final = blobURL(repo: repo, blobName: oid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path),
                      "downloader should publish a final blob")
        let attrs = try FileManager.default.attributesOfItem(atPath: final.path)
        let finalSize = attrs[.size] as? Int64
        XCTAssertEqual(finalSize, size)

        let sample = try Data(contentsOf: final, options: [.mappedIfSafe])
        let prefix = sample.prefix(16)
        let allAB = prefix.allSatisfy { $0 == 0xAB }
        // Expected correct behavior: re-fetch missing ranges so the file is 0xAB.
        // Actual (bug): size==total short-circuits the chunked path; zeros remain.
        XCTAssertTrue(allAB,
                      "BUG: holey .incomplete of full size was accepted. first16=\(prefix.map { String(format: "%02x", $0) }.joined())")

        let gets = MockHFProtocol.snapshotRequests().filter { ($0.httpMethod ?? "GET") == "GET" && !($0.url?.path.contains("/tree/") ?? false) && !($0.url?.path.contains("/revision/") ?? false) }
        XCTAssertFalse(gets.isEmpty,
                       "BUG: no file GET was issued; resume skipped the hole")
    }

    /// A CDN that ignores Range and returns HTTP 200 + the entire object for
    /// every chunk writes the full payload at each chunk offset.
    func testChunked200FullBodyOverwritesAtOffsetAndInflatesFile() async throws {
        let repo = "audit/range-200"
        let oid = "blob-range"
        let size = hundredMB
        let body = Data(repeating: 0xCD, count: Int(size))
        installBasicHFHandler(
            repo: repo,
            filePath: "weights.bin",
            size: size,
            oid: oid,
            fileBody: body,
            rangeMode: .ignoreRangeReturnFull200
        )

        try await downloader.download(repoId: repo) { _ in }

        let final = blobURL(repo: repo, blobName: oid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: final.path)
        let finalSize = attrs[.size] as? Int64 ?? -1
        XCTAssertEqual(finalSize, size,
                       "BUG: accepting HTTP 200+full body for Range chunks inflated/corrupt file to \(finalSize) bytes (expected \(size))")
    }

    /// Small-file path writes whatever the server returned. A short 200 is
    /// treated as success when the file is not LFS-tracked.
    func testSmallFileAcceptsTruncatedBodyWithoutSizeCheck() async throws {
        let repo = "audit/trunc"
        let oid = "blob-trunc"
        let claimed: Int64 = 4096
        installBasicHFHandler(
            repo: repo,
            filePath: "config.json",
            size: claimed,
            oid: oid,
            fileBody: Data(repeating: 0x31, count: Int(claimed)),
            rangeMode: .truncated(7)
        )

        var thrown: Error?
        do {
            try await downloader.download(repoId: repo) { _ in }
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown,
                        "truncated 200 (7 bytes) must not be accepted as a \(claimed)-byte download")

        let final = blobURL(repo: repo, blobName: oid)
        if FileManager.default.fileExists(atPath: final.path) {
            let data = try Data(contentsOf: final)
            XCTAssertEqual(data.count, Int(claimed),
                           "must not publish a truncated blob (got \(data.count) bytes, claimed \(claimed))")
        }
    }

    /// Resolve URL is built with `URL(string:)` and no percent-encoding.
    func testFilenameWithSpaceFailsResolve() async throws {
        let repo = "audit/space-name"
        let oid = "blob-space"
        installBasicHFHandler(
            repo: repo,
            filePath: "my weights.bin",
            size: 32,
            oid: oid,
            fileBody: Data(repeating: 0x22, count: 32)
        )

        do {
            try await downloader.download(repoId: repo) { _ in }
            // If this succeeds the URL happened to parse; assert the file exists.
            let final = blobURL(repo: repo, blobName: oid)
            XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        } catch let err as MLXDownloadError {
            let msg = err.localizedDescription
            XCTAssertTrue(
                msg.contains("malformed") || msg.contains("Unexpected") || msg.contains("HEAD"),
                "space in filename failed as expected: \(msg)"
            )
            // Failure to download a perfectly valid HF path is the bug.
            XCTFail("BUG: filename with a space cannot be resolved (\(msg))")
        }
    }

    func testEnsureSnapshotSymlinkResolvesForNestedPath() throws {
        let cache = cacheDir.appendingPathComponent("models--org--name", isDirectory: true)
        let blob = cache.appendingPathComponent("blobs/deadbeef", isDirectory: false)
        let entry = cache.appendingPathComponent("snapshots/abc123/subdir/weights.bin", isDirectory: false)
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: blob)

        try MLXHubDownloader.ensureSnapshotSymlink(from: entry, to: blob)

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        let resolved = URL(fileURLWithPath: dest, relativeTo: entry.deletingLastPathComponent())
            .standardizedFileURL
        XCTAssertEqual(resolved, blob.standardizedFileURL,
                       "symlink dest \(dest) does not resolve to blob")
        let contents = try String(contentsOf: entry, encoding: .utf8)
        XCTAssertEqual(contents, "payload")
    }

    /// Same hole as the size-based resume skip, but with an LFS SHA: the
    /// downloader still does not re-fetch the missing range — it SHA-fails
    /// and deletes the partial instead of repairing it.
    func testHoleyResumeWithLfsShaDoesNotRepair() async throws {
        let repo = "audit/hole-lfs"
        let oid = "blob-hole-lfs"
        let size = hundredMB
        let good = Data(repeating: 0xAB, count: Int(size))
        let digest = SHA256.hash(data: good)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        installBasicHFHandler(
            repo: repo,
            filePath: "model.safetensors",
            size: size,
            oid: oid,
            sha256: sha,
            fileBody: good
        )

        let partial = incompleteURL(repo: repo, blobName: sha)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()

        var thrown: Error?
        do {
            try await downloader.download(repoId: repo) { _ in }
        } catch {
            thrown = error
        }

        let gets = MockHFProtocol.snapshotRequests().filter {
            let p = $0.url?.path ?? ""
            return ($0.httpMethod ?? "GET") == "GET"
                && !p.contains("/tree/")
                && !p.contains("/revision/")
        }
        XCTAssertFalse(gets.isEmpty,
                       "BUG: LFS holey resume issued no file GET; did not repair missing ranges")
        if gets.isEmpty {
            XCTAssertNotNil(thrown, "expected SHA mismatch after skipping the hole")
        }
    }

    /// A 206 that is shorter than the requested Range is treated as a
    /// successful chunk (no length check against start...end).
    func testChunkedAcceptsShort206AsSuccess() async throws {
        let repo = "audit/short-206"
        let oid = "blob-short206"
        let size = hundredMB
        let tree = treeJSON(path: "weights.bin", size: size, oid: oid)
        let rev = Data("{\"sha\":\"cafebabe\"}".utf8)
        MockHFProtocol.handler = { req in
            let path = req.url!.path
            let method = req.httpMethod ?? "GET"
            if path.contains("/tree/") {
                return .init(status: 200, headers: [:], body: tree)
            }
            if path.contains("/revision/") {
                return .init(status: 200, headers: [:], body: rev)
            }
            if method == "HEAD" {
                return .init(status: 200, headers: [:], body: Data())
            }
            // Always 206 with 8 bytes, regardless of Range.
            let slice = Data(repeating: 0xEE, count: 8)
            return .init(
                status: 206,
                headers: ["Content-Range": "bytes 0-7/\(size)", "Content-Length": "8"],
                body: slice
            )
        }

        var thrown: Error?
        do {
            try await downloader.download(repoId: repo) { _ in }
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "short 206 must fail the chunk, not publish a partial blob")

        let final = blobURL(repo: repo, blobName: oid)
        if FileManager.default.fileExists(atPath: final.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: final.path)
            let finalSize = attrs[.size] as? Int64 ?? -1
            XCTAssertEqual(finalSize, size,
                           "must not publish a short-206 blob (\(finalSize) bytes, claimed \(size))")
        }
    }

    func testLoadStateFlipsToLoadingAt999() {
        var state = MLXModelLoadState()
        state.begin(modelId: "m", displayName: "m")
        state.update(fraction: 0.999)
        XCTAssertEqual(state.phase, .loading,
                       "0.999 of a still-running download is treated as fully downloaded / loading")
    }
}

private func parseRange(_ header: String, total: Int) -> Range<Int>? {
    // "bytes=start-end"
    let trimmed = header.replacingOccurrences(of: "bytes=", with: "")
    let parts = trimmed.split(separator: "-")
    guard parts.count == 2,
          let start = Int(parts[0]),
          let end = Int(parts[1]) else { return nil }
    let upper = min(end + 1, total)
    guard start >= 0, start < upper else { return nil }
    return start..<upper
}
