import CoreGraphics

enum MirrorPanelLayout {
    static let defaultEdgeInset: CGFloat = 24
    static let defaultSnapThreshold: CGFloat = 18
    static let controlsPreferredWidth: CGFloat = 96
    static let controlsHorizontalInset: CGFloat = 8

    static func initialSize(
        for sourceSize: CGSize,
        maximumWidth: CGFloat = CGFloat(PopupPreferences.panelDefaultWidth),
        minimumWidth: CGFloat = CGFloat(PopupPreferences.panelWidthRange.lowerBound)
    ) -> CGSize {
        let aspect = max(sourceSize.width / max(sourceSize.height, 1), 0.1)
        let width = min(max(sourceSize.width, minimumWidth), maximumWidth)
        return CGSize(width: width, height: width / aspect)
    }

    static func initialOrigin(
        for panelSize: CGSize,
        in visibleFrame: CGRect,
        edgeInset: CGFloat = defaultEdgeInset
    ) -> CGPoint {
        let frame = CGRect(
            x: visibleFrame.maxX - panelSize.width - edgeInset,
            y: visibleFrame.maxY - panelSize.height - edgeInset,
            width: panelSize.width,
            height: panelSize.height
        )
        return constrainedFrame(frame, to: visibleFrame).origin
    }

    static func constrainedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let origin = CGPoint(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    static func stackedFrames(
        count: Int,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        edgeInset: CGFloat = defaultEdgeInset,
        spacing: CGFloat = 12,
        minimumSize: CGSize = CGSize(
            width: CGFloat(PopupPreferences.panelWidthRange.lowerBound),
            height: 90
        )
    ) -> [CGRect] {
        guard count > 0, panelSize.width > 0, panelSize.height > 0 else { return [] }

        let constrainedMinimumSize = constrained(
            minimumSize: minimumSize,
            to: visibleFrame.size
        )

        if let singleColumnLayout = stackLayout(
            count: count,
            rows: count,
            columns: 1,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            edgeInset: edgeInset,
            spacing: spacing,
            minimumSize: constrainedMinimumSize
        ) {
            return frames(
                for: singleColumnLayout,
                count: count,
                in: visibleFrame,
                edgeInset: edgeInset,
                spacing: spacing
            )
        }

        let bestLayout = (1...count).compactMap { rows in
            let columns = Int(ceil(Double(count) / Double(rows)))
            return stackLayout(
                count: count,
                rows: rows,
                columns: columns,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                edgeInset: edgeInset,
                spacing: spacing,
                minimumSize: constrainedMinimumSize
            )
        }
        .max { lhs, rhs in
            let lhsArea = lhs.size.width * lhs.size.height
            let rhsArea = rhs.size.width * rhs.size.height
            guard lhsArea != rhsArea else {
                return lhs.columns > rhs.columns
            }
            return lhsArea < rhsArea
        }

        guard let bestLayout else {
            let fallback = StackLayout(rows: count, columns: 1, size: constrainedMinimumSize)
            return frames(
                for: fallback,
                count: count,
                in: visibleFrame,
                edgeInset: edgeInset,
                spacing: spacing
            ).map { constrainedFrame($0, to: visibleFrame) }
        }

        return frames(
            for: bestLayout,
            count: count,
            in: visibleFrame,
            edgeInset: edgeInset,
            spacing: spacing
        )
    }

    private struct StackLayout {
        let rows: Int
        let columns: Int
        let size: CGSize
    }

    private static func stackLayout(
        count: Int,
        rows: Int,
        columns: Int,
        panelSize: CGSize,
        visibleFrame: CGRect,
        edgeInset: CGFloat,
        spacing: CGFloat,
        minimumSize: CGSize
    ) -> StackLayout? {
        guard rows > 0, columns > 0, rows * columns >= count else { return nil }

        let availableWidth = visibleFrame.width - edgeInset * 2 - spacing * CGFloat(max(0, columns - 1))
        let availableHeight = visibleFrame.height - edgeInset * 2 - spacing * CGFloat(max(0, rows - 1))
        guard availableWidth > 0, availableHeight > 0 else { return nil }

        let scale = min(
            1,
            availableWidth / (panelSize.width * CGFloat(columns)),
            availableHeight / (panelSize.height * CGFloat(rows))
        )
        let arrangedSize = CGSize(
            width: floor(panelSize.width * scale),
            height: floor(panelSize.height * scale)
        )
        let size = CGSize(
            width: max(arrangedSize.width, minimumSize.width),
            height: max(arrangedSize.height, minimumSize.height)
        )

        let occupiedWidth = size.width * CGFloat(columns) + spacing * CGFloat(max(0, columns - 1))
        let occupiedHeight = size.height * CGFloat(rows) + spacing * CGFloat(max(0, rows - 1))
        guard occupiedWidth <= visibleFrame.width - edgeInset * 2,
              occupiedHeight <= visibleFrame.height - edgeInset * 2 else {
            return nil
        }

        return StackLayout(rows: rows, columns: columns, size: size)
    }

    private static func constrained(minimumSize: CGSize, to visibleSize: CGSize) -> CGSize {
        CGSize(
            width: min(max(1, minimumSize.width), visibleSize.width),
            height: min(max(1, minimumSize.height), visibleSize.height)
        )
    }

    private static func frames(
        for layout: StackLayout,
        count: Int,
        in visibleFrame: CGRect,
        edgeInset: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        return (0..<count).map { index in
            let column = index / layout.rows
            let row = index % layout.rows
            let originX = visibleFrame.maxX
                - edgeInset
                - layout.size.width
                - CGFloat(column) * (layout.size.width + spacing)
            let originY = visibleFrame.maxY
                - edgeInset
                - layout.size.height
                - CGFloat(row) * (layout.size.height + spacing)

            return CGRect(origin: CGPoint(x: originX, y: originY), size: layout.size)
        }
    }

    static func commonPanelSize(for sizes: [CGSize]) -> CGSize {
        sizes.reduce(.zero) { commonSize, size in
            CGSize(
                width: max(commonSize.width, size.width),
                height: max(commonSize.height, size.height)
            )
        }
    }

    static func snappedOrigin(
        for frame: CGRect,
        in visibleFrame: CGRect,
        threshold: CGFloat = defaultSnapThreshold
    ) -> CGPoint {
        let left = abs(frame.minX - visibleFrame.minX)
        let right = abs(visibleFrame.maxX - frame.maxX)
        let bottom = abs(frame.minY - visibleFrame.minY)
        let top = abs(visibleFrame.maxY - frame.maxY)
        var origin = frame.origin

        if min(left, right) <= threshold {
            origin.x = left <= right ? visibleFrame.minX : visibleFrame.maxX - frame.width
        }
        if min(bottom, top) <= threshold {
            origin.y = bottom <= top ? visibleFrame.minY : visibleFrame.maxY - frame.height
        }

        return origin
    }

    static func expandedFrame(
        for aspectRatio: CGFloat,
        in visibleFrame: CGRect,
        edgeInset: CGFloat = defaultEdgeInset
    ) -> CGRect {
        let availableFrame = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        guard availableFrame.width > 0, availableFrame.height > 0 else {
            return constrainedFrame(visibleFrame, to: visibleFrame)
        }

        let aspectRatio = max(aspectRatio, 0.1)
        let availableAspectRatio = availableFrame.width / max(availableFrame.height, 1)
        let size: CGSize
        if availableAspectRatio > aspectRatio {
            size = CGSize(width: floor(availableFrame.height * aspectRatio), height: floor(availableFrame.height))
        } else {
            size = CGSize(width: floor(availableFrame.width), height: floor(availableFrame.width / aspectRatio))
        }

        let frame = CGRect(
            x: availableFrame.midX - size.width / 2,
            y: availableFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return constrainedFrame(frame.integral, to: visibleFrame)
    }

    static func controlsWidth(
        for contentWidth: CGFloat,
        horizontalInset: CGFloat = controlsHorizontalInset,
        preferredWidth: CGFloat = controlsPreferredWidth
    ) -> CGFloat {
        min(preferredWidth, max(0, contentWidth - horizontalInset * 2))
    }

    static func videoFrame(
        in bounds: CGRect,
        cropRect: CGRect?,
        streamOutputSize: CGSize
    ) -> CGRect {
        guard let cropRect,
              streamOutputSize.width > 0,
              streamOutputSize.height > 0,
              cropRect.width > 0,
              cropRect.height > 0 else {
            return bounds
        }

        let scale = max(bounds.width / cropRect.width, bounds.height / cropRect.height)
        return CGRect(
            x: -cropRect.minX * scale,
            y: -(streamOutputSize.height - cropRect.maxY) * scale,
            width: streamOutputSize.width * scale,
            height: streamOutputSize.height * scale
        )
    }
}
