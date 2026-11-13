import AppKit

@MainActor
final class RegionSelectionController {
    private var windows: [SelectionOverlayWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var keyMonitor: Any?
    private var isSelecting = false

    func begin(completion: @escaping (CGRect?) -> Void) {
        guard !isSelecting else { return }
        isSelecting = true
        self.completion = completion

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.finish(with: nil) }
                return nil
            }
            return event
        }

        windows = NSScreen.screens.map { screen in
            let window = SelectionOverlayWindow(screen: screen)
            window.selectionView.onFinish = { [weak self] rect in self?.finish(with: rect) }
            window.selectionView.onCancel = { [weak self] in self?.finish(with: nil) }
            return window
        }

        NSCursor.crosshair.push()
        for window in windows {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with rect: CGRect?) {
        guard isSelecting else { return }
        isSelecting = false

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        NSCursor.pop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        let completion = completion
        self.completion = nil
        completion?(rect)
    }
}

final class SelectionOverlayWindow: NSWindow {
    let selectionView: SelectionOverlayView

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        selectionView = SelectionOverlayView()
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: bufferingType,
            defer: flag
        )
        configureOverlay()
    }

    init(screen: NSScreen) {
        selectionView = SelectionOverlayView()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        configureOverlay()
    }

    private func configureOverlay() {
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionOverlayView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    private static let dimAlpha: CGFloat = 0.55
    private static let hintText = "Drag to select a region  ·  Esc to cancel"
    private static let accessibilityLabel = "Drag to select a region. Escape to cancel."
    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85)
    ]
    private static let dimensionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func configureView() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.accessibilityLabel)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = currentRect else {
            // No drag yet — fill the whole screen with the dark dim and show hint.
            NSColor.black.withAlphaComponent(Self.dimAlpha).setFill()
            bounds.fill()
            drawHint()
            return
        }

        // Dim everything outside the selection.
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.append(NSBezierPath(rect: rect))
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(Self.dimAlpha).setFill()
        dimPath.fill()

        // Selected region: clear fill so the screen content shows through.
        NSColor.clear.setFill()
        rect.fill()

        // Selection border.
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        border.stroke()

        drawDimensionsLabel(for: rect)
    }

    private func drawHint() {
        let textSize = Self.hintText.size(withAttributes: Self.hintAttributes)
        let pad: CGFloat = 10
        let boxW = textSize.width + pad * 2
        let boxH = textSize.height + pad * 2
        let boxRect = CGRect(
            x: bounds.midX - boxW / 2,
            y: bounds.midY - boxH / 2,
            width: boxW,
            height: boxH
        )
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 6, yRadius: 6).fill()
        Self.hintText.draw(
            at: CGPoint(x: boxRect.minX + pad, y: boxRect.minY + pad),
            withAttributes: Self.hintAttributes
        )
    }

    private func drawDimensionsLabel(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 1
        let pw = Int((rect.width  * scale).rounded())
        let ph = Int((rect.height * scale).rounded())
        let label = "\(pw) × \(ph)"

        let textSize = label.size(withAttributes: Self.dimensionAttributes)
        let pad: CGFloat = 5
        let boxW = textSize.width + pad * 2
        let boxH = textSize.height + pad * 2

        let bx = min(max(rect.maxX - boxW, bounds.minX), bounds.maxX - boxW)
        var by = rect.minY - boxH - 8
        if by < bounds.minY { by = rect.maxY + 8 }
        by = min(max(by, bounds.minY), bounds.maxY - boxH)

        let boxRect = CGRect(x: bx, y: by, width: boxW, height: boxH)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: boxRect.minX + pad, y: boxRect.minY + pad), withAttributes: Self.dimensionAttributes)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        guard let rect = currentRect, rect.width >= 8, rect.height >= 8, let window else {
            onFinish?(nil)
            return
        }
        let origin = window.convertPoint(toScreen: rect.origin)
        onFinish?(CGRect(origin: origin, size: rect.size).standardized)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private var currentRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        ).integral
    }
}
