import AppKit
import AVFoundation
import CoreMedia

@MainActor
final class FloatingMirrorController: NSObject, NSWindowDelegate {
    let id = UUID()

    private let displayRegion: DisplayRegion
    private let panel: FloatingMirrorPanel
    private let contentView: MirrorContentView
    private let frameDispatcher: MirrorFrameDispatcher
    private let preferredPanelSize: CGSize
    private let onClose: (UUID) -> Void
    private var captureSession: RegionCaptureSession?
    private var isSnapping = false
    private var frameBeforeExpansion: CGRect?

    var isClickThrough: Bool { contentView.isClickThroughEnabled }
    var frame: CGRect { panel.frame }
    var preferredArrangementSize: CGSize { preferredPanelSize }
    var sourceVisibleFrame: CGRect { displayRegion.screen.visibleFrame }

    var sourceDisplayIsAvailable: Bool {
        NSScreen.screens.contains { $0.displayID == displayRegion.displayID }
    }

    init(displayRegion: DisplayRegion, onClose: @escaping (UUID) -> Void) {
        self.displayRegion = displayRegion
        self.contentView = MirrorContentView()
        self.frameDispatcher = MirrorFrameDispatcher()
        self.onClose = onClose

        let initialSize = FloatingMirrorController.initialPanelSize(for: displayRegion.screenRect.size)
        self.preferredPanelSize = initialSize
        let initialOrigin = FloatingMirrorController.initialPanelOrigin(size: initialSize, on: displayRegion.screen)
        panel = FloatingMirrorPanel(contentRect: CGRect(origin: initialOrigin, size: initialSize))

        super.init()

        frameDispatcher.contentView = contentView
        panel.delegate = self
        panel.contentView = contentView
        panel.contentAspectRatio = displayRegion.screenRect.size
        panel.title = "Popup Mirror"
        panel.alphaValue = PopupPreferences.panelOpacity
        panel.ignoresMouseEvents = false
        contentView.setVideoCropRect(displayRegion.videoCropRect, streamOutputSize: displayRegion.streamOutputSize)

        contentView.onClose = { [weak self] in
            self?.close()
        }
        contentView.onToggleClickThrough = { [weak self] enabled in
            self?.setClickThrough(enabled, persist: true)
        }
        contentView.onToggleExpansion = { [weak self] in
            self?.toggleExpansion()
        }
        contentView.onRestart = { [weak self] in
            Task { @MainActor in
                try? await self?.restartCapture()
            }
        }
        contentView.setClickThrough(PopupPreferences.clickThrough)

        createCaptureSession()
    }

    func start() async throws {
        try await captureSession?.start()
        panel.orderFrontRegardless()
    }

    func keepOnTop() {
        panel.orderFrontRegardless()
    }

    func close() {
        captureSession?.stop()
        captureSession = nil
        panel.close()
    }

    // Awaitable variant used during app termination. Waits for the SCStream XPC
    // stop to complete before closing the panel, preventing the process from
    // lingering in Activity Monitor with a live XPC call in flight.
    func closeAndWait() async {
        let session = captureSession
        captureSession = nil
        await session?.stopAndWait()
        panel.close()
    }

    func closeWithMessage(_ message: String) {
        captureSession?.stop()
        captureSession = nil
        contentView.showStatus(message, canRestart: false)
        keepVisibleOnCurrentDisplays()
    }

    func applyPreferences() {
        setOpacity(PopupPreferences.panelOpacity)
        setClickThrough(PopupPreferences.clickThrough, persist: false)
    }

    func setClickThrough(_ enabled: Bool, persist: Bool = false) {
        panel.ignoresMouseEvents = false
        contentView.setClickThrough(enabled)
        if persist {
            PopupPreferences.clickThrough = enabled
        }
    }

    func keepVisibleOnCurrentDisplays() {
        guard let visibleFrame = NSScreen.visibleFrame(containing: panel.frame) else { return }
        panel.setFrame(MirrorPanelLayout.constrainedFrame(panel.frame, to: visibleFrame), display: true)
    }

    func setArrangedFrame(_ frame: CGRect) {
        frameBeforeExpansion = nil
        contentView.setExpanded(false)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    func windowDidMove(_ notification: Notification) {
        snapToNearestCornerIfNeeded()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        snapToNearestCornerIfNeeded()
    }

    func windowWillMiniaturize(_ notification: Notification) {
        panel.deminiaturize(nil)
        keepOnTop()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        panel.deminiaturize(nil)
        keepOnTop()
    }

    func windowWillClose(_ notification: Notification) {
        captureSession?.stop()
        captureSession = nil
        onClose(id)
    }

    private func createCaptureSession() {
        captureSession = RegionCaptureSession(
            displayRegion: displayRegion,
            frameHandler: { [frameDispatcher] sampleBuffer in
                frameDispatcher.enqueue(sampleBuffer)
            },
            failureHandler: { [weak self] error in
                DispatchQueue.main.async {
                    self?.captureDidFail(error)
                }
            }
        )
    }

    private func restartCapture() async throws {
        guard sourceDisplayIsAvailable else {
            contentView.showStatus("Source display unavailable", canRestart: false)
            return
        }

        contentView.hideStatus()
        captureSession?.stop()
        createCaptureSession()

        do {
            try await captureSession?.start()
        } catch {
            captureDidFail(error)
            throw error
        }
    }

    private func captureDidFail(_ error: Error) {
        captureSession?.stop()
        captureSession = nil
        contentView.showStatus(error.localizedDescription, canRestart: sourceDisplayIsAvailable)
    }

    private func setOpacity(_ opacity: Double) {
        let clamped = PopupPreferences.clamped(opacity, to: PopupPreferences.panelOpacityRange)
        panel.alphaValue = clamped
    }

    private func toggleExpansion() {
        if let restoreFrame = frameBeforeExpansion {
            frameBeforeExpansion = nil
            contentView.setExpanded(false)
            panel.setFrame(restoreFrame, display: true, animate: true)
            return
        }

        guard let visibleFrame = NSScreen.visibleFrame(containing: panel.frame) else { return }
        frameBeforeExpansion = panel.frame
        contentView.setExpanded(true)
        let aspectRatio = displayRegion.screenRect.width / max(displayRegion.screenRect.height, 1)
        panel.setFrame(
            MirrorPanelLayout.expandedFrame(for: aspectRatio, in: visibleFrame),
            display: true,
            animate: true
        )
    }

    private func snapToNearestCornerIfNeeded() {
        guard !isSnapping,
              frameBeforeExpansion == nil,
              let visibleFrame = NSScreen.visibleFrame(containing: panel.frame) else { return }

        let frame = panel.frame
        let origin = MirrorPanelLayout.snappedOrigin(for: frame, in: visibleFrame)

        guard origin != frame.origin else { return }
        isSnapping = true
        panel.setFrameOrigin(origin)
        isSnapping = false
    }

    private static func initialPanelSize(for sourceSize: CGSize) -> CGSize {
        MirrorPanelLayout.initialSize(for: sourceSize)
    }

    private static func initialPanelOrigin(size: CGSize, on screen: NSScreen) -> CGPoint {
        MirrorPanelLayout.initialOrigin(for: size, in: screen.visibleFrame)
    }
}

final class FloatingMirrorPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        // .stationary prevented the panel from re-appearing after Space transitions.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .black
        isMovableByWindowBackground = true
        hasShadow = true
        minSize = CGSize(width: CGFloat(PopupPreferences.panelWidthRange.lowerBound), height: 90)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func miniaturize(_ sender: Any?) {
        orderFrontRegardless()
    }

    override func performMiniaturize(_ sender: Any?) {
        orderFrontRegardless()
    }

    // Prevent the system from hiding the panel when the accessory app deactivates.
    // On macOS 26 the setter can be called internally even after init sets it to false.
    override var hidesOnDeactivate: Bool {
        get { false }
        set { }
    }
}

final class MirrorContentView: NSView {
    private static let expandImage = NSImage(
        systemSymbolName: "arrow.up.left.and.arrow.down.right",
        accessibilityDescription: "Temporarily Expand"
    )
    private static let restoreImage = NSImage(
        systemSymbolName: "arrow.down.right.and.arrow.up.left",
        accessibilityDescription: "Restore Size"
    )

    var onClose: (() -> Void)?
    var onToggleClickThrough: ((Bool) -> Void)?
    var onToggleExpansion: (() -> Void)?
    var onRestart: (() -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let controlsView = NSVisualEffectView()
    private let closeButton = MirrorControlButton()
    private let expandButton = MirrorControlButton()
    private let clickThroughButton = MirrorControlButton()
    private let statusContainer = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
    private var hideControlsTask: DispatchWorkItem?
    private var videoCropRect: CGRect?
    private var streamOutputSize: CGSize = .zero
    private var isExpanded: Bool?
    private(set) var isClickThroughEnabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
        configureControls()
        configureStatusView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
        configureControls()
        configureStatusView()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let displayFrame = videoFrame(for: bounds)
        if displayLayer.frame != displayFrame {
            displayLayer.frame = displayFrame
        }
        CATransaction.commit()

        let controlsWidth = MirrorPanelLayout.controlsWidth(for: bounds.width)
        let controlsFrame = CGRect(
            x: bounds.width - controlsWidth - MirrorPanelLayout.controlsHorizontalInset,
            y: bounds.height - 36,
            width: controlsWidth,
            height: 28
        )
        if controlsView.frame != controlsFrame {
            controlsView.frame = controlsFrame
        }

        let statusFrame = bounds.insetBy(dx: 18, dy: max(18, bounds.height * 0.25))
        if statusContainer.frame != statusFrame {
            statusContainer.frame = statusFrame
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sampleBuffer)
    }

    func setVideoCropRect(_ cropRect: CGRect?, streamOutputSize: CGSize) {
        guard videoCropRect != cropRect || self.streamOutputSize != streamOutputSize else { return }
        videoCropRect = cropRect
        self.streamOutputSize = streamOutputSize
        needsLayout = true
    }

    func setClickThrough(_ enabled: Bool) {
        isClickThroughEnabled = enabled
        clickThroughButton.state = enabled ? .on : .off
        clickThroughButton.contentTintColor = enabled ? .controlAccentColor : .labelColor
        if enabled {
            setControlsVisible(true, delay: 0)
        } else {
            // When click-through is re-enabled for mouse events, show controls if the
            // cursor is already inside the panel (mouseEntered won't re-fire on its own).
            updateHoverStateFromCurrentMousePosition()
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        expandButton.state = expanded ? .on : .off
        expandButton.image = expanded ? Self.restoreImage : Self.expandImage
        expandButton.toolTip = expanded ? "Restore Size" : "Temporarily Expand"
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateHoverStateFromCurrentMousePosition()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        guard let hitView, isClickThroughEnabled else { return hitView }

        return hitView.isDescendant(of: controlsView) || hitView.isDescendant(of: statusContainer) ? hitView : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hideControlsTask?.cancel()
        hideControlsTask = nil
        setControlsVisible(true, delay: 0)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isClickThroughEnabled else { return }
        setControlsVisible(false, delay: 0.6)
    }

    private func setControlsVisible(_ visible: Bool, delay: TimeInterval) {
        guard visible || !isClickThroughEnabled else { return }
        hideControlsTask?.cancel()
        hideControlsTask = nil

        if delay > 0 && !visible {
            let task = DispatchWorkItem { [weak self] in
                self?.animateControls(visible: false)
            }
            hideControlsTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        } else {
            animateControls(visible: visible)
        }
    }

    private func animateControls(visible: Bool) {
        let targetAlpha: CGFloat = visible ? 1 : 0
        guard abs(controlsView.alphaValue - targetAlpha) > 0.001 else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.15 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            controlsView.animator().alphaValue = targetAlpha
        }
    }

    private func updateHoverStateFromCurrentMousePosition() {
        guard let window else { return }
        let mouseInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setControlsVisible(bounds.contains(mouseInView), delay: 0)
    }

    func showStatus(_ message: String, canRestart: Bool) {
        statusLabel.stringValue = message
        restartButton.isHidden = !canRestart
        statusContainer.isHidden = false
    }

    func hideStatus() {
        statusContainer.isHidden = true
    }

    @objc private func closeButtonPressed() {
        onClose?()
    }

    @objc private func clickThroughPressed() {
        onToggleClickThrough?(clickThroughButton.state == .on)
    }

    @objc private func expandPressed() {
        onToggleExpansion?()
    }

    @objc private func restartPressed() {
        onRestart?()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    private func videoFrame(for bounds: CGRect) -> CGRect {
        MirrorPanelLayout.videoFrame(
            in: bounds,
            cropRect: videoCropRect,
            streamOutputSize: streamOutputSize
        )
    }

    private func configureControls() {
        controlsView.material = .hudWindow
        controlsView.blendingMode = .withinWindow
        controlsView.state = .active
        controlsView.wantsLayer = true
        controlsView.layer?.cornerRadius = 6
        controlsView.alphaValue = 0
        controlsView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(controlsView)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.bezelStyle = .automatic
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed)
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.toolTip = "Close Mirror"

        expandButton.bezelStyle = .automatic
        expandButton.isBordered = false
        expandButton.target = self
        expandButton.action = #selector(expandPressed)
        expandButton.setButtonType(.toggle)
        setExpanded(false)

        clickThroughButton.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Click Through")
        clickThroughButton.bezelStyle = .automatic
        clickThroughButton.isBordered = false
        clickThroughButton.setButtonType(.toggle)
        clickThroughButton.target = self
        clickThroughButton.action = #selector(clickThroughPressed)
        clickThroughButton.toolTip = "Click Through"

        let stack = NSStackView(views: [closeButton, expandButton, clickThroughButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(stack)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            expandButton.widthAnchor.constraint(equalToConstant: 20),
            expandButton.heightAnchor.constraint(equalToConstant: 20),
            clickThroughButton.widthAnchor.constraint(equalToConstant: 20),
            clickThroughButton.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controlsView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor)
        ])
    }

    private func configureStatusView() {
        statusContainer.material = .hudWindow
        statusContainer.blendingMode = .withinWindow
        statusContainer.state = .active
        statusContainer.wantsLayer = true
        statusContainer.layer?.cornerRadius = 8
        statusContainer.isHidden = true
        addSubview(statusContainer)

        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        restartButton.target = self
        restartButton.action = #selector(restartPressed)
        restartButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [statusLabel, restartButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor)
        ])
    }
}

private final class MirrorFrameDispatcher: @unchecked Sendable {
    weak var contentView: MirrorContentView?

    private let lock = NSLock()
    private var pendingFrame: CMSampleBuffer?
    private var isDrainScheduled = false

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let shouldSchedule = lock.withLock {
            pendingFrame = sampleBuffer
            guard !isDrainScheduled else { return false }
            isDrainScheduled = true
            return true
        }

        if shouldSchedule {
            scheduleDrain()
        }
    }

    private func scheduleDrain() {
        DispatchQueue.main.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        let frame = lock.withLock {
            let frame = pendingFrame
            pendingFrame = nil
            return frame
        }

        if let frame {
            contentView?.enqueue(frame)
        }

        let shouldContinue = lock.withLock {
            if pendingFrame != nil {
                return true
            }
            isDrainScheduled = false
            return false
        }

        if shouldContinue {
            scheduleDrain()
        }
    }
}

private final class MirrorControlButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private extension NSView {
    func isDescendant(of ancestor: NSView) -> Bool {
        var view: NSView? = self
        while let currentView = view {
            if currentView === ancestor { return true }
            view = currentView.superview
        }
        return false
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func visibleFrame(containing rect: CGRect) -> CGRect? {
        if let screen = bestScreen(containing: rect) {
            return screen.visibleFrame
        }

        return screens.first?.visibleFrame
    }

    private static func bestScreen(containing rect: CGRect) -> NSScreen? {
        var bestScreen: NSScreen?
        var bestIntersectionArea: CGFloat = 0

        for screen in screens {
            let intersectionArea = screen.frame.intersectionArea(with: rect)
            guard intersectionArea > bestIntersectionArea else { continue }
            bestScreen = screen
            bestIntersectionArea = intersectionArea
        }

        return bestScreen
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    func intersectionArea(with rect: CGRect) -> CGFloat {
        intersection(rect).area
    }
}
