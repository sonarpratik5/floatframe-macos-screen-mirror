import AppKit
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let view = ShortcutRecorderControl()
        view.onChange = { shortcut in
            self.shortcut = shortcut
        }
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderControl, context: Context) {
        nsView.shortcut = shortcut
    }
}

final class ShortcutRecorderControl: NSView {
    var onChange: ((KeyboardShortcut) -> Void)?
    var shortcut: KeyboardShortcut = .defaultSelection {
        didSet {
            guard oldValue != shortcut else { return }
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 30) }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape — cancel recording and resign
            window?.makeFirstResponder(nil)
            return
        }

        if event.keyCode == 48 { // Tab — pass through for focus-chain navigation
            super.keyDown(with: event)
            return
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let firstCharacter = characters.first,
              firstCharacter.isLetter || firstCharacter.isNumber else {
            NSSound.beep()
            return
        }

        let modifierFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !modifierFlags.isEmpty else {
            NSSound.beep()
            return
        }

        let newShortcut = KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: modifierFlags.carbonHotKeyModifiers,
            keyEquivalent: String(firstCharacter)
        )
        shortcut = newShortcut
        onChange?(newShortcut)
    }

    override func draw(_ dirtyRect: NSRect) {
        let isFocused = window?.firstResponder === self
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isFocused ? 2 : 1
        path.stroke()

        let text = isFocused ? "Record shortcut" : shortcut.glyphDisplayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        text.draw(at: point, withAttributes: attributes)
    }
}
