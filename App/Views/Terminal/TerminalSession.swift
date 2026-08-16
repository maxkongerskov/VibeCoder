//
//  TerminalSession.swift
//  Wave U3 — one login-shell PTY per project cwd. Standalone of the agent loop.
//

import AppKit
import Combine
import Darwin
import Foundation

enum TerminalPtyError: Error, Equatable {
    case fork
}

/// Serial PTY I/O. Reads never run on the main actor.
final class TerminalPty: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tools.vibecoder.terminal.pty")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var killWorkItem: DispatchWorkItem?
    private var columns: Int = 80
    private var rows: Int = 24

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    var isRunning: Bool {
        queue.sync { childPID > 0 }
    }

    @inline(never)
    func spawn(shell: String, cwd: URL, columns: Int, rows: Int) -> Result<Void, TerminalPtyError> {
        teardown()
        self.columns = max(20, columns)
        self.rows = max(4, rows)
        let login = TerminalCwd.loginArgv0(forShell: shell)
        var outcome: Result<Void, TerminalPtyError> = .failure(.fork)
        var argv0 = Array(login.utf8CString)
        argv0.withUnsafeMutableBufferPointer { argv0Buf in
            cwd.path.withCString { cwdC in
                shell.withCString { shellC in
                    var argv: [UnsafeMutablePointer<CChar>?] = [argv0Buf.baseAddress, nil]
                    var master: Int32 = -1
                    var win = winsize(
                        ws_row: UInt16(clamping: self.rows),
                        ws_col: UInt16(clamping: self.columns),
                        ws_xpixel: 0,
                        ws_ypixel: 0
                    )
                    let pid = forkpty(&master, nil, nil, &win)
                    if pid == 0 {
                        _ = chdir(cwdC)
                        setenv("PWD", cwdC, 1)
                        setenv("TERM", "xterm-256color", 1)
                        setenv("SHELL", shellC, 1)
                        execv(shellC, &argv)
                        _exit(127)
                    }
                    if pid < 0 || master < 0 {
                        outcome = .failure(.fork)
                        return
                    }
                    self.install(master: master, pid: pid)
                    outcome = .success(())
                }
            }
        }
        return outcome
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            self?.writeLocked(data)
        }
    }

    func resize(columns: Int, rows: Int) {
        let cols = max(20, columns)
        let rws = max(4, rows)
        queue.async { [weak self] in
            guard let self else { return }
            self.columns = cols
            self.rows = rws
            guard self.masterFD >= 0 else { return }
            var win = winsize(
                ws_row: UInt16(clamping: rws),
                ws_col: UInt16(clamping: cols),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(self.masterFD, TIOCSWINSZ, &win)
        }
    }

    /// SIGTERM, then SIGKILL after 0.6s if the child is still alive.
    func terminate() {
        queue.async { [weak self] in
            guard let self, self.childPID > 0 else { return }
            let pid = self.childPID
            _ = kill(pid, SIGTERM)
            self.killWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.childPID == pid else { return }
                _ = kill(pid, SIGKILL)
                self.reapAndCloseLocked()
            }
            self.killWorkItem = work
            self.queue.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    func teardown() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardownLocked()
        } else {
            queue.sync { self.teardownLocked() }
        }
    }

    private func install(master: Int32, pid: pid_t) {
        queue.sync {
            self.masterFD = master
            self.childPID = pid
            let flags = fcntl(master, F_GETFL)
            if flags >= 0 {
                _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
            }
            _ = fcntl(master, F_SETFD, FD_CLOEXEC)
            self.startReaderLocked()
        }
    }

    private func startReaderLocked() {
        let fd = masterFD
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainLocked()
        }
        source.setCancelHandler { [weak self] in
            guard let self else {
                if fd >= 0 { close(fd) }
                return
            }
            if self.masterFD == fd {
                close(fd)
                self.masterFD = -1
            } else if fd >= 0 {
                close(fd)
            }
        }
        readSource = source
        source.resume()
    }

    private func drainLocked() {
        guard masterFD >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n: ssize_t = buf.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return read(self.masterFD, base, raw.count)
            }
            if n > 0 {
                onOutput?(Data(buf.prefix(Int(n))))
            } else if n == 0 {
                reapAndCloseLocked()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    return
                }
                reapAndCloseLocked()
                return
            }
        }
    }

    private func writeLocked(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n: ssize_t = bytes.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.write(self.masterFD, base + offset, bytes.count - offset)
            }
            if n > 0 {
                offset += Int(n)
            } else if n < 0 && (errno == EINTR) {
                continue
            } else {
                return
            }
        }
    }

    private func teardownLocked() {
        killWorkItem?.cancel()
        killWorkItem = nil
        if childPID > 0 {
            _ = kill(childPID, SIGKILL)
        }
        reapAndCloseLocked()
    }

    private func reapAndCloseLocked() {
        killWorkItem?.cancel()
        killWorkItem = nil
        let pid = childPID
        childPID = -1
        var status: Int32 = 0
        if pid > 0 {
            _ = waitpid(pid, &status, 0)
        }
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        if pid > 0 {
            onExit?(WaitStatus.exitCode(status))
        }
    }
}

/// Darwin `sys/wait.h` macros (not imported into Swift).
private enum WaitStatus {
    static func exitCode(_ status: Int32) -> Int32 {
        let wstatus = status & 0x7f
        if wstatus == 0 {
            return (status >> 8) & 0xff
        }
        if wstatus != 0x7f {
            return 128 + wstatus
        }
        return status
    }
}

@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var display = NSAttributedString()
    @Published private(set) var isAlive = false
    @Published private(set) var cwd: URL
    @Published private(set) var lastExitCode: Int32?

    private let pty = TerminalPty()
    private var emulator = TerminalEmulator()
    private var cwdIdentity: String
    private var columns = 80
    private var rows = 24

    init(cwd: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.cwd = cwd
        self.cwdIdentity = TerminalCwd.identity(of: cwd)
        attachCallbacks()
    }

    deinit {
        pty.teardown()
    }

    func ensureStarted(cwd: URL) {
        let identity = TerminalCwd.identity(of: cwd)
        if isAlive, cwdIdentity == identity { return }
        adoptCWD(cwd)
    }

    func adoptCWD(_ url: URL) {
        let identity = TerminalCwd.identity(of: url)
        if isAlive, cwdIdentity == identity { return }
        pty.teardown()
        cwd = url
        cwdIdentity = identity
        emulator = TerminalEmulator()
        lastExitCode = nil
        spawn()
        refreshDisplay()
    }

    func send(_ data: Data) {
        pty.write(data)
    }

    func terminate() {
        pty.terminate()
    }

    func setPixelSize(_ size: CGSize) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let cellW = max(font.maximumAdvancement.width, 1)
        let cellH = max(font.ascender - font.descender + font.leading, 1)
        let newCols = max(20, Int((size.width / cellW).rounded(.down)))
        let newRows = max(4, Int((size.height / cellH).rounded(.down)))
        guard newCols != columns || newRows != rows else { return }
        columns = newCols
        rows = newRows
        pty.resize(columns: columns, rows: rows)
    }

    func refreshDisplay() {
        let appearance = NSApp.effectiveAppearance
        display = emulator.buffer.attributedString(appearance: appearance, fontSize: 12)
    }

    private func spawn() {
        let shell = TerminalCwd.resolvedShell()
        switch pty.spawn(shell: shell, cwd: cwd, columns: columns, rows: rows) {
        case .success:
            isAlive = true
        case .failure:
            isAlive = false
            emulator.note("could not start shell: forkpty failed")
        }
    }

    private func attachCallbacks() {
        pty.onOutput = { [weak self] data in
            Task { @MainActor in
                self?.append(data)
            }
        }
        pty.onExit = { [weak self] code in
            Task { @MainActor in
                self?.handleExit(code)
            }
        }
    }

    private func handleExit(_ code: Int32) {
        // Ignore a reaped predecessor after adoptCWD has already spawned again.
        if pty.isRunning { return }
        isAlive = false
        lastExitCode = code
    }

    private func append(_ data: Data) {
        emulator.ingest(data)
        refreshDisplay()
    }
}
