//
//  TestCapture.swift
//
//  Swift 5.10 on GitHub Actions rejects mutating a local `var` from a
//  @Sendable test callback. These boxes match FinishFlag / CallCounter
//  already used in other AgentCore tests.
//

import Foundation

final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool = false) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int
    init(_ n: Int = 0) { self.n = n }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return n }
        set { lock.lock(); n = newValue; lock.unlock() }
    }
    func increment() {
        lock.lock(); n += 1; lock.unlock()
    }
}

final class TestList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    func append(_ item: Element) {
        lock.lock(); items.append(item); lock.unlock()
    }
    var value: [Element] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}
