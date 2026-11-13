import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import Testing
@testable import popup

struct popupTests {
    @Test func keyboardShortcutDisplayStringUsesStableModifierOrder() {
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyEquivalent: "p"
        )

        #expect(shortcut.displayString == "Control-Option-Shift-Command-P")
    }

    @Test func keyboardShortcutGlyphDisplayStringUsesMacModifierGlyphs() {
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyEquivalent: "p"
        )

        #expect(shortcut.glyphDisplayString == "⌃⌥⇧⌘P")
    }

    @Test func keyboardShortcutMenuModifierMaskMatchesCarbonModifiers() {
        let shortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            keyEquivalent: "p"
        )

        let mask = shortcut.menuModifierMask

        #expect(mask.contains(.control))
        #expect(mask.contains(.option))
        #expect(mask.contains(.shift))
        #expect(mask.contains(.command))
        #expect(!mask.contains(.capsLock))
    }

    @Test func appKitModifierFlagsConvertToCarbonHotKeyModifiers() {
        let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .capsLock]

        #expect(modifiers.carbonHotKeyModifiers == UInt32(cmdKey | shiftKey | optionKey | controlKey))
    }

    @MainActor
    @Test func preferencesClampValuesRoundTripShortcutAndNotifyChanges() async throws {
        let savedPreferences = SavedPreferences()
        defer { savedPreferences.restore() }

        savedPreferences.clear()

        let changeCounter = PreferenceChangeCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: PopupPreferences.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            changeCounter.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(PopupPreferences.selectionShortcut == .defaultSelection)
        #expect(PopupPreferences.panelOpacity == PopupPreferences.defaultPanelOpacity)
        #expect(PopupPreferences.panelDefaultWidth == PopupPreferences.defaultPanelWidth)
        #expect(PopupPreferences.clickThrough == false)
        #expect(PopupPreferences.appearanceTheme == .standard)

        let customShortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey | optionKey),
            keyEquivalent: "b"
        )

        PopupPreferences.selectionShortcut = customShortcut
        PopupPreferences.panelOpacity = 2
        PopupPreferences.panelDefaultWidth = 1_200
        PopupPreferences.clickThrough = true
        PopupPreferences.appearanceTheme = .liquidGlass

        #expect(PopupPreferences.selectionShortcut == customShortcut)
        #expect(PopupPreferences.panelOpacity == PopupPreferences.panelOpacityRange.upperBound)
        #expect(PopupPreferences.panelDefaultWidth == PopupPreferences.panelWidthRange.upperBound)
        #expect(PopupPreferences.clickThrough == true)
        #expect(PopupPreferences.appearanceTheme == .liquidGlass)

        PopupPreferences.panelOpacity = 0.1
        PopupPreferences.panelDefaultWidth = 100

        #expect(PopupPreferences.panelOpacity == PopupPreferences.panelOpacityRange.lowerBound)
        #expect(PopupPreferences.panelDefaultWidth == PopupPreferences.panelWidthRange.lowerBound)
        #expect(changeCounter.count == 6)
    }

    @MainActor
    @Test func resetForTestingClearsEveryPersistedPreference() {
        let savedPreferences = SavedPreferences()
        defer { savedPreferences.restore() }

        PopupPreferences.selectionShortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey | optionKey),
            keyEquivalent: "b"
        )
        PopupPreferences.panelOpacity = 0.3
        PopupPreferences.panelDefaultWidth = 650
        PopupPreferences.clickThrough = true
        PopupPreferences.appearanceTheme = .liquidGlass
        PopupPreferences.hasCompletedOnboarding = true

        PopupPreferences.resetForTesting()

        #expect(PopupPreferences.selectionShortcut == .defaultSelection)
        #expect(PopupPreferences.panelOpacity == PopupPreferences.defaultPanelOpacity)
        #expect(PopupPreferences.panelDefaultWidth == PopupPreferences.defaultPanelWidth)
        #expect(PopupPreferences.clickThrough == false)
        #expect(PopupPreferences.appearanceTheme == .standard)
        #expect(PopupPreferences.hasCompletedOnboarding == false)
    }

    @MainActor
    @Test func selectionOverlayAcceptsFirstMouseAndFirstResponder() {
        let view = SelectionOverlayView()

        #expect(view.acceptsFirstResponder)
        #expect(view.acceptsFirstMouse(for: nil))
    }

    @MainActor
    @Test func closingOnboardingDismissesWithoutCompleting() {
        let controller = OnboardingWindowController()
        var completed = false
        var dismissed = false
        controller.onComplete = { completed = true }
        controller.onDismiss = { dismissed = true }

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: NSWindow()))

        #expect(completed == false)
        #expect(dismissed == true)
    }

    @Test func captureGeometryErrorsHaveUserFacingDescriptions() {
        #expect(CaptureGeometryError.emptySelection.errorDescription == "Select a larger screen region.")
        #expect(CaptureGeometryError.noScreenForSelection.errorDescription == "The selected rectangle is not on an active display.")
        #expect(CaptureGeometryError.noShareableDisplay.errorDescription == "The selected display is not currently available to ScreenCaptureKit.")
    }

    @Test func captureGeometryRejectsSelectionsBelowMinimumDimension() {
        #expect(!CaptureGeometry.isValidSelectionSize(CGRect(x: 0, y: 0, width: 7.9, height: 100)))
        #expect(!CaptureGeometry.isValidSelectionSize(CGRect(x: 0, y: 0, width: 100, height: 7.9)))
        #expect(CaptureGeometry.isValidSelectionSize(CGRect(x: 0, y: 0, width: 8, height: 8)))
    }

    @Test func captureGeometryWindowCandidateRequiresSelectionContainedByWindow() {
        let sourceRect = CGRect(x: 100, y: 100, width: 120, height: 80)
        let mostlyCoveredButOutside = WindowCandidate(
            window: "mostlyCovered",
            frame: CGRect(x: 110, y: 100, width: 300, height: 300),
            isOnScreen: true,
            windowLayer: 0
        )

        let best = CaptureGeometry.bestWindowCandidate(in: [mostlyCoveredButOutside], matching: sourceRect)

        #expect(best == nil)
    }

    @Test func captureGeometryWindowCandidateAllowsTinyFractionalContainmentDrift() {
        let sourceRect = CGRect(x: 100, y: 100, width: 120, height: 80)
        let nearlyExactWindow = WindowCandidate(
            window: "nearlyExact",
            frame: CGRect(x: 100.5, y: 99.5, width: 220, height: 181),
            isOnScreen: true,
            windowLayer: 0
        )

        let best = CaptureGeometry.bestWindowCandidate(in: [nearlyExactWindow], matching: sourceRect)

        #expect(best?.window == "nearlyExact")
    }

    @Test func captureGeometryWindowCandidatePrefersSpecificContainingWindow() {
        let sourceRect = CGRect(x: 100, y: 100, width: 120, height: 80)
        let background = WindowCandidate(
            window: "background",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            isOnScreen: true,
            windowLayer: 0
        )
        let target = WindowCandidate(
            window: "target",
            frame: CGRect(x: 80, y: 80, width: 280, height: 220),
            isOnScreen: true,
            windowLayer: 0
        )

        let best = CaptureGeometry.bestWindowCandidate(in: [background, target], matching: sourceRect)

        #expect(best?.window == "target")
    }

    @Test func captureGeometryWindowCandidatePrefersFrontmostContainingWindow() {
        let sourceRect = CGRect(x: 100, y: 100, width: 120, height: 80)
        let frontmost = WindowCandidate(
            window: "frontmost",
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isOnScreen: true,
            windowLayer: 0,
            windowOrder: 0
        )
        let smallerBehind = WindowCandidate(
            window: "smallerBehind",
            frame: CGRect(x: 80, y: 80, width: 280, height: 220),
            isOnScreen: true,
            windowLayer: 0,
            windowOrder: 8
        )

        let best = CaptureGeometry.bestWindowCandidate(in: [smallerBehind, frontmost], matching: sourceRect)

        #expect(best?.window == "frontmost")
    }

    @Test func captureGeometryWindowCandidateRejectsPartialOrNonNormalWindows() {
        let sourceRect = CGRect(x: 100, y: 100, width: 120, height: 80)
        let partialOverlap = WindowCandidate(
            window: "partial",
            frame: CGRect(x: 180, y: 120, width: 200, height: 200),
            isOnScreen: true,
            windowLayer: 0
        )
        let overlayLayer = WindowCandidate(
            window: "overlay",
            frame: CGRect(x: 90, y: 90, width: 200, height: 160),
            isOnScreen: true,
            windowLayer: 25
        )
        let offscreen = WindowCandidate(
            window: "offscreen",
            frame: CGRect(x: 90, y: 90, width: 200, height: 160),
            isOnScreen: false,
            windowLayer: 0
        )

        let best = CaptureGeometry.bestWindowCandidate(
            in: [partialOverlap, overlayLayer, offscreen],
            matching: sourceRect
        )

        #expect(best == nil)
    }

    @Test func captureGeometryConvertsExternalDisplaySelectionToLocalPointAndPixelRects() {
        let screenFrame = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let selection = CGRect(x: -1_820, y: 200, width: 400, height: 300)

        let sourceRect = CaptureGeometry.displaySourceRect(
            for: selection,
            in: screenFrame,
            backingScaleFactor: 1
        )

        #expect(sourceRect.points == CGRect(x: 100, y: 580, width: 400, height: 300))
        #expect(sourceRect.pixels == CGRect(x: 100, y: 580, width: 400, height: 300))
        #expect(sourceRect.pointPixelScale == 1)
    }

    @Test func captureGeometryUsesPointSourceRectAndPixelOutputForRetinaDisplay() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let selection = CGRect(x: 120, y: 200, width: 320, height: 180)

        let displayRect = CaptureGeometry.displaySourceRect(
            for: selection,
            in: screenFrame,
            backingScaleFactor: 2
        )

        #expect(displayRect.points == CGRect(x: 120, y: 520, width: 320, height: 180))
        #expect(displayRect.pixels == CGRect(x: 240, y: 1_040, width: 640, height: 360))
        #expect(displayRect.points.origin != displayRect.pixels.origin)
        #expect(displayRect.pointPixelScale == 2)
    }

    @Test func captureSessionErrorsHaveUserFacingDescriptions() {
        let permissionError = CaptureSessionError(kind: .screenRecordingPermissionDenied)
        let entitlementError = CaptureSessionError(kind: .missingScreenCaptureEntitlement)

        #expect(permissionError.opensScreenRecordingSettings)
        #expect(permissionError.errorDescription == "Screen Recording access is required before Popup can mirror a selected region. Grant access in Privacy & Security, then quit Popup completely and launch it again.")
        #expect(entitlementError.errorDescription == "Popup is missing the screen capture entitlement required by ScreenCaptureKit. Check the app signing settings and build configuration.")
    }

    @Test func regionCaptureSessionRecognizesUserStoppedError() {
        let userStopped = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.userStopped.rawValue
        )
        let failedToStart = NSError(
            domain: SCStreamError.errorDomain,
            code: SCStreamError.Code.failedToStart.rawValue
        )
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        #expect(RegionCaptureSession.isUserStoppedError(userStopped))
        #expect(!RegionCaptureSession.isUserStoppedError(failedToStart))
        #expect(!RegionCaptureSession.isUserStoppedError(unrelated))
    }

    @Test func mirrorPanelInitialSizePreservesAspectWithinWidthLimits() {
        let smallSource = CGSize(width: 120, height: 60)
        let wideSource = CGSize(width: 1_000, height: 500)

        let smallSize = MirrorPanelLayout.initialSize(for: smallSource, maximumWidth: 420, minimumWidth: 200)
        let wideSize = MirrorPanelLayout.initialSize(for: wideSource, maximumWidth: 420, minimumWidth: 200)

        #expect(smallSize == CGSize(width: 200, height: 100))
        #expect(wideSize == CGSize(width: 420, height: 210))
    }

    @Test func mirrorPanelConstrainedFrameKeepsPanelInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 80, width: 600, height: 400)
        let offscreenFrame = CGRect(x: 640, y: 430, width: 220, height: 180)
        let oversizedFrame = CGRect(x: 40, y: 20, width: 900, height: 600)

        #expect(
            MirrorPanelLayout.constrainedFrame(offscreenFrame, to: visibleFrame)
                == CGRect(x: 480, y: 300, width: 220, height: 180)
        )
        #expect(
            MirrorPanelLayout.constrainedFrame(oversizedFrame, to: visibleFrame)
                == visibleFrame
        )
    }

    @Test func mirrorPanelStackedFramesArrangeEqualSizedPanelsTopDown() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let frames = MirrorPanelLayout.stackedFrames(
            count: 3,
            panelSize: CGSize(width: 300, height: 200),
            in: visibleFrame,
            edgeInset: 24,
            spacing: 12
        )

        #expect(frames == [
            CGRect(x: 676, y: 576, width: 300, height: 200),
            CGRect(x: 676, y: 364, width: 300, height: 200),
            CGRect(x: 676, y: 152, width: 300, height: 200)
        ])
    }

    @Test func mirrorPanelStackedFramesShrinkTogetherWhenStackWouldOverflow() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let frames = MirrorPanelLayout.stackedFrames(
            count: 3,
            panelSize: CGSize(width: 300, height: 200),
            in: visibleFrame,
            edgeInset: 24,
            spacing: 12,
            minimumSize: CGSize(width: 1, height: 1)
        )

        #expect(frames == [
            CGRect(x: 362, y: 334, width: 214, height: 142),
            CGRect(x: 362, y: 180, width: 214, height: 142),
            CGRect(x: 362, y: 26, width: 214, height: 142)
        ])
    }

    @Test func mirrorPanelStackedFramesNeverGoBelowPanelMinimumSize() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 360)
        let frames = MirrorPanelLayout.stackedFrames(
            count: 5,
            panelSize: CGSize(width: 420, height: 240),
            in: visibleFrame,
            edgeInset: 24,
            spacing: 12,
            minimumSize: CGSize(width: 200, height: 90)
        )

        #expect(frames.allSatisfy { $0.width >= 200 && $0.height >= 90 })
        #expect(frames.allSatisfy { visibleFrame.contains($0) })
        #expect(framesDoNotOverlap(frames))
    }

    @Test func mirrorPanelStackedFramesUseColumnsWhenMinimumSizeWouldOverlapSingleStack() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 360)
        let frames = MirrorPanelLayout.stackedFrames(
            count: 5,
            panelSize: CGSize(width: 420, height: 240),
            in: visibleFrame,
            edgeInset: 24,
            spacing: 12,
            minimumSize: CGSize(width: 200, height: 90)
        )

        #expect(frames == [
            CGRect(x: 276, y: 240, width: 200, height: 96),
            CGRect(x: 276, y: 132, width: 200, height: 96),
            CGRect(x: 276, y: 24, width: 200, height: 96),
            CGRect(x: 64, y: 240, width: 200, height: 96),
            CGRect(x: 64, y: 132, width: 200, height: 96)
        ])
    }

    @Test func mirrorPanelCommonPanelSizeUsesLargestPreferredDimensions() {
        let commonSize = MirrorPanelLayout.commonPanelSize(for: [
            CGSize(width: 320, height: 180),
            CGSize(width: 420, height: 160),
            CGSize(width: 280, height: 240)
        ])

        #expect(commonSize == CGSize(width: 420, height: 240))
    }

    @Test func mirrorPanelSnappedOriginUsesNearestEdgesWithinThreshold() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let nearTopRight = CGRect(x: 694, y: 594, width: 300, height: 200)
        let freeFloating = CGRect(x: 500, y: 300, width: 300, height: 200)

        #expect(
            MirrorPanelLayout.snappedOrigin(for: nearTopRight, in: visibleFrame, threshold: 18)
                == CGPoint(x: 700, y: 600)
        )
        #expect(
            MirrorPanelLayout.snappedOrigin(for: freeFloating, in: visibleFrame, threshold: 18)
                == freeFloating.origin
        )
    }

    @Test func mirrorPanelExpandedFramePreservesAspectWithinVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        let frame = MirrorPanelLayout.expandedFrame(
            for: 16.0 / 9.0,
            in: visibleFrame,
            edgeInset: 24
        )

        #expect(frame == CGRect(x: 24, y: 132, width: 952, height: 536))
    }

    @Test func mirrorPanelControlsUseCompactFixedWidth() {
        let narrowControlsWidth = MirrorPanelLayout.controlsWidth(for: 200)
        let wideControlsWidth = MirrorPanelLayout.controlsWidth(for: 600)

        #expect(narrowControlsWidth == MirrorPanelLayout.controlsPreferredWidth)
        #expect(wideControlsWidth == MirrorPanelLayout.controlsPreferredWidth)
    }

    @Test func mirrorPanelVideoFrameCropsWindowStreamToSelectedRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let cropRect = CGRect(x: 100, y: 50, width: 300, height: 200)
        let streamOutputSize = CGSize(width: 900, height: 700)

        let frame = MirrorPanelLayout.videoFrame(
            in: bounds,
            cropRect: cropRect,
            streamOutputSize: streamOutputSize
        )

        #expect(frame == CGRect(x: -100, y: -450, width: 900, height: 700))
    }

    @Test func mirrorPanelVideoFrameUsesBoundsWithoutCrop() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

        let frame = MirrorPanelLayout.videoFrame(
            in: bounds,
            cropRect: nil,
            streamOutputSize: .zero
        )

        #expect(frame == bounds)
    }

    @MainActor
    @Test func floatingMirrorPanelDoesNotMiniaturize() {
        let panel = FloatingMirrorPanel(contentRect: CGRect(x: 0, y: 0, width: 240, height: 160))
        defer { panel.close() }

        panel.miniaturize(nil)

        #expect(panel.isMiniaturized == false)
    }

    @MainActor
    @Test func mirrorStartupRegistersOnlyAfterStartSucceeds() async {
        var events: [String] = []

        await MirrorStartup.start(
            makeMirror: {
                events.append("make")
                return FakeMirror()
            },
            start: { _ in
                events.append("start")
                #expect(!events.contains("didStart"))
            },
            didStart: { _ in
                events.append("didStart")
            },
            didFailToStart: { _, _ in
                events.append("didFailToStart")
            },
            didFailToCreate: { _ in
                events.append("didFailToCreate")
            }
        )

        #expect(events == ["make", "start", "didStart"])
    }

    @MainActor
    @Test func mirrorStartupDoesNotRegisterWhenStartFails() async {
        let startupError = TestError.startFailed
        var didRegister = false
        var handledError: TestError?
        var closedMirror: FakeMirror?

        await MirrorStartup.start(
            makeMirror: { FakeMirror() },
            start: { _ in throw startupError },
            didStart: { _ in didRegister = true },
            didFailToStart: { mirror, error in
                closedMirror = mirror
                handledError = error as? TestError
            },
            didFailToCreate: { _ in }
        )

        #expect(didRegister == false)
        #expect(closedMirror != nil)
        #expect(handledError == startupError)
    }

    // MARK: - CG global coordinate conversion

    @Test func captureGeometryCGGlobalRectFlipsYRelativeToPrimaryHeight() {
        // AppKit: origin at bottom-left, Y up. Selection bottom-left=(100,200), top-right=(500,500).
        // CG global: origin at top-left of primary display, Y down.
        // primaryHeight=900 → CG minY = 900 − appKitMaxY = 900 − 500 = 400
        let result = CaptureGeometry.cgGlobalRect(
            for: CGRect(x: 100, y: 200, width: 400, height: 300),
            primaryDisplayHeight: 900
        )
        #expect(result == CGRect(x: 100, y: 400, width: 400, height: 300))
    }

    @Test func captureGeometryCGGlobalRectPreservesXIncludingNegativeForLeftDisplay() {
        // Secondary display to the left: AppKit x = −1800. X is unchanged by the Y flip.
        // primaryHeight=900 → CG minY = 900 − 400 = 500
        let result = CaptureGeometry.cgGlobalRect(
            for: CGRect(x: -1800, y: 200, width: 300, height: 200),
            primaryDisplayHeight: 900
        )
        #expect(result == CGRect(x: -1800, y: 500, width: 300, height: 200))
    }

    @Test func captureGeometryCGGlobalRectIsIdentityOnBottomEdgeOfPrimaryDisplay() {
        // A selection flush with the bottom of the primary display: AppKit y=0, height=100.
        // CG minY = 900 − 100 = 800. Width/height unchanged.
        let result = CaptureGeometry.cgGlobalRect(
            for: CGRect(x: 0, y: 0, width: 200, height: 100),
            primaryDisplayHeight: 900
        )
        #expect(result == CGRect(x: 0, y: 800, width: 200, height: 100))
    }

    // MARK: - Window matching uses CG global coordinates

    @Test func captureGeometryWindowCandidateNeedsCGGlobalCoordsToMatchOnSecondaryDisplay() {
        // Secondary display: AppKit frame (−1920, 0, 1920, 1080), primaryHeight=900.
        // Window in CG global at (−1900, 460, 800, 500) — its top-left at CG (−1900, 460).
        // AppKit selection (−1800, 200, 300, 200) → CG global (−1800, 500, 300, 200).
        let windowCG = WindowCandidate(
            window: "secondaryWindow",
            frame: CGRect(x: -1900, y: 460, width: 800, height: 500),
            isOnScreen: true,
            windowLayer: 0
        )

        // Display-local coords for the same selection on a 1080-tall secondary display:
        // x = −1800 − (−1920) = 120, y = 1080 − 400 = 680 → (120, 680, 300, 200)
        let displayLocal = CGRect(x: 120, y: 680, width: 300, height: 200)
        // CG global: (−1800, 500, 300, 200)
        let cgGlobal = CGRect(x: -1800, y: 500, width: 300, height: 200)

        let wrongResult = CaptureGeometry.bestWindowCandidate(in: [windowCG], matching: displayLocal)
        let correctResult = CaptureGeometry.bestWindowCandidate(in: [windowCG], matching: cgGlobal)

        #expect(wrongResult == nil, "Display-local coords must not match a CG-global window frame")
        #expect(correctResult?.window == "secondaryWindow", "CG-global coords must match the window")
    }

    @Test func captureGeometryWindowCandidateMatchesMainDisplayWindowWithCGGlobalCoords() {
        // On the main display, CG global y = primaryHeight − appKitMaxY.
        // Window AppKit (100, 300, 800, 500) → CG global (100, 100, 800, 500) with primaryHeight=900.
        // Selection AppKit (200, 350, 300, 200) → CG global (200, 350, 300, 200) — same on main display.
        let windowCG = WindowCandidate(
            window: "mainWindow",
            frame: CGRect(x: 100, y: 100, width: 800, height: 500),
            isOnScreen: true,
            windowLayer: 0
        )
        let cgGlobal = CGRect(x: 200, y: 350, width: 300, height: 200)

        let result = CaptureGeometry.bestWindowCandidate(in: [windowCG], matching: cgGlobal)

        #expect(result?.window == "mainWindow")
    }

    // MARK: - Window crop rect geometry

    @Test func captureGeometryWindowCropRectOffsetFromWindowTopLeftInCGGlobal() {
        // Window CG global top-left at (−1900, 460). Selection CG global top-left at (−1800, 500).
        // Horizontal offset: −1800 − (−1900) = 100 pts × @2x = 200 px.
        // Vertical offset (both Y-down): 500 − 460 = 40 pts × @2x = 80 px.
        let cropRect = CaptureGeometry.windowVideoCropRect(
            cgSelection: CGRect(x: -1800, y: 500, width: 300, height: 200),
            windowFrame: CGRect(x: -1900, y: 460, width: 800, height: 500),
            outputSize: CGSize(width: 600, height: 400),
            pointPixelScale: 2
        )
        #expect(cropRect == CGRect(x: 200, y: 80, width: 600, height: 400))
    }

    @Test func captureGeometryWindowCropRectClampsWhenSelectionExceedsWindowBoundary() {
        // Selection starts left of window (minX −1950 < window minX −1900) → X clamps to 0.
        // Y offset: 500 − 460 = 40 pts × @2x = 80 px (positive, no clamp).
        let cropRect = CaptureGeometry.windowVideoCropRect(
            cgSelection: CGRect(x: -1950, y: 500, width: 300, height: 200),
            windowFrame: CGRect(x: -1900, y: 460, width: 800, height: 500),
            outputSize: CGSize(width: 600, height: 400),
            pointPixelScale: 2
        )
        #expect(cropRect.minX == 0)
        #expect(cropRect.minY == 80)
        #expect(cropRect.size == CGSize(width: 600, height: 400))
    }

    @Test func captureGeometryWindowCropRectOnMainDisplayMatchesExpectedPixelOffset() {
        // Main display (primaryHeight=900). Window AppKit (100, 300, 800, 500):
        // CG global = (100, 100, 800, 500) because 900−800=100 for Y.
        // Selection AppKit (200, 350, 300, 200): CG global = (200, 350, 300, 200).
        // Crop: x=(200−100)×2=200 px, y=(350−100)×2=500 px.
        let cropRect = CaptureGeometry.windowVideoCropRect(
            cgSelection: CGRect(x: 200, y: 350, width: 300, height: 200),
            windowFrame: CGRect(x: 100, y: 100, width: 800, height: 500),
            outputSize: CGSize(width: 600, height: 400),
            pointPixelScale: 2
        )
        #expect(cropRect == CGRect(x: 200, y: 500, width: 600, height: 400))
    }
}

private final class FakeMirror {
}

private enum TestError: Error, Equatable {
    case startFailed
}

private func framesDoNotOverlap(_ frames: [CGRect]) -> Bool {
    for lhsIndex in frames.indices {
        for rhsIndex in frames.indices where rhsIndex > lhsIndex {
            if frames[lhsIndex].intersects(frames[rhsIndex]) {
                return false
            }
        }
    }
    return true
}

private final class PreferenceChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock {
            value += 1
        }
    }
}

private struct SavedPreferences {
    private let values: [String: Any]

    init() {
        values = PopupPreferences.snapshotPersistedValuesForTesting()
    }

    func clear() {
        PopupPreferences.removePersistedValuesForTesting()
    }

    func restore() {
        PopupPreferences.restorePersistedValuesForTesting(values)
    }
}
