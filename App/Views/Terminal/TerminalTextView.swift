//
//  TerminalTextView.swift
//  Wave U3 — NSTextView that displays PTY output and writes keystrokes to the master.
//

import AppKit
import SwiftUI

struct TerminalTextView: NSViewRepresentable {
    var attributed: NSAttributedString
    var fixedGrid: Bool
    var applicationCursorKeys: Bool
    var onInput: (Data) -> Void
    var onPaste: (String) -> Void
    var onResize: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onPaste: onPaste, onResize: onResize)
    }

    func makeNSView(context: Context) -> TerminalScrollView {
        let scroll = TerminalScrollView()
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.onResize = context.coordinator.onResize

        let text = TerminalNSTextView(frame: .zero)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = TerminalMetrics.inset
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.allowsUndo = false
        text.usesFindBar = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.focusRingType = .none
        text.onSend = context.coordinator.onInput
        text.onPaste = context.coordinator.onPaste
        text.applicationCursorKeys = applicationCursorKeys
        text.setAccessibilityElement(true)
        text.setAccessibilityRole(.textArea)
        text.setAccessibilityLabel("Terminal output")
        text.setAccessibilityValue(attributed.string)
        text.defaultParagraphStyle = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            return paragraph
        }()
        applyChrome(scroll: scroll, text: text)

        scroll.documentView = text
        context.coordinator.textView = text
        DispatchQueue.main.async {
            scroll.window?.makeFirstResponder(text)
            context.coordinator.onResize(scroll.contentSize)
        }
        return scroll
    }

    func updateNSView(_ scroll: TerminalScrollView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onPaste = onPaste
        context.coordinator.onResize = onResize
        scroll.onResize = onResize
        guard let text = scroll.documentView as? TerminalNSTextView else { return }
        text.onSend = onInput
        text.onPaste = onPaste
        text.applicationCursorKeys = applicationCursorKeys
        text.setAccessibilityValue(attributed.string)
        applyChrome(scroll: scroll, text: text)

        scroll.hasVerticalScroller = !fixedGrid
        let wasNearBottom = Self.isNearBottom(scroll)
        let selected = text.selectedRange()
        if let storage = text.textStorage {
            storage.setAttributedString(attributed)
        }
        let length = (text.string as NSString).length
        if selected.length > 0, selected.location + selected.length <= length {
            text.setSelectedRange(selected)
        } else if fixedGrid {
            text.scrollToBeginningOfDocument(nil)
        } else if wasNearBottom {
            text.scrollToEndOfDocument(nil)
        }
    }

    private func applyChrome(scroll: NSScrollView, text: NSTextView) {
        let bg = TerminalMetrics.canvasColor
        scroll.backgroundColor = bg
        scroll.drawsBackground = true
        text.backgroundColor = bg
        text.drawsBackground = true
        text.insertionPointColor = TerminalMetrics.textColor
        text.selectedTextAttributes = [
            .backgroundColor: TerminalMetrics.selectionColor,
            .foregroundColor: TerminalMetrics.textColor,
        ]
    }

    private static func isNearBottom(_ scroll: NSScrollView) -> Bool {
        let docH = scroll.documentView?.bounds.height ?? 0
        let clip = scroll.contentView.bounds
        return docH - clip.maxY < 32
    }

    final class Coordinator {
        var onInput: (Data) -> Void
        var onPaste: (String) -> Void
        var onResize: (CGSize) -> Void
        weak var textView: TerminalNSTextView?

        init(
            onInput: @escaping (Data) -> Void,
            onPaste: @escaping (String) -> Void,
            onResize: @escaping (CGSize) -> Void
        ) {
            self.onInput = onInput
            self.onPaste = onPaste
            self.onResize = onResize
        }
    }
}

final class TerminalScrollView: NSScrollView {
    var onResize: ((CGSize) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(contentSize)
    }
}

final class TerminalNSTextView: NSTextView {
    var onSend: ((Data) -> Void)?
    var applicationCursorKeys = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            setAccessibilityFocused(true)
        }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func accessibilityValue() -> String? {
        string
    }

    override func keyDown(with event: NSEvent) {
        if let data = TerminalKeyEncoder.data(for: event, applicationCursorKeys: applicationCursorKeys) {
            onSend?(data)
            return
        }
        super.keyDown(with: event)
    }

    var onPaste: ((String) -> Void)?

    override func paste(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string), !string.isEmpty {
            if let onPaste {
                onPaste(string)
            } else {
                onSend?(Data(string.utf8))
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "v" {
                paste(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let string = insertString as? String, !string.isEmpty {
            onSend?(Data(string.utf8))
        }
    }
}

enum TerminalKeyEncoder {
    static func data(for event: NSEvent, applicationCursorKeys: Bool = false) -> Data? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }

        if flags.contains(.control),
           let raw = event.charactersIgnoringModifiers?.lowercased(),
           let scalar = raw.unicodeScalars.first,
           scalar.isASCII {
            let value = scalar.value
            if value >= 97 && value <= 122 {
                return Data([UInt8(value - 96)])
            }
            if value == 64 { return Data([0x00]) }
            if value == 91 { return Data([0x1b]) }
            if value == 92 { return Data([0x1c]) }
            if value == 93 { return Data([0x1d]) }
        }

        switch event.keyCode {
        case 126: return cursorKey(applicationCursorKeys, 0x41)
        case 125: return cursorKey(applicationCursorKeys, 0x42)
        case 124: return cursorKey(applicationCursorKeys, 0x43)
        case 123: return cursorKey(applicationCursorKeys, 0x44)
        case 36, 76: return Data([0x0d])
        case 48: return Data([0x09])
        case 51: return Data([0x7f])
        case 53: return Data([0x1b])
        case 115: return cursorKey(applicationCursorKeys, 0x48)
        case 119: return cursorKey(applicationCursorKeys, 0x46)
        case 116: return Data([0x1b, 0x5b, 0x35, 0x7e])
        case 121: return Data([0x1b, 0x5b, 0x36, 0x7e])
        default:
            break
        }

        if let chars = event.characters, !chars.isEmpty {
            return Data(chars.utf8)
        }
        return nil
    }

    private static func cursorKey(_ application: Bool, _ final: UInt8) -> Data {
        application ? Data([0x1b, 0x4f, final]) : Data([0x1b, 0x5b, final])
    }
}
