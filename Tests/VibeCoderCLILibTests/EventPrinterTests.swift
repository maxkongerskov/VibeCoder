//
//  EventPrinterTests.swift
//  C2: TTY color vs NO_COLOR / non-TTY plain text.
//

import XCTest
import AgentCore
@testable import VibeCoderCLILib

final class EventPrinterTests: XCTestCase {

    func testTTYColorPathEmitsANSIForErrorAndToolEvents() {
        let cap = Capture()
        let printer = EventPrinter(
            colorStdout: true,
            colorStderr: true,
            writeStdout: { cap.writeOut($0) },
            writeStderr: { cap.writeErr($0) }
        )

        printer.handle(.error(description: "boom"))
        printer.handle(.toolStarted(id: "t1", name: "read_file", label: "Read foo.swift"))
        printer.handle(.toolCompleted(id: "t1", name: "read_file", label: "Read foo.swift", isError: true))
        printer.handle(.toolResult(
            invocation: ToolCallInvocation(id: "t1", name: "read_file", arguments: "{}"),
            result: ToolResult(content: "no such file", isError: true)
        ))

        XCTAssertTrue(cap.err.contains("\u{001B}["), "error/tool stderr should carry ANSI")
        XCTAssertTrue(cap.out.contains("\u{001B}["), "toolCompleted stdout should carry ANSI")
        XCTAssertTrue(cap.err.contains("[error] boom"))
        XCTAssertTrue(cap.err.contains("[read_file] Read foo.swift"))
        XCTAssertTrue(cap.err.contains("[✗ read_file] no such file"))
        XCTAssertTrue(cap.out.contains("[✗ read_file]"))
        XCTAssertNotEqual(stripANSI(cap.err), cap.err)
        XCTAssertEqual(stripANSI(cap.err), "\n[error] boom\n[read_file] Read foo.swift\n[✗ read_file] no such file\n")
        XCTAssertEqual(stripANSI(cap.out), "[✗ read_file]\n")
    }

    func testNoColorAndNonTTYMatchC1PlainText() {
        let cap = Capture()
        let printer = EventPrinter(
            colorStdout: false,
            colorStderr: false,
            writeStdout: { cap.writeOut($0) },
            writeStderr: { cap.writeErr($0) }
        )
        replayC1Events(on: printer)

        XCTAssertFalse(cap.out.contains("\u{001B}"))
        XCTAssertFalse(cap.err.contains("\u{001B}"))
        XCTAssertEqual(cap.out, c1Stdout)
        XCTAssertEqual(cap.err, c1Stderr)
    }

    func testColoredOutputStripsToC1PlainText() {
        let cap = Capture()
        let printer = EventPrinter(
            colorStdout: true,
            colorStderr: true,
            writeStdout: { cap.writeOut($0) },
            writeStderr: { cap.writeErr($0) }
        )
        replayC1Events(on: printer)

        XCTAssertTrue(cap.err.contains("\u{001B}["))
        XCTAssertEqual(stripANSI(cap.out), c1Stdout)
        XCTAssertEqual(stripANSI(cap.err), c1Stderr)
    }

    func testColorEnabledRespectsNO_COLORAndTTY() {
        XCTAssertTrue(
            EventPrinter.colorEnabled(for: 2, environment: [:], isTTY: { _ in true }),
            "TTY and no NO_COLOR → color"
        )
        XCTAssertFalse(
            EventPrinter.colorEnabled(for: 2, environment: ["NO_COLOR": "1"], isTTY: { _ in true }),
            "NO_COLOR set → no color even on TTY"
        )
        XCTAssertFalse(
            EventPrinter.colorEnabled(for: 2, environment: [:], isTTY: { _ in false }),
            "non-TTY → no color"
        )
        XCTAssertTrue(
            EventPrinter.colorEnabled(for: 2, environment: ["NO_COLOR": ""], isTTY: { _ in true }),
            "empty NO_COLOR does not disable (no-color.org)"
        )
        XCTAssertFalse(
            EventPrinter.colorEnabled(for: 1, environment: ["NO_COLOR": "1"], isTTY: { _ in false })
        )
    }

    func testEmptyContentDeltaWritesNothing() {
        let cap = Capture()
        let printer = EventPrinter(
            colorStdout: true,
            colorStderr: true,
            writeStdout: { cap.writeOut($0) },
            writeStderr: { cap.writeErr($0) }
        )
        printer.handle(.contentDelta(""))
        XCTAssertEqual(cap.out, "")
        XCTAssertEqual(cap.err, "")
    }
}

// MARK: - C1 snapshot (exact strings from the uncolored printer)

private let c1Stdout = "hello[✓ grep]\n[✗ read_file]\n"
private let c1Stderr = """
[read_file] Read foo.swift
[✓ grep] match
[✗ read_file] no such file
[build ✓]
[build ✗] clang: error
[build skip] no xcodeproj
\n[done] completed
\n[error] boom
\n[stalled] read:x
\n[iteration cap 8]
[info] paused
[ask] continue?
""" + "\n"

private func replayC1Events(on printer: EventPrinter) {
    printer.handle(.contentDelta("hello"))
    printer.handle(.contentDelta(""))
    printer.handle(.reasoningDelta("think"))
    printer.handle(.toolStarted(id: "t1", name: "read_file", label: "Read foo.swift"))
    printer.handle(.toolCompleted(id: "t2", name: "grep", label: "Grep", isError: false))
    printer.handle(.toolCompleted(id: "t1", name: "read_file", label: "Read", isError: true))
    printer.handle(.toolResult(
        invocation: ToolCallInvocation(id: "t2", name: "grep", arguments: "{}"),
        result: ToolResult(content: "match\nrest", isError: false)
    ))
    printer.handle(.toolResult(
        invocation: ToolCallInvocation(id: "t1", name: "read_file", arguments: "{}"),
        result: ToolResult(content: "no such file", isError: true)
    ))
    printer.handle(.buildPassed)
    printer.handle(.buildFailed(log: "clang: error"))
    printer.handle(.buildSkipped(reason: "no xcodeproj"))
    printer.handle(.finished(reason: "completed"))
    printer.handle(.error(description: "boom"))
    printer.handle(.stalled(repeatedSignature: "read:x"))
    printer.handle(.iterationCapHit(cap: 8))
    printer.handle(.info("paused"))
    printer.handle(.pendingQuestion(AgentQuestion(question: "continue?")))
    printer.handle(.iterationStarted(iteration: 1))
}

private func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(
        of: "\u{001B}\\[[0-9;]*m",
        with: "",
        options: .regularExpression
    )
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = ""
    private var _err = ""

    var out: String { lock.lock(); defer { lock.unlock() }; return _out }
    var err: String { lock.lock(); defer { lock.unlock() }; return _err }

    func writeOut(_ s: String) { lock.lock(); _out += s; lock.unlock() }
    func writeErr(_ s: String) { lock.lock(); _err += s; lock.unlock() }
}
