//
//  BugHuntAppViewsTests.swift
//
//  Runtime proofs for parse/format helpers used by App/Views.
//

import XCTest
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

}
