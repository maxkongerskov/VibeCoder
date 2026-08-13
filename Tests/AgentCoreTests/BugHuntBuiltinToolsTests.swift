//
//  BugHuntBuiltinToolsTests.swift
//
//  Verification-first bug hunt against Sources/AgentCore/Tools/Builtins.
//  Each test invokes real Tool types (or their public helpers) against a
//  temp directory. Failures here are the only evidence used in the report.
//

import XCTest
@testable import AgentCore

final class BugHuntBuiltinToolsTests: XCTestCase {

    private var root: URL!
    private var conversationID: UUID!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-builtins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        conversationID = UUID()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ctx(preRead: [URL] = []) -> ToolContext {
        let reads = Set(preRead.map { SafeModeConfig.normalizePath($0.path) })
        return ToolContext(
            projectRoot: root,
            conversationID: conversationID,
            executionMode: .yolo,
            authorization: AuthorizationConfig(useInlineRememberedOnly: true),
            sessionReadPaths: reads
        )
    }

    // MARK: - edit_file replace_all

    /// `replace_all` uses `while true { switch { break } }` — in Swift `break`
    /// only exits the switch, so this is a tight CPU loop. Run it off the
    /// cooperative pool and fail if it does not finish in time.
    func testEditFileReplaceAllTerminatesAndReplacesEveryMatch() throws {
        let file = root.appendingPathComponent("repeat.txt")
        try "foo\nbar\nfoo\n".write(to: file, atomically: true, encoding: .utf8)
        let edits = """
        <<<<<<< SEARCH
        foo
        =======
        baz
        >>>>>>> REPLACE
        """
        let context = ctx(preRead: [file])
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let result = try await EditFileTool().execute(
                    arguments: ToolArguments(dictionary: [
                        "path": "repeat.txt",
                        "edits": edits,
                        "replace_all": true,
                    ]),
                    context: context
                )
                box.result = result
            } catch {
                box.error = error
            }
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + 2.5)
        XCTAssertEqual(
            waited, .success,
            "edit_file replace_all hung (Swift break inside switch does not exit the while-true loop)"
        )
        if waited == .success {
            if let error = box.error { throw error }
            let result = try XCTUnwrap(box.result)
            XCTAssertFalse(result.isError, result.content)
            let body = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(body.components(separatedBy: "baz").count - 1, 2)
            XCTAssertFalse(body.contains("foo"))
        }
    }

    func testEditFileReplaceAllWhereReplacementContainsSearchDoesNotHang() throws {
        let file = root.appendingPathComponent("grow.txt")
        try "a\n".write(to: file, atomically: true, encoding: .utf8)
        let edits = """
        <<<<<<< SEARCH
        a
        =======
        aa
        >>>>>>> REPLACE
        """
        let context = ctx(preRead: [file])
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let result = try await EditFileTool().execute(
                    arguments: ToolArguments(dictionary: [
                        "path": "grow.txt",
                        "edits": edits,
                        "replace_all": true,
                    ]),
                    context: context
                )
                box.result = result
            } catch {
                box.error = error
            }
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + 2.5)
        XCTAssertEqual(
            waited, .success,
            "edit_file replace_all hung when REPLACE contains SEARCH"
        )
        if waited == .success {
            if let error = box.error { throw error }
            let body = try String(contentsOf: file, encoding: .utf8)
            XCTAssertLessThan(body.count, 20, "replace_all grew unbounded: \(body)")
        }
    }

    // MARK: - read_file slicing

    func testReadFileNegativeMaxLinesDoesNotCrash() async throws {
        let file = root.appendingPathComponent("lines.txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            arguments: ToolArguments(dictionary: [
                "path": "lines.txt",
                "offset": 1,
                "maxLines": -5,
            ]),
            context: ctx()
        )
        // Must not trap. Negative maxLines should error or clamp, not crash.
        XCTAssertTrue(result.isError || !result.content.isEmpty || result.content.isEmpty)
    }

    func testReadFileHugeOffsetPlusMaxLinesDoesNotOverflow() async throws {
        let file = root.appendingPathComponent("small.txt")
        try "only\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await ReadFileTool().execute(
            arguments: ToolArguments(dictionary: [
                "path": "small.txt",
                "offset": Int.max,
                "maxLines": 10,
            ]),
            context: ctx()
        )
        XCTAssertFalse(result.content.isEmpty)
    }

    // MARK: - grep_code

    func testGrepPatternStartingWithDashIsNotTreatedAsFlag() async throws {
        let file = root.appendingPathComponent("dash.txt")
        try "alpha\n-v\nbeta\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await GrepCodeTool().execute(
            arguments: ToolArguments(dictionary: [
                "pattern": "-v",
                "path": ".",
            ]),
            context: ctx()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(
            result.content.contains("-v"),
            "pattern '-v' must search for '-v', not invert-match. got: \(result.content)"
        )
        XCTAssertFalse(
            result.content.contains("alpha"),
            "invert-match would leak other lines: \(result.content)"
        )
    }

    func testGrepNegativeMaxResultsDoesNotCrash() async throws {
        let file = root.appendingPathComponent("g.txt")
        try "needle\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await GrepCodeTool().execute(
            arguments: ToolArguments(dictionary: [
                "pattern": "needle",
                "path": ".",
                "maxResults": -1,
            ]),
            context: ctx()
        )
        XCTAssertTrue(result.isError || result.content.contains("needle") || result.content.contains("no matches")
                      || result.content.contains("…"))
    }

    // MARK: - glob_files

    func testGlobDoubleStarAloneMatchesNestedFiles() async throws {
        let nested = root.appendingPathComponent("sub/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: nested.appendingPathComponent("leaf.txt"), atomically: true, encoding: .utf8)

        let result = try await GlobFilesTool().execute(
            arguments: ToolArguments(dictionary: ["pattern": "**"]),
            context: ctx()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertFalse(result.content.contains("(no matches)"), result.content)
        XCTAssertTrue(
            result.content.contains("top.txt") || result.content.contains("leaf.txt"),
            "** should match files at any depth, got: \(result.content)"
        )
    }

    func testGlobTrailingDoubleStarMatchesFilesUnderDirectory() async throws {
        let nested = root.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "x".write(to: nested.appendingPathComponent("mod.swift"), atomically: true, encoding: .utf8)

        let result = try await GlobFilesTool().execute(
            arguments: ToolArguments(dictionary: ["pattern": "pkg/**"]),
            context: ctx()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(
            result.content.contains("mod.swift"),
            "pkg/** should match pkg/mod.swift, got: \(result.content)"
        )
    }

    // MARK: - fetch_url SSRF guard

    func testFetchURLBlocksDecimalLocalhost() {
        XCTAssertTrue(
            FetchURLTool.isBlocked(host: "2130706433"),
            "decimal 127.0.0.1 (2130706433) must be blocked"
        )
    }

    func testFetchURLBlocksTrailingDotLocalhost() {
        XCTAssertTrue(
            FetchURLTool.isBlocked(host: "localhost."),
            "localhost. (FQDN form) must be blocked"
        )
    }

    func testFetchURLBlocksIPv4MappedIPv6Loopback() {
        XCTAssertTrue(
            FetchURLTool.isBlocked(host: "::ffff:127.0.0.1"),
            "IPv4-mapped IPv6 loopback must be blocked"
        )
        XCTAssertTrue(
            FetchURLTool.isBlocked(host: "[::ffff:127.0.0.1]"),
            "bracketed IPv4-mapped IPv6 loopback must be blocked"
        )
    }

    func testFetchURLBlocksBareZero() {
        XCTAssertTrue(
            FetchURLTool.isBlocked(host: "0"),
            "host '0' (0.0.0.0) must be blocked"
        )
    }

    func testFetchURLExecuteBlocksLocalhostTrailingDot() async {
        let result = await FetchURLTool.fetch(url: "http://localhost./")
        XCTAssertTrue(result.isError, result.output)
        XCTAssertTrue(
            result.output.lowercased().contains("local") || result.output.lowercased().contains("private")
                || result.output.lowercased().contains("refusing"),
            "expected SSRF refusal, got: \(result.output)"
        )
    }

    func testFetchURLExecuteDoesNotReachIPv4MappedLoopback() async throws {
        let port = try startLoopbackProbeServer()
        defer { stopLoopbackProbeServer() }

        let url = "http://[::ffff:127.0.0.1]:\(port)/"
        let result = await FetchURLTool.fetch(url: url)
        XCTAssertFalse(
            result.output.contains("SSRF_PROBE_OK"),
            "fetch_url retrieved loopback content via IPv4-mapped IPv6: \(result.output)"
        )
        XCTAssertTrue(
            result.isError,
            "expected refusal for \(url), got success: \(result.output)"
        )
    }

    func testFetchRSSExecuteBlocksDecimalLocalhost() async {
        let result = await FetchRSSTool.fetch(url: "http://2130706433/")
        XCTAssertTrue(result.isError, result.output)
        XCTAssertTrue(
            result.output.lowercased().contains("local") || result.output.lowercased().contains("private")
                || result.output.lowercased().contains("refusing"),
            "expected SSRF refusal, got: \(result.output)"
        )
    }

    // MARK: - apply_patch

    func testApplyPatchStripsDiffTimestampsFromPath() throws {
        let patch = """
        --- a/hello.swift\t2024-01-15 12:00:00.000000000 +0000
        +++ b/hello.swift\t2024-01-15 12:00:00.000000000 +0000
        @@ -1 +1 @@
        -old
        +new
        """
        let parsed = UnifiedDiff.parse(patch)
        XCTAssertEqual(parsed.count, 1, "expected one file hunk, got \(parsed)")
        XCTAssertEqual(
            parsed.first?.path,
            "hello.swift",
            "diff -u timestamps must not become part of the path, got \(parsed.first?.path ?? "nil")"
        )
    }

    func testApplyPatchRollbackDeletesNewFileInsteadOfLeavingEmpty() async throws {
        // First target is a new file that writes successfully. Second target's
        // parent is a regular file, so createDirectory fails mid-batch.
        let blocker = root.appendingPathComponent("blocker")
        try "not-a-dir".write(to: blocker, atomically: true, encoding: .utf8)

        let patch = """
        --- /dev/null
        +++ b/created.txt
        @@ -0,0 +1 @@
        +hello
        --- /dev/null
        +++ b/blocker/nested.txt
        @@ -0,0 +1 @@
        +nope
        """

        let result = try await ApplyPatchTool().execute(
            arguments: ToolArguments(dictionary: ["patch": patch]),
            context: ctx()
        )
        XCTAssertTrue(result.isError, result.content)

        let created = root.appendingPathComponent("created.txt")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: created.path),
            "rollback of a newly created file must delete it, not leave an empty leftover. exists=\(FileManager.default.fileExists(atPath: created.path)) content=\((try? String(contentsOf: created, encoding: .utf8)) ?? "<unreadable>")"
        )
    }

    // MARK: - text_edit / notebook / porting confinement

    func testTextEditBulkReplaceRefusesPathOutsideWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-textedit-outside-\(UUID().uuidString).txt")
        try "secret-before".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        do {
            let result = try await TextEditTool().execute(
                arguments: ToolArguments(dictionary: [
                    "action": "bulk_find_replace",
                    "paths": [outside.path],
                    "pattern": "secret-before",
                    "replacement": "pwned",
                ]),
                context: ctx()
            )
            XCTAssertTrue(
                result.isError,
                "bulk_find_replace wrote outside workspace: \(result.content)"
            )
        } catch {
            // permissionDenied / invalidArguments is the correct fail-closed path
        }

        XCTAssertEqual(
            try String(contentsOf: outside, encoding: .utf8),
            "secret-before",
            "text_edit must not mutate files outside the project root"
        )
    }

    func testTextEditFillTemplateRefusesOutputPathOutsideWorkspace() async throws {
        let template = root.appendingPathComponent("t.txt")
        try "Hello {{name}}".write(to: template, atomically: true, encoding: .utf8)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-fill-outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }

        do {
            let result = try await TextEditTool().execute(
                arguments: ToolArguments(dictionary: [
                    "action": "fill_template",
                    "templatePath": "t.txt",
                    "outputPath": outside.path,
                    "values": ["name": "Ada"],
                ]),
                context: ctx()
            )
            XCTAssertTrue(result.isError, "fill_template wrote outside: \(result.content)")
        } catch {
            // fail-closed
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.path),
            "fill_template must not create files outside the project root"
        )
    }

    func testNotebookMutateRefusesPathOutsideWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-nb-\(UUID().uuidString).ipynb")
        let original = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","metadata":{},"source":["print(1)\\n"],"outputs":[],"execution_count":null}]}
        """
        try original.write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        do {
            let result = try await NotebookTool().execute(
                arguments: ToolArguments(dictionary: [
                    "path": outside.path,
                    "action": "replace_source",
                    "index": 0,
                    "source": "print(2)",
                ]),
                context: ctx()
            )
            XCTAssertTrue(result.isError, "notebook mutated outside workspace: \(result.content)")
        } catch {
            // fail-closed
        }

        let after = try String(contentsOf: outside, encoding: .utf8)
        XCTAssertTrue(
            after.contains("print(1)"),
            "notebook outside workspace must be unchanged, got: \(after)"
        )
        XCTAssertFalse(after.contains("print(2)"))
    }

    func testPortingShimRefusesOutputPathOutsideWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("bughunt-shim-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: outside) }

        do {
            let result = try await PortingTools().execute(
                arguments: ToolArguments(dictionary: [
                    "action": "generate_framework_shim",
                    "framework": "Combine",
                    "output_path": outside.path,
                ]),
                context: ctx()
            )
            XCTAssertTrue(result.isError, "porting shim wrote outside: \(result.content)")
        } catch {
            // fail-closed
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.path),
            "generate_framework_shim must not write outside the project root"
        )
    }

    // MARK: - notebook JSON

    // MARK: - xcode_project_editor quoting

    func testXcodeAddFileQuotesPathWithSpaces() async throws {
        let projDir = root.appendingPathComponent("Demo.xcodeproj")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let pbx = """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tobjects = {

        /* Begin PBXBuildFile section */
        /* End PBXBuildFile section */

        /* Begin PBXFileReference section */
        \t\tAAAAAAAA0000000000000001 /* App.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
        /* End PBXFileReference section */

        /* Begin PBXGroup section */
        \t\tBBBBBBBB0000000000000001 = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tAAAAAAAA0000000000000001 /* App.swift */,
        \t\t\t);
        \t\t\tsourceTree = "<group>";
        \t\t};
        /* End PBXGroup section */

        /* Begin PBXSourcesBuildPhase section */
        \t\tCCCCCCCC0000000000000001 /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \t\t\t);
        \t\t\trunOnlyForDeploymentPostprocessing = 0;
        \t\t};
        /* End PBXSourcesBuildPhase section */
        \t};
        \trootObject = DDDDDDDD0000000000000001;
        }
        """
        try pbx.write(to: projDir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let spaced = root.appendingPathComponent("My File.swift")
        try "let x = 1\n".write(to: spaced, atomically: true, encoding: .utf8)

        let result = try await XcodeProjectEditorTool().execute(
            arguments: ToolArguments(dictionary: [
                "action": "add_file",
                "file_path": "My File.swift",
                "project_path": ".",
            ]),
            context: ctx()
        )
        XCTAssertFalse(result.isError, result.content)

        let written = try String(contentsOf: projDir.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(
            written.contains("path = \"My File.swift\"") || written.contains("path = \"My File.swift\";"),
            "pbxproj path with a space must be quoted, got excerpt: \(written)"
        )
        XCTAssertFalse(
            written.contains("path = My File.swift;"),
            "unquoted space in pbxproj path corrupts the project file"
        )
    }

    // MARK: - helpers

    private final class ResultBox: @unchecked Sendable {
        var result: ToolResult?
        var error: Error?
    }

    private static var probeProcess: Process?

    private func startLoopbackProbeServer() throws -> Int {
        let port = Int.random(in: 18000...18999)
        let script = """
        import http.server, socketserver
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'SSRF_PROBE_OK')
            def log_message(self, fmt, *args):
                pass
        socketserver.TCPServer.allow_reuse_address = True
        with socketserver.TCPServer(('127.0.0.1', \(port)), H) as httpd:
            httpd.serve_forever()
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        Self.probeProcess = proc
        // Give the socket a moment to bind.
        Thread.sleep(forTimeInterval: 0.2)
        return port
    }

    private func stopLoopbackProbeServer() {
        Self.probeProcess?.terminate()
        Self.probeProcess = nil
    }
}
