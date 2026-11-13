import AppKit
import CoreGraphics
import ScreenCaptureKit

struct DisplayRegion {
    let display: SCDisplay
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let screenRect: CGRect
    let streamSourceRect: CGRect
    let streamOutputSize: CGSize
    let videoCropRect: CGRect?
    let window: SCWindow?
}

enum CaptureGeometryError: LocalizedError {
    case noScreenForSelection
    case noShareableDisplay
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .noScreenForSelection:
            "The selected rectangle is not on an active display."
        case .noShareableDisplay:
            "The selected display is not currently available to ScreenCaptureKit."
        case .emptySelection:
            "Select a larger screen region."
        }
    }
}

enum CaptureGeometry {
    private static let minimumSelectionDimension: CGFloat = 8
    private static let windowSelectionContainmentTolerance: CGFloat = 1

    static func displayRegion(containing selection: CGRect) async throws -> DisplayRegion {
        guard isValidSelectionSize(selection) else {
            throw CaptureGeometryError.emptySelection
        }

        guard let screen = NSScreen.bestScreen(containing: selection) else {
            throw CaptureGeometryError.noScreenForSelection
        }

        let displayID = try screen.displayID()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureGeometryError.noShareableDisplay
        }

        let clippedSelection = selection.intersection(screen.frame).standardized
        guard isValidSelectionSize(clippedSelection) else {
            throw CaptureGeometryError.emptySelection
        }

        let displayRect = displaySourceRect(
            for: clippedSelection,
            in: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
        let pointPixelScale = displayRect.pointPixelScale
        let outputSize = CGSize(
            width: max(1, displayRect.pixels.width),
            height: max(1, displayRect.pixels.height)
        )

        // SCWindow.frame uses CG global coordinates (Y-down, origin at top-left of primary
        // display). Convert the AppKit selection to the same space so window matching and
        // crop-rect calculations are correct on secondary/external displays.
        let cgSelection = cgGlobalRect(
            for: clippedSelection,
            primaryDisplayHeight: primaryDisplayHeight()
        )

        let window = bestWindow(in: content.windows, matching: cgSelection)
        let streamSourceRect: CGRect
        let streamOutputSize: CGSize
        let videoCropRect: CGRect?
        if let window {
            let windowFrame = window.frame.integral
            streamSourceRect = .zero
            streamOutputSize = CGSize(
                width: max(1, windowFrame.width * pointPixelScale),
                height: max(1, windowFrame.height * pointPixelScale)
            )
            videoCropRect = windowVideoCropRect(
                cgSelection: cgSelection,
                windowFrame: windowFrame,
                outputSize: outputSize,
                pointPixelScale: pointPixelScale
            )
        } else {
            // ScreenCaptureKit sourceRect is display-local logical coordinates;
            // output width/height below remain pixel-sized for Retina fidelity.
            streamSourceRect = displayRect.points
            streamOutputSize = outputSize
            videoCropRect = nil
        }

        return DisplayRegion(
            display: display,
            displayID: displayID,
            screen: screen,
            screenRect: clippedSelection,
            streamSourceRect: streamSourceRect,
            streamOutputSize: streamOutputSize,
            videoCropRect: videoCropRect,
            window: window
        )
    }

    static func isValidSelectionSize(_ rect: CGRect) -> Bool {
        !rect.isNull
            && !rect.isEmpty
            && rect.width >= minimumSelectionDimension
            && rect.height >= minimumSelectionDimension
    }

    static func bestWindow(
        in windows: [SCWindow],
        matching sourceRect: CGRect
    ) -> SCWindow? {
        let minimumSelectionCoverage: CGFloat = 0.85
        let sourceArea = sourceRect.area
        guard sourceArea > 0 else { return nil }

        var eligibleWindows: [SCWindow] = []
        for window in windows {
            let candidate = WindowCandidate(window: window)
            guard candidate.isEligibleMatch(
                for: sourceRect,
                sourceArea: sourceArea,
                minimumSelectionCoverage: minimumSelectionCoverage,
                containmentTolerance: windowSelectionContainmentTolerance
            ) else {
                continue
            }
            eligibleWindows.append(window)
        }

        guard eligibleWindows.count > 1 else {
            return eligibleWindows.first
        }

        let windowOrder = CGWindowOrder.frontToBack
        var bestCandidate: WindowCandidate<SCWindow>?
        for window in eligibleWindows {
            bestCandidate = preferredCandidate(
                between: bestCandidate,
                and: WindowCandidate(window: window, windowOrder: windowOrder[window.windowID]),
                matching: sourceRect,
                sourceArea: sourceArea,
                minimumSelectionCoverage: minimumSelectionCoverage
            )
        }
        return bestCandidate?.window
    }

    static func bestWindowCandidate<T>(
        in candidates: [WindowCandidate<T>],
        matching sourceRect: CGRect
    ) -> WindowCandidate<T>? {
        let minimumSelectionCoverage: CGFloat = 0.85
        let sourceArea = sourceRect.area
        guard sourceArea > 0 else { return nil }

        var bestCandidate: WindowCandidate<T>?
        for candidate in candidates {
            bestCandidate = preferredCandidate(
                between: bestCandidate,
                and: candidate,
                matching: sourceRect,
                sourceArea: sourceArea,
                minimumSelectionCoverage: minimumSelectionCoverage
            )
        }
        return bestCandidate
    }

    private static func preferredCandidate<T>(
        between currentBest: WindowCandidate<T>?,
        and candidate: WindowCandidate<T>,
        matching sourceRect: CGRect,
        sourceArea: CGFloat,
        minimumSelectionCoverage: CGFloat
    ) -> WindowCandidate<T>? {
        guard candidate.isEligibleMatch(
            for: sourceRect,
            sourceArea: sourceArea,
            minimumSelectionCoverage: minimumSelectionCoverage,
            containmentTolerance: windowSelectionContainmentTolerance
        ) else {
            return currentBest
        }

        guard let currentBest else { return candidate }
        return candidate.isPreferred(over: currentBest, for: sourceRect) ? candidate : currentBest
    }

    // Converts an AppKit rect (Y-up, origin at bottom-left of primary display) to the CG
    // global rect (Y-down, origin at top-left of primary display) used by SCWindow.frame.
    static func cgGlobalRect(for appKitRect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: appKitRect.minX,
            y: primaryDisplayHeight - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    static func primaryDisplayHeight() -> CGFloat {
        NSScreen.screens.first { screen in
            (try? screen.displayID()) == CGMainDisplayID()
        }?.frame.height
            ?? NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
    }

    // Returns the pixel crop rect that positions `cgSelection` within the window-stream output.
    // Both `cgSelection` and `windowFrame` must be in CG global coordinates (Y-down).
    // The resulting rect's origin is in Y-down pixel space from the top-left of the window output.
    static func windowVideoCropRect(
        cgSelection: CGRect,
        windowFrame: CGRect,
        outputSize: CGSize,
        pointPixelScale: CGFloat
    ) -> CGRect {
        CGRect(
            x: max(0, (cgSelection.minX - windowFrame.minX) * pointPixelScale),
            y: max(0, (cgSelection.minY - windowFrame.minY) * pointPixelScale),
            width: outputSize.width,
            height: outputSize.height
        )
    }

    static func displaySourceRect(
        for selection: CGRect,
        in screenFrame: CGRect,
        backingScaleFactor: CGFloat
    ) -> (points: CGRect, pixels: CGRect, pointPixelScale: CGFloat) {
        let pointPixelScale = backingScaleFactor
        let points = CGRect(
            x: selection.minX - screenFrame.minX,
            y: screenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        ).integral

        return (
            points: points,
            pixels: points.scaled(by: pointPixelScale).integral,
            pointPixelScale: pointPixelScale
        )
    }
}

struct WindowCandidate<Window> {
    let window: Window
    let frame: CGRect
    let isOnScreen: Bool
    let windowLayer: Int
    let windowOrder: Int?

    init(window: Window, frame: CGRect, isOnScreen: Bool, windowLayer: Int, windowOrder: Int? = nil) {
        self.window = window
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.windowLayer = windowLayer
        self.windowOrder = windowOrder
    }

    init(window: SCWindow, windowOrder: Int? = nil) where Window == SCWindow {
        self.init(
            window: window,
            frame: window.frame,
            isOnScreen: window.isOnScreen,
            windowLayer: window.windowLayer,
            windowOrder: windowOrder
        )
    }

    func isEligibleMatch(
        for sourceRect: CGRect,
        sourceArea: CGFloat,
        minimumSelectionCoverage: CGFloat,
        containmentTolerance: CGFloat
    ) -> Bool {
        isOnScreen
            && windowLayer == 0
            && frame.contains(sourceRect.center)
            && frame.contains(sourceRect, tolerance: containmentTolerance)
            && frame.intersectionArea(with: sourceRect) / sourceArea >= minimumSelectionCoverage
    }

    func isPreferred(over candidate: WindowCandidate<Window>, for sourceRect: CGRect) -> Bool {
        if let lhsOrder = windowOrder, let rhsOrder = candidate.windowOrder, lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        if windowOrder != nil, candidate.windowOrder == nil {
            return true
        }
        if windowOrder == nil, candidate.windowOrder != nil {
            return false
        }

        let lhsArea = frame.area
        let rhsArea = candidate.frame.area
        guard lhsArea != rhsArea else {
            return frame.intersectionArea(with: sourceRect) > candidate.frame.intersectionArea(with: sourceRect)
        }
        return lhsArea < rhsArea
    }
}

private enum CGWindowOrder {
    static var frontToBack: [CGWindowID: Int] {
        guard let windowInfos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var orderByID: [CGWindowID: Int] = [:]
        for (index, info) in windowInfos.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            orderByID[CGWindowID(number.uint32Value)] = index
        }
        return orderByID
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func intersectionArea(with rect: CGRect) -> CGFloat {
        let intersection = intersection(rect)
        return intersection.area
    }

    func contains(_ rect: CGRect, tolerance: CGFloat) -> Bool {
        insetBy(dx: -tolerance, dy: -tolerance).contains(rect)
    }

    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(
            x: minX * scale,
            y: minY * scale,
            width: width * scale,
            height: height * scale
        )
    }
}

private extension NSScreen {
    static func bestScreen(containing rect: CGRect) -> NSScreen? {
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

    func displayID() throws -> CGDirectDisplayID {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureGeometryError.noScreenForSelection
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
