//
//  BugHuntAppViewsTests.swift
//
//  Runtime proofs for parse/format helpers used by App/Views.
//

import XCTest
import Network
import AgentCore
@testable import VibeCoderApp

final class BugHuntAppViewsTests: XCTestCase {

    // MARK: - ShellOutput vs real run_shell wire format

    func testShellOutputParsesExitCodeFromRunShellToolOutput() {
        // RunShellTool emits: `$ cmd\n[exit N]\nstdout`
        let output = "$ ls -la\n[exit 0]\nfile.swift\n"
        let code = ShellOutput.exitCode(from: output)
        XCTAssertEqual(code, 0, "exit badge must read [exit N] after the $ command header")
        XCTAssertFalse(
            ShellOutput.stripExitLine(from: output).contains("[exit 0]"),
            "stripped body must not still contain the [exit N] line"
        )
    }

    func testShellOutputParsesNonzeroExitAndSeatbeltHeader() {
        let output = "$ false\n[seatbelt: on]\n[exit 1]\n"
        XCTAssertEqual(ShellOutput.exitCode(from: output), 1)
        let stripped = ShellOutput.stripExitLine(from: output)
        XCTAssertFalse(stripped.contains("[exit 1]"))
        XCTAssertTrue(stripped.contains("$ false") || stripped.contains("seatbelt"))
    }

    func testShellOutputStripDropsExitLineNotCommandLine() {
        let output = "\n[exit 0]\nhello\n"
        XCTAssertEqual(ShellOutput.exitCode(from: output), 0)
        let stripped = ShellOutput.stripExitLine(from: output)
        XCTAssertEqual(stripped.trimmingCharacters(in: .newlines), "hello")
        XCTAssertFalse(stripped.contains("[exit 0]"))
    }

    // MARK: - CodeSessionBuilder plan projection (revise_plan)

    func testRevisePlanAddRemoveUpdatesProjectedTodos() {
        let create = """
        {"goal":"Ship","todos":["Design","Implement","Verify"]}
        """
        let revise = """
        {"goal":"Ship v2","add":["Write docs"],"remove":["Verify"]}
        """
        let m1 = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCallInvocation(id: "c1", name: "create_plan", arguments: create)]
        )
        let m2 = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [ToolCallInvocation(id: "r1", name: "revise_plan", arguments: revise)]
        )
        let convo = Conversation(messages: [m1, m2])
        let states: [UUID: [ToolCallUIState]] = [
            m1.id: [ToolCallUIState(
                id: "c1", toolName: "create_plan", status: .success,
                input: create,
                output: "Created plan.\nPlan — Ship\n1. [ ] Design\n2. [ ] Implement\n3. [ ] Verify\nProgress: 0/3 complete"
            )],
            m2.id: [ToolCallUIState(
                id: "r1", toolName: "revise_plan", status: .success,
                input: revise,
                output: "Plan — Ship v2\n1. [ ] Design\n2. [ ] Implement\n3. [ ] Write docs\nProgress: 0/3 complete"
            )],
        ]

        let plan = CodeSessionBuilder.currentPlan(conversation: convo, toolStates: states)
        XCTAssertEqual(plan?.goal, "Ship v2")
        XCTAssertEqual(plan?.todos.map(\.text), ["Design", "Implement", "Write docs"])
        XCTAssertFalse(plan?.todos.contains(where: { $0.text == "Verify" }) ?? true)
    }

    // MARK: - P0-1 /export routing never rebroadcasts

    func testExportRoutingNeverImpliesRebroadcast() {
        let id = UUID()
        let chatVisible = ExportConversationRouting.decide(
            noteObject: id,
            selectedConversationID: id,
            chatTabVisible: true
        )
        XCTAssertEqual(chatVisible.selectConversationID, id)
        XCTAssertFalse(chatVisible.switchToChatTab)

        let otherTab = ExportConversationRouting.decide(
            noteObject: id,
            selectedConversationID: nil,
            chatTabVisible: false
        )
        XCTAssertEqual(otherTab.selectConversationID, id)
        XCTAssertTrue(otherTab.switchToChatTab)
    }

    func testExportRoutingFallsBackToSelectedConversation() {
        let selected = UUID()
        let decision = ExportConversationRouting.decide(
            noteObject: nil,
            selectedConversationID: selected,
            chatTabVisible: true
        )
        XCTAssertEqual(decision.selectConversationID, selected)
    }

    // MARK: - apply_patch inline card: +++ / --- content lines

    func testApplyPatchDoesNotTreatPlusPlusIncrementAsFileHeader() {
        // Unified diff for adding `++i;` / removing `--n;`.
        // Real ApplyPatchTool/UnifiedDiff.parse uses "+++ " / "--- " (space)
        // for file headers. The UI linesFromPatch uses hasPrefix("+++")/("---").
        let patch = """
        --- a/loop.c
        +++ b/loop.c
        @@ -1,3 +1,3 @@
         int i = 0;
        ---n;
        +++i;
         return i;
        """
        let args: [String: Any] = ["patch": patch]
        let input = try! String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let state = ToolCallUIState(
            id: "p1",
            toolName: "apply_patch",
            status: .success,
            input: input,
            output: "Patched loop.c"
        )
        let edit = CodeSessionBuilder.fileEdit(from: state)
        XCTAssertNotNil(edit)
        XCTAssertGreaterThan(edit?.removedCount ?? 0, 0, "removing `--n;` must show a red line")
        XCTAssertGreaterThan(edit?.addedCount ?? 0, 0, "adding `++i;` must show a green line")
        let kinds = edit?.lines.map { line -> String in
            switch line {
            case .added(let s): return "+\(s)"
            case .removed(let s): return "-\(s)"
            case .context(let s): return " \(s)"
            }
        } ?? []
        XCTAssertTrue(kinds.contains(where: { $0 == "- --n;" || $0 == "---n;" || $0.hasPrefix("-") && $0.contains("n;") }),
                      "expected a removed --n line, got \(kinds)")
        XCTAssertTrue(kinds.contains(where: { $0 == "+ ++i;" || $0 == "+++i;" || $0.hasPrefix("+") && $0.contains("i;") }),
                      "expected an added ++i line, got \(kinds)")
    }

    // MARK: - write_file empty body / empty SEARCH create seeding

    func testEmptySearchCreateSeedsLaterRewriteRedLines() {
        // EditFileTool: empty SEARCH creates a file.
        let createEdits = """
        <<<<<<< SEARCH
        =======
        hello
        world
        >>>>>>> REPLACE
        """
        let createArgs: [String: Any] = ["path": "/tmp/New.swift", "edits": createEdits]
        let createInput = try! String(data: JSONSerialization.data(withJSONObject: createArgs), encoding: .utf8)!
        let create = ToolCallUIState(
            id: "c", toolName: "edit_file", status: .success,
            input: createInput, output: "created"
        )

        let rewriteArgs: [String: Any] = ["path": "/tmp/New.swift", "content": "hello\n"]
        let rewriteInput = try! String(data: JSONSerialization.data(withJSONObject: rewriteArgs), encoding: .utf8)!
        let rewrite = ToolCallUIState(
            id: "w", toolName: "write_file", status: .success,
            input: rewriteInput, output: "wrote"
        )

        let parts = ChatToolPartition.split([create, rewrite])
        XCTAssertEqual(parts.edits.count, 2)
        XCTAssertGreaterThan(
            parts.edits[1].removedCount, 0,
            "rewrite after empty-SEARCH create must know prior content so red − lines appear"
        )
    }

    func testEditFileReplaceAllSeedsEveryOccurrence() {
        let prev = "foo\nfoo\nfoo\n"
        let edits = """
        <<<<<<< SEARCH
        foo
        =======
        bar
        >>>>>>> REPLACE
        """
        let args: [String: Any] = [
            "path": "/tmp/t.txt",
            "edits": edits,
            "replace_all": true
        ]
        let input = try! String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let state = ToolCallUIState(
            id: "r", toolName: "edit_file", status: .success,
            input: input, output: "ok"
        )
        let after = CodeSessionBuilder.contentAfterEdit(previous: prev, state: state)
        XCTAssertEqual(after, "bar\nbar\nbar\n")
    }

    // MARK: - ThinkTagSplit (re-exported; used by MessageBubble / ModelChrome)

    func testThinkTagSplitExtractsEveryClosedThinkBlock() {
        let raw = """
        <think>first</think>
        answer one
        <think>second</think>
        answer two
        """
        let split = ThinkTagSplit.parse(raw)
        XCTAssertEqual(split.thinking, "first\n\nsecond")
        XCTAssertFalse(split.body.contains("<think>"), "later think blocks must not leak into the answer")
        XCTAssertTrue(split.body.contains("answer one"))
        XCTAssertTrue(split.body.contains("answer two"))
    }

    // MARK: - Mention query (composer @ parsing)

    @MainActor
    func testActiveMentionQueryDoesNotTreatEmailAsMention() {
        XCTAssertNil(
            MentionSearchCoordinator.activeMentionQuery(in: "please email max@icloud.com"),
            "an email address must not open the @-mention popup"
        )
        XCTAssertNil(
            MentionSearchCoordinator.activeMentionQuery(in: "user@example.com"),
            "a bare email must not be treated as an @-query"
        )
    }

    @MainActor
    func testActiveMentionQueryStillFindsTokenAfterWhitespace() {
        XCTAssertEqual(
            MentionSearchCoordinator.activeMentionQuery(in: "see @Foo.swift"),
            "Foo.swift"
        )
        XCTAssertEqual(
            MentionSearchCoordinator.activeMentionQuery(in: "@Bar"),
            "Bar"
        )
    }

    func testSelectCandidateRegexRemovesOnlyMentionToken() {
        // Verbatim from MentionAwareComposer.selectCandidate
        func stripMention(from text: String) -> String {
            var text = text
            if let range = text.range(of: #"(?:(?<=^)|(?<=\s))@[^\s\n]*$"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            return text
        }
        XCTAssertEqual(stripMention(from: "see @Foo.swift"), "see ")
        // If the query incorrectly treats emails as mentions, selecting a hit
        // would also mangle the address.
        let afterEmailSelect = stripMention(from: "please email max@icloud.com")
        XCTAssertEqual(afterEmailSelect, "please email max@icloud.com")
    }

    // MARK: - MessageBubble splitContent / displayBody fallback

    func testModelChromeDoesNotReemitThinkTagsAsAnswer() {
        let raw = "<think>I will add one and one</think>"
        let chrome = ModelChrome.present(raw, enabled: true)
        XCTAssertEqual(chrome.thinking, "I will add one and one")
        XCTAssertFalse(
            chrome.body.contains("<think>"),
            "stripped body must not re-emit raw think tags (got \(chrome.body.debugDescription))"
        )
        XCTAssertTrue(
            chrome.body.isEmpty,
            "content that is only a think block must have an empty answer body (got \(chrome.body.debugDescription))"
        )
    }

    // MARK: - normalizedEndpointURL (verbatim from ConnectionSettingsView)

    func testNormalizedEndpointStripsChatCompletionsSuffix() {
        let url = ConnectionSettingsView.normalizedEndpointURL(
            from: "http://127.0.0.1:8080/v1/chat/completions"
        )
        XCTAssertEqual(url?.path, "/v1")
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertEqual(url?.port, 8080)
    }

    func testEmptyHeroIgnoresWireOnlyReminderLogs() {
        let log = ChatMessage(
            role: .user,
            content: SystemReminder.autoVerify(path: "App.swift", tail: "let x = 1")
        )
        XCTAssertTrue(
            ChatView.shouldShowEmptyBrandHero(
                messages: [log],
                isRunning: false,
                streamingContent: "",
                noticesEmpty: true
            ),
            "AutoVerify log must not count as a real chat turn"
        )
        let real = ChatMessage(role: .user, content: "hello")
        XCTAssertFalse(
            ChatView.shouldShowEmptyBrandHero(
                messages: [real],
                isRunning: false,
                streamingContent: "",
                noticesEmpty: true
            )
        )
    }

    func testSidebarPreviewSkipsTrailingAutoVerifyLog() {
        var conv = Conversation(title: "t")
        conv.messages = [
            ChatMessage(role: .user, content: "edit App.swift"),
            ChatMessage(role: .assistant, content: "Updated the file."),
            ChatMessage(
                role: .user,
                content: SystemReminder.autoVerify(path: "App.swift", tail: "SECRET_TAIL")
            ),
        ]
        let preview = ZCodeSidebar.previewLine(for: conv)
        XCTAssertTrue(preview.contains("Updated the file."))
        XCTAssertFalse(preview.contains("SECRET_TAIL"))
        XCTAssertFalse(preview.contains("AutoVerify"))
    }

    func testNormalizedEndpointAcceptsBareHostPort() {
        let url = ConnectionSettingsView.normalizedEndpointURL(from: "127.0.0.1:8080")
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertEqual(url?.port, 8080)
        XCTAssertEqual(url?.path, "/v1")
    }

    // MARK: - PDF / documents / markdown helpers

    func testParsePageRangeNeverBuildsInvalidClosedRange() {
        XCTAssertEqual(PDFToolsService.parsePageRange(nil, max: 0), [])
        XCTAssertEqual(PDFToolsService.parsePageRange("all", max: 0), [])
        XCTAssertEqual(PDFToolsService.parsePageRange("4-10", max: 3), [])
        XCTAssertEqual(PDFToolsService.parsePageRange("1-5", max: 3), [1, 2, 3])
        XCTAssertEqual(PDFToolsService.parsePageRange("all", max: 2), [1, 2])
    }

    func testDocumentConvertSamePathDoesNotDeleteOnlyCopy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("only.md")
        try "keep me".write(to: file, atomically: true, encoding: .utf8)
        let result = DocumentConvertService.convert(
            input: file.path, output: file.path, from: "md", to: "md")
        XCTAssertFalse(result.lowercased().hasPrefix("error"), result)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(body, "keep me")
    }

    @MainActor
    func testSpellcheckMissingFileMentionsCouldNotReadPath() {
        let missing = "/tmp/does-not-exist-\(UUID().uuidString).txt"
        let result = SpellcheckService.check(path: missing, text: nil, language: nil)
        XCTAssertTrue(result.contains("could not read path"), result)
        XCTAssertFalse(result.contains("provide either `path` or `text`"), result)
    }

    func testCreatePDFMissingMarkdownPathMessage() async {
        let missing = "/tmp/does-not-exist-\(UUID().uuidString).md"
        let result = await DocumentRenderingService.renderMarkdownToPDF(
            markdownPath: missing,
            markdownText: nil,
            outputPath: "/tmp/out.pdf"
        )
        XCTAssertTrue(result.contains("could not read markdown_path"), result)
        XCTAssertFalse(result.contains("provide either `markdown_path` or `markdown_text`"), result)
    }

    func testRotateHugeAngleDoesNotTrap() {
        let result = PDFToolsService.manipulate(
            action: "rotate",
            args: ["input": "/tmp/x.pdf", "output": "/tmp/y.pdf", "angle": 1e20]
        )
        XCTAssertTrue(result.contains("angle"), result)
        XCTAssertFalse(result.contains("Rotated"), result)
    }

    func testMarkdownToHTMLStripsListMarkersAndEscapesAttrs() {
        let ul = MarkdownToHTML.render("  - hello")
        XCTAssertTrue(ul.contains("<li>"), ul)
        XCTAssertTrue(ul.contains("hello"), ul)
        XCTAssertFalse(ul.contains("- hello"), ul)

        let ol = MarkdownToHTML.render("1. 2020 was a year")
        XCTAssertTrue(ol.contains("2020 was a year"), ol)
        XCTAssertFalse(ol.contains(">020"), ol)

        let fenced = MarkdownToHTML.render("```foo\"><img\ncode\n```")
        XCTAssertFalse(fenced.contains("class=\"lang-foo\">"), fenced)
        XCTAssertTrue(fenced.contains("&quot;") || fenced.contains("lang-foo"), fenced)

        let link = MarkdownToHTML.render("[x](http://ex.com/a\"onclick=\"alert(1))")
        XCTAssertFalse(link.contains("href=\"http://ex.com/a\""), link)
        XCTAssertTrue(link.contains("&quot;") || link.contains("&#39;"), link)
    }

    func testNormalizedEndpointStripsChatCompletionsWithoutV1Prefix() {
        let url = ConnectionSettingsView.normalizedEndpointURL(
            from: "http://127.0.0.1:8080/chat/completions"
        )
        XCTAssertEqual(url?.path, "/v1")
    }

    func testDefaultDetectTargetsCoverLocalServers() {
        let ids = Set(LoopbackDetectTarget.defaults.map(\.backend))
        XCTAssertTrue(ids.contains(.lmStudio))
        XCTAssertTrue(ids.contains(.ollama))
        XCTAssertTrue(ids.contains(.omlx))
        XCTAssertTrue(ids.contains(.unslothStudio), "Unsloth Studio is a loopback default")
        XCTAssertTrue(ids.contains(.exo), "EXO is a loopback default")
        XCTAssertFalse(ids.contains(.custom), "custom is a Settings URL, not a default probe")
    }

    func testClassifyRequiresModelsJSONNotBareTCP() {
        XCTAssertEqual(LoopbackServerProbe.classify(status: 200, body: Data("{}".utf8)), .busyNotCompat)
        let list = #"{"object":"list","data":[]}"#.data(using: .utf8)
        XCTAssertEqual(LoopbackServerProbe.classify(status: 200, body: list), .modelsReady)
        XCTAssertEqual(LoopbackServerProbe.classify(status: 401, body: nil), .modelsReady)
        XCTAssertEqual(LoopbackServerProbe.classify(status: 403, body: Data()), .modelsReady)
        XCTAssertEqual(LoopbackServerProbe.classify(status: 404, body: Data("<html>".utf8)), .busyNotCompat)
    }

    func testTCPOpenWithoutHTTPIsNotModelsReady() {
        // Minimal repro: accept TCP and never speak HTTP.
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            return XCTFail("listen: \(error)")
        }
        let ready = expectation(description: "listen")
        var port = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state, let p = listener.port {
                port = Int(p.rawValue)
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .utility))
            // Intentionally never write an HTTP response.
        }
        listener.start(queue: .global(qos: .utility))
        defer { listener.cancel() }
        wait(for: [ready], timeout: 2)
        guard let url = LoopbackServerProbe.modelsURL(host: "127.0.0.1", port: port) else {
            return XCTFail("url")
        }
        let verdict = LoopbackServerProbe.probe(url: url, timeout: 0.6)
        XCTAssertNotEqual(verdict, .modelsReady, "TCP-only must not look like a model server")
    }

    func testHTTPModelsListIsDetected() {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            return XCTFail("listen: \(error)")
        }
        let ready = expectation(description: "listen")
        var port = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state, let p = listener.port {
                port = Int(p.rawValue)
                ready.fulfill()
            }
        }
        let body = #"{"object":"list","data":[{"id":"m"}]}"#
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .utility))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let payload = Data(body.utf8)
                let resp = """
                HTTP/1.1 200 OK\r
                Content-Type: application/json\r
                Content-Length: \(payload.count)\r
                Connection: close\r
                \r
                \(body)
                """
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        listener.start(queue: .global(qos: .utility))
        defer { listener.cancel() }
        wait(for: [ready], timeout: 2)
        guard let url = LoopbackServerProbe.modelsURL(host: "127.0.0.1", port: port) else {
            return XCTFail("url")
        }
        XCTAssertEqual(LoopbackServerProbe.probe(url: url, timeout: 1.2), .modelsReady)
    }
}

@MainActor
final class PatchReviewQueueTests: XCTestCase {
    func testPatchReviewQueuesSecondBatch() async {
        let coord = PatchReviewCoordinator()
        let p1 = [PatchPreview(
            path: "A.swift", originalContent: "a", updatedContent: "b", hunks: [])]
        let p2 = [PatchPreview(
            path: "B.swift", originalContent: "c", updatedContent: "d", hunks: [])]

        async let first = coord.review(p1)
        await Task.yield()
        async let second = coord.review(p2)
        await Task.yield()
        XCTAssertNotNil(coord.pendingBatch)
        coord.resolve(.acceptAll)
        let d1 = await first
        XCTAssertEqual(d1, .acceptAll)
        await Task.yield()
        XCTAssertNotNil(coord.pendingBatch)
        coord.resolve(.rejectAll)
        let d2 = await second
        XCTAssertEqual(d2, .rejectAll)
    }
}
