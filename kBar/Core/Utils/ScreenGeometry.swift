import CoreGraphics

enum ScreenGeometry {
    static func mergeColumnActivity(
        _ activity: [Bool],
        gapTolerance: Int,
        minimumWidth: Int
    ) -> [ClosedRange<Int>] {
        guard !activity.isEmpty else {
            return []
        }

        var ranges: [ClosedRange<Int>] = []
        var start: Int?
        var lastActive: Int?

        for index in activity.indices {
            if activity[index] {
                if start == nil {
                    start = index
                }
                lastActive = index
                continue
            }

            guard let currentStart = start, let currentLastActive = lastActive else {
                continue
            }

            if index - currentLastActive <= gapTolerance {
                continue
            }

            if currentLastActive - currentStart + 1 >= minimumWidth {
                ranges.append(currentStart...currentLastActive)
            }

            start = nil
            lastActive = nil
        }

        if let currentStart = start, let currentLastActive = lastActive, currentLastActive - currentStart + 1 >= minimumWidth {
            ranges.append(currentStart...currentLastActive)
        }

        return ranges
    }

    static func union(_ frames: [CGRect], horizontalPadding: CGFloat = 0, verticalPadding: CGFloat = 0) -> CGRect? {
        guard let first = frames.first else {
            return nil
        }

        let unionRect = frames.dropFirst().reduce(first) { partialResult, frame in
            partialResult.union(frame)
        }

        return unionRect.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
    }
}
