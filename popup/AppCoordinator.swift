import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSMenuDelegate, NSWindowDelegate {
    static weak var shared: AppCoordinator?

    private let skipsMirrorCreationForUITests: Bool
    private var selectionController: RegionSelectionController?
    private var mirrors: [UUID: FloatingMirrorController] = [:]
    private var mirrorOrder: [UUID] = []
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var registeredShortcut: KeyboardShortcut?
    private var settingsWindow: NSWindow?
    private var isRunning = false
    private var selectionTask: Task<Void, Never>?
    private var selectionTaskID: UUID?
    private var mirrorStartupTasks: [UUID: Task<Void, Never>] = [:]

    // Status-bar item (replaces the SwiftUI MenuBarExtra scene).
    private var statusItem: NSStatusItem?
    private var selectRegionMenuItem: NSMenuItem?
    private weak var opacityMenuSlider: NSSlider?
    private weak var opacityMenuValueLabel: NSTextField?
    private var disableClickThroughMenuItem: NSMenuItem?
    private var closeAllMirrorsMenuItem: NSMenuItem?

    var hasClickThroughMirrors: Bool { mirrors.values.contains { $0.isClickThrough } }
    var hasMirrors: Bool { !mirrors.isEmpty }

    init(skipsMirrorCreationForUITests: Bool = false) {
        self.skipsMirrorCreationForUITests = skipsMirrorCreationForUITests
        super.init()
    }

    func start() {
        guard !isRunning else { return }

        isRunning = true
        AppCoordinator.shared = self
        setupStatusItem()
        installGlobalShortcut()
        observePreferences()
        observeDisplayChanges()
        observeAppDeactivation()
    }

    func stop() {
        isRunning = false
        selectionTask?.cancel()
        selectionTask = nil
        selectionTaskID = nil
        selectionController?.cancel()
        selectionController = nil
        cancelMirrorStartups()

        teardownStatusItem()
        unregisterGlobalShortcut()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        NotificationCenter.default.removeObserver(self)

        for mirror in Array(mirrors.values) {
            mirror.close()
        }
        mirrors.removeAll()
        mirrorOrder.removeAll()
    }

    // Awaitable teardown used during app termination. Unregisters shortcuts and
    // observers synchronously (preventing new mirrors from being created while we
    // clean up), then concurrently awaits each mirror's SCStream XPC stop so the
    // process can exit without leaving orphaned XPC calls in flight.
    func stopAndWait() async {
        isRunning = false
        selectionTask?.cancel()
        selectionTask = nil
        selectionTaskID = nil
        cancelMirrorStartups()

        teardownStatusItem()
        unregisterGlobalShortcut()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        // Cancel any active selection overlay so its windows and event monitors
        // are removed before the process exits.
        selectionController?.cancel()
        selectionController = nil

        NotificationCenter.default.removeObserver(self)

        await withTaskGroup(of: Void.self) { group in
            for mirror in Array(mirrors.values) {
                group.addTask { await mirror.closeAndWait() }
            }
        }
        mirrors.removeAll()
        mirrorOrder.removeAll()
    }

    func beginSelection() {
        guard isRunning, selectionController == nil, selectionTask == nil else { return }
        let taskID = UUID()
        selectionTaskID = taskID
        selectionTask = Task { @MainActor [weak self] in
            defer {
                if self?.selectionTaskID == taskID {
                    self?.selectionTask = nil
                    self?.selectionTaskID = nil
                }
            }

            // Wait for any menu/popover dismiss animation to complete before showing
            // the overlay. Without this, the overlay windows are created while the
            // app is still mid-transition and never receive mouse events.
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard let self, self.isRunning, self.selectionController == nil else { return }

            // Request activation for keyboard handling; the overlay also accepts
            // first mouse so dragging works if activation is not granted.
            NSApp.activate()

            let controller = RegionSelectionController()
            self.selectionController = controller
            controller.begin { [weak self] rect in
                Task { @MainActor in
                    self?.selectionController = nil
                    guard let self, self.isRunning, let rect else { return }
                    guard !self.skipsMirrorCreationForUITests else { return }
                    self.createMirror(for: rect)
                }
            }
        }
    }

    func disableClickThrough() {
        PopupPreferences.clickThrough = false
        for mirror in mirrors.values {
            mirror.setClickThrough(false)
        }
    }

    func closeAllMirrors() {
        for mirror in Array(mirrors.values) {
            mirror.close()
        }
        mirrors.removeAll()
        mirrorOrder.removeAll()
    }

    func openSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Popup Settings"
        window.contentView = NSHostingView(rootView: ContentView())
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        settingsWindow = nil
    }

    private func createMirror(for screenRect: CGRect) {
        guard isRunning else { return }

        let startupID = UUID()
        mirrorStartupTasks[startupID] = Task { @MainActor [weak self] in
            defer { self?.mirrorStartupTasks[startupID] = nil }
            guard let self, self.isRunning else { return }

            await MirrorStartup.start(
                makeMirror: {
                    let displayRegion = try await CaptureGeometry.displayRegion(containing: screenRect)
                    try Task.checkCancellation()
                    return FloatingMirrorController(displayRegion: displayRegion) { [weak self] id in
                        guard let self else { return }
                        self.mirrors[id] = nil
                        self.mirrorOrder.removeAll { $0 == id }
                        self.arrangeMirrors()
                    }
                },
                start: { mirror in
                    try Task.checkCancellation()
                    try await mirror.start()
                    try Task.checkCancellation()
                },
                didStart: { mirror in
                    guard self.isRunning else {
                        mirror.close()
                        return
                    }
                    self.mirrors[mirror.id] = mirror
                    self.mirrorOrder.append(mirror.id)
                    self.arrangeMirrors()
                },
                didFailToStart: { mirror, error in
                    mirror.close()
                    guard !Task.isCancelled, !(error is CancellationError), self.isRunning else { return }
                    self.showCaptureError(error)
                },
                didFailToCreate: { error in
                    guard !Task.isCancelled, !(error is CancellationError), self.isRunning else { return }
                    self.showCaptureError(error)
                }
            )
        }
    }

    private func cancelMirrorStartups() {
        for task in mirrorStartupTasks.values {
            task.cancel()
        }
        mirrorStartupTasks.removeAll()
    }

    private func showCaptureError(_ error: Error) {
        let captureError = CaptureSessionError(error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Popup could not start screen capture"
        alert.informativeText = captureError.localizedDescription

        if captureError.opensScreenRecordingSettings {
            alert.addButton(withTitle: "Open Screen Recording Settings")
            alert.addButton(withTitle: "Quit Popup")
            alert.addButton(withTitle: "OK")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                ScreenRecordingSettings.open()
            case .alertSecondButtonReturn:
                NSApp.terminate(nil)
            default:
                break
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func observePreferences() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChangeNotification),
            name: PopupPreferences.didChangeNotification,
            object: nil
        )
    }

    @objc private func preferencesDidChangeNotification() {
        installGlobalShortcut()
        updateMenuShortcut()
        updateOpacityMenuItem()
        for mirror in mirrors.values {
            mirror.applyPreferences()
        }
    }

    private func observeDisplayChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func displayConfigurationDidChange() {
        selectionController?.cancel()
        var disconnectedIDs: [UUID] = []
        for (id, mirror) in mirrors {
            if mirror.sourceDisplayIsAvailable {
                mirror.keepVisibleOnCurrentDisplays()
            } else {
                mirror.closeWithMessage("Source display disconnected")
                disconnectedIDs.append(id)
            }
        }
        // Remove disconnected mirrors before arranging so they don't skew group
        // counts or receive erroneous setArrangedFrame calls. The panel stays
        // visible showing the error until the user closes it manually.
        for id in disconnectedIDs {
            mirrors[id] = nil
            mirrorOrder.removeAll { $0 == id }
        }
        arrangeMirrors()
    }

    private func arrangeMirrors() {
        let orderedMirrors = mirrorOrder.compactMap { mirrors[$0] }
        var groups: [(visibleFrame: CGRect, mirrors: [FloatingMirrorController])] = []

        for mirror in orderedMirrors {
            let visibleFrame = mirror.sourceVisibleFrame
            if let index = groups.firstIndex(where: { $0.visibleFrame == visibleFrame }) {
                groups[index].mirrors.append(mirror)
            } else {
                groups.append((visibleFrame, [mirror]))
            }
        }

        for group in groups {
            arrangeMirrors(group.mirrors, in: group.visibleFrame)
        }
    }

    private func arrangeMirrors(_ orderedMirrors: [FloatingMirrorController], in targetVisibleFrame: CGRect) {
        let panelSize = commonPanelSize(for: orderedMirrors)
        guard panelSize != .zero else { return }

        let frames = MirrorPanelLayout.stackedFrames(
            count: orderedMirrors.count,
            panelSize: panelSize,
            in: targetVisibleFrame
        )

        for (mirror, frame) in zip(orderedMirrors, frames) {
            mirror.setArrangedFrame(frame)
        }
    }

    private func commonPanelSize(for mirrors: [FloatingMirrorController]) -> CGSize {
        MirrorPanelLayout.commonPanelSize(for: mirrors.map(\.preferredArrangementSize))
    }

    private func observeAppDeactivation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    // Accessory apps can have their panels hidden by macOS on deactivation even
    // when hidesOnDeactivate = false. Re-ordering them front immediately after
    // deactivation keeps the mirrors always visible above other app windows.
    @objc private func applicationDidResignActive() {
        for mirror in mirrors.values {
            mirror.keepOnTop()
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle.circle",
                                     accessibilityDescription: "Popup")
        item.button?.toolTip = "Popup"

        let menu = NSMenu()
        menu.delegate = self

        let shortcut = PopupPreferences.selectionShortcut

        let selectItem = NSMenuItem(title: "Select Region",
                                    action: #selector(selectRegionMenuAction),
                                    keyEquivalent: shortcut.keyEquivalent)
        selectItem.keyEquivalentModifierMask = shortcut.menuModifierMask
        selectItem.target = self

        let opacityItem = makeOpacityMenuItem()

        let disableClickThrough = NSMenuItem(title: "Disable Click-Through",
                                              action: #selector(disableClickThroughMenuAction),
                                              keyEquivalent: "")
        disableClickThrough.target = self

        let closeAll = NSMenuItem(title: "Close All Mirrors",
                                   action: #selector(closeAllMirrorsMenuAction),
                                   keyEquivalent: "")
        closeAll.target = self

        let openSettings = NSMenuItem(title: "Open Settings\u{2026}",
                                       action: #selector(openSettingsMenuAction),
                                       keyEquivalent: ",")
        openSettings.keyEquivalentModifierMask = .command
        openSettings.target = self

        let quit = NSMenuItem(title: "Quit Popup",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command

        menu.addItem(selectItem)
        menu.addItem(.separator())
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        menu.addItem(disableClickThrough)
        menu.addItem(closeAll)
        menu.addItem(.separator())
        menu.addItem(openSettings)
        menu.addItem(.separator())
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        selectRegionMenuItem = selectItem
        disableClickThroughMenuItem = disableClickThrough
        closeAllMirrorsMenuItem = closeAll
    }

    private func makeOpacityMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))

        let icon = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Opacity") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Opacity")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(
            value: PopupPreferences.panelOpacity,
            minValue: PopupPreferences.panelOpacityRange.lowerBound,
            maxValue: PopupPreferences.panelOpacityRange.upperBound,
            target: self,
            action: #selector(opacityMenuSliderChanged(_:))
        )
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(label)
        container.addSubview(valueLabel)
        container.addSubview(slider)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 44),

            slider.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: valueLabel.trailingAnchor),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4)
        ])

        opacityMenuSlider = slider
        opacityMenuValueLabel = valueLabel
        item.view = container
        updateOpacityMenuItem()
        return item
    }

    private func teardownStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        selectRegionMenuItem = nil
        opacityMenuSlider = nil
        opacityMenuValueLabel = nil
        disableClickThroughMenuItem = nil
        closeAllMirrorsMenuItem = nil
    }

    private func updateMenuShortcut() {
        let shortcut = PopupPreferences.selectionShortcut
        selectRegionMenuItem?.keyEquivalent = shortcut.keyEquivalent
        selectRegionMenuItem?.keyEquivalentModifierMask = shortcut.menuModifierMask
    }

    private func updateOpacityMenuItem() {
        let opacity = PopupPreferences.panelOpacity
        opacityMenuSlider?.doubleValue = opacity
        opacityMenuValueLabel?.stringValue = opacity.formatted(.percent.precision(.fractionLength(0)))
    }

    // Called just before the menu opens so enabled states are always current.
    func menuWillOpen(_ menu: NSMenu) {
        updateOpacityMenuItem()
        disableClickThroughMenuItem?.isEnabled = hasClickThroughMirrors
        closeAllMirrorsMenuItem?.isEnabled = hasMirrors
    }

    @objc private func selectRegionMenuAction() { beginSelection() }
    @objc private func opacityMenuSliderChanged(_ sender: NSSlider) {
        PopupPreferences.panelOpacity = sender.doubleValue
        updateOpacityMenuItem()
    }
    @objc private func disableClickThroughMenuAction() { disableClickThrough() }
    @objc private func closeAllMirrorsMenuAction() { closeAllMirrors() }

    @objc private func openSettingsMenuAction() {
        openSettingsWindow()
    }

    // MARK: - Global Shortcut

    private func installGlobalShortcut() {
        let shortcut = PopupPreferences.selectionShortcut
        guard registeredShortcut != shortcut || hotKeyRef == nil else { return }

        unregisterGlobalShortcut()

        let hotKeyID = EventHotKeyID(signature: OSType("POP1".fourCharCode), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            hotKeyRef = nil
            registeredShortcut = nil
            return
        }

        registeredShortcut = shortcut
        installHotKeyEventHandlerIfNeeded()
    }

    private func unregisterGlobalShortcut() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredShortcut = nil
    }

    private func installHotKeyEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr, hotKeyID.id == 1 else { return status }
            let coordinator = Unmanaged<AppCoordinator>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                coordinator.beginSelection()
            }
            return noErr
        }, 1, &eventSpec, selfPointer, &eventHandlerRef)
    }
}

enum MirrorStartup {
    @MainActor
    static func start<Mirror>(
        makeMirror: () async throws -> Mirror,
        start: (Mirror) async throws -> Void,
        didStart: (Mirror) -> Void,
        didFailToStart: (Mirror, Error) -> Void,
        didFailToCreate: (Error) -> Void
    ) async {
        do {
            let mirror = try await makeMirror()
            do {
                try await start(mirror)
                didStart(mirror)
            } catch {
                didFailToStart(mirror, error)
            }
        } catch {
            didFailToCreate(error)
        }
    }
}

private extension String {
    var fourCharCode: FourCharCode {
        utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}
