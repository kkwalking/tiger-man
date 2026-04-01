import AppKit
import CoreGraphics

struct MenuBarCapture {
    let image: CGImage
    let menuBarFrame: CGRect
    let scale: CGFloat
}

@MainActor
final class ScreenCaptureService {
    func captureMenuBar(for screen: NSScreen) -> MenuBarCapture? {
        let menuBarFrame = LayoutCoordinator.menuBarFrame(for: screen)
        guard let displayID = displayID(for: screen) else {
            Logger.error("Unable to resolve display ID for screen")
            return nil
        }

        let captureRect = displayCaptureRect(for: menuBarFrame, on: screen)
        guard let image = CGDisplayCreateImage(displayID, rect: captureRect) else {
            Logger.error("Unable to capture menu bar image")
            return nil
        }

        let scale = menuBarFrame.width == 0 ? 1 : CGFloat(image.width) / menuBarFrame.width
        return MenuBarCapture(image: image, menuBarFrame: menuBarFrame, scale: scale)
    }

    func cropSnapshot(from capture: MenuBarCapture, screenRect: CGRect, source: StatusItemSource) -> NSImage? {
        let imageRect = imageRect(for: screenRect, inside: capture)
        let paddedRect = paddedImageRect(
            for: imageRect,
            imageWidth: capture.image.width,
            imageHeight: capture.image.height,
            padding: 2
        )
        guard let cropped = capture.image.cropping(to: paddedRect.integral) else {
            return nil
        }

        let thresholdBias = source == .accessibility ? -4 : 0
        let keyedImage = keyedIconImage(from: cropped, thresholdBias: thresholdBias) ?? cropped
        let trimMinAlpha = source == .accessibility ? 20 : 28
        let trimmedImage = trimTransparentBounds(in: keyedImage, minimumAlpha: trimMinAlpha, padding: 1) ?? keyedImage

        let logicalScale = capture.scale > 0 ? capture.scale : 1
        let logicalSize = NSSize(
            width: CGFloat(trimmedImage.width) / logicalScale,
            height: CGFloat(trimmedImage.height) / logicalScale
        )
        return NSImage(cgImage: trimmedImage, size: logicalSize)
    }

    private func imageRect(for screenRect: CGRect, inside capture: MenuBarCapture) -> CGRect {
        let localX = (screenRect.minX - capture.menuBarFrame.minX) * capture.scale
        let localY = (capture.menuBarFrame.maxY - screenRect.maxY) * capture.scale
        let width = screenRect.width * capture.scale
        let height = screenRect.height * capture.scale

        return CGRect(
            x: max(0, localX),
            y: max(0, localY),
            width: min(CGFloat(capture.image.width) - localX, width),
            height: min(CGFloat(capture.image.height) - localY, height)
        )
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func displayCaptureRect(for menuBarFrame: CGRect, on screen: NSScreen) -> CGRect {
        let localRectInPoints = CGRect(
            x: menuBarFrame.minX - screen.frame.minX,
            y: screen.frame.maxY - menuBarFrame.maxY,
            width: menuBarFrame.width,
            height: menuBarFrame.height
        )

        let scale = screen.backingScaleFactor
        return CGRect(
            x: localRectInPoints.minX * scale,
            y: localRectInPoints.minY * scale,
            width: localRectInPoints.width * scale,
            height: localRectInPoints.height * scale
        )
    }

    private func paddedImageRect(
        for rect: CGRect,
        imageWidth: Int,
        imageHeight: Int,
        padding: CGFloat
    ) -> CGRect {
        let maxWidth = CGFloat(imageWidth)
        let maxHeight = CGFloat(imageHeight)
        let minX = max(0, rect.minX - padding)
        let minY = max(0, rect.minY - padding)
        let maxX = min(maxWidth, rect.maxX + padding)
        let maxY = min(maxHeight, rect.maxY + padding)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private func keyedIconImage(from image: CGImage, thresholdBias: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        else {
            return nil
        }

        let drawRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: drawRect)

        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        let stripWidth = max(1, min(4, width / 5))
        let stripHeight = max(1, min(4, height / 4))
        let leftColor = averageColor(
            xRange: 0..<stripWidth,
            yRange: 0..<height,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            data: data
        )
        let rightColor = averageColor(
            xRange: (width - stripWidth)..<width,
            yRange: 0..<height,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            data: data
        )
        let topColor = averageColor(
            xRange: 0..<width,
            yRange: 0..<stripHeight,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            data: data
        )
        let bottomColor = averageColor(
            xRange: 0..<width,
            yRange: (height - stripHeight)..<height,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            data: data
        )

        let transparentThreshold = max(18, 24 + thresholdBias)
        let softThreshold = max(42, 66 + thresholdBias)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let red = Int(data[offset])
                let green = Int(data[offset + 1])
                let blue = Int(data[offset + 2])
                let originalAlpha = Int(data[offset + 3])

                let t = width <= 1 ? 0 : CGFloat(x) / CGFloat(width - 1)
                let rowT = height <= 1 ? 0 : CGFloat(y) / CGFloat(height - 1)
                let horizontalRed = interpolate(from: leftColor.red, to: rightColor.red, t: t)
                let horizontalGreen = interpolate(from: leftColor.green, to: rightColor.green, t: t)
                let horizontalBlue = interpolate(from: leftColor.blue, to: rightColor.blue, t: t)
                let verticalRed = interpolate(from: topColor.red, to: bottomColor.red, t: rowT)
                let verticalGreen = interpolate(from: topColor.green, to: bottomColor.green, t: rowT)
                let verticalBlue = interpolate(from: topColor.blue, to: bottomColor.blue, t: rowT)
                let backgroundRed = blended(horizontalRed, verticalRed, horizontalWeight: 0.75)
                let backgroundGreen = blended(horizontalGreen, verticalGreen, horizontalWeight: 0.75)
                let backgroundBlue = blended(horizontalBlue, verticalBlue, horizontalWeight: 0.75)

                let distance = abs(red - backgroundRed) + abs(green - backgroundGreen) + abs(blue - backgroundBlue)
                let keyedAlpha: Int
                if distance <= transparentThreshold {
                    keyedAlpha = 0
                } else if distance <= softThreshold {
                    keyedAlpha = min(255, (distance - transparentThreshold) * 6)
                } else {
                    keyedAlpha = 255
                }

                let finalAlpha = min(originalAlpha, keyedAlpha)
                data[offset + 3] = UInt8(max(0, min(255, finalAlpha)))
                if finalAlpha == 0 {
                    data[offset] = 0
                    data[offset + 1] = 0
                    data[offset + 2] = 0
                }
            }
        }

        // Aggressive border cleanup: remove likely menu bar gradient spill at tile edges.
        let borderTrim = min(2, max(1, min(width, height) / 8))
        if borderTrim > 0 {
            for y in 0..<height {
                for x in 0..<width {
                    if x < borderTrim || x >= (width - borderTrim) || y < borderTrim || y >= (height - borderTrim) {
                        let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                        data[offset + 3] = 0
                        data[offset] = 0
                        data[offset + 1] = 0
                        data[offset + 2] = 0
                    }
                }
            }
        }

        if width > 2, height > 2 {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                    let alpha = Int(data[offset + 3])
                    if alpha == 0 || alpha >= 96 {
                        continue
                    }

                    var strongNeighbors = 0
                    for ny in (y - 1)...(y + 1) {
                        for nx in (x - 1)...(x + 1) where !(nx == x && ny == y) {
                            let neighborOffset = (ny * bytesPerRow) + (nx * bytesPerPixel)
                            if Int(data[neighborOffset + 3]) >= 110 {
                                strongNeighbors += 1
                            }
                        }
                    }

                    if strongNeighbors <= 1 {
                        data[offset + 3] = 0
                        data[offset] = 0
                        data[offset + 1] = 0
                        data[offset + 2] = 0
                    }
                }
            }
        }

        isolateDominantConnectedRegion(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            activeAlpha: 104,
            data: data
        )

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let alpha = Int(data[offset + 3])
                if alpha < 96 {
                    data[offset + 3] = 0
                    data[offset] = 0
                    data[offset + 1] = 0
                    data[offset + 2] = 0
                } else {
                    data[offset + 3] = 255
                }
            }
        }

        return context.makeImage()
    }

    private func isolateDominantConnectedRegion(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        activeAlpha: Int,
        data: UnsafeMutablePointer<UInt8>
    ) {
        guard width > 0, height > 0 else {
            return
        }

        let pixelCount = width * height
        var visited = Array(repeating: false, count: pixelCount)
        var components: [AlphaComponent] = []

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                if visited[index] {
                    continue
                }
                visited[index] = true

                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                if Int(data[offset + 3]) < activeAlpha {
                    continue
                }

                var queue = [index]
                var head = 0
                var pixels: [Int] = []
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var sumX = 0
                var sumY = 0

                while head < queue.count {
                    let current = queue[head]
                    head += 1
                    pixels.append(current)

                    let cx = current % width
                    let cy = current / width
                    minX = min(minX, cx)
                    maxX = max(maxX, cx)
                    minY = min(minY, cy)
                    maxY = max(maxY, cy)
                    sumX += cx
                    sumY += cy

                    let neighbors = [
                        (cx - 1, cy),
                        (cx + 1, cy),
                        (cx, cy - 1),
                        (cx, cy + 1),
                    ]
                    for (nx, ny) in neighbors where nx >= 0 && nx < width && ny >= 0 && ny < height {
                        let neighborIndex = (ny * width) + nx
                        if visited[neighborIndex] {
                            continue
                        }
                        visited[neighborIndex] = true

                        let neighborOffset = (ny * bytesPerRow) + (nx * bytesPerPixel)
                        if Int(data[neighborOffset + 3]) >= activeAlpha {
                            queue.append(neighborIndex)
                        }
                    }
                }

                components.append(
                    AlphaComponent(
                        pixels: pixels,
                        minX: minX,
                        maxX: maxX,
                        minY: minY,
                        maxY: maxY,
                        sumX: sumX,
                        sumY: sumY
                    )
                )
            }
        }

        guard !components.isEmpty else {
            return
        }

        let centerX = Double(width - 1) / 2.0
        let centerY = Double(height - 1) / 2.0
        let best = components.max { lhs, rhs in
            componentScore(lhs, centerX: centerX, centerY: centerY, width: width, height: height)
                < componentScore(rhs, centerX: centerX, centerY: centerY, width: width, height: height)
        }
        guard let best else {
            return
        }

        var keep = Array(repeating: false, count: pixelCount)
        let expandedBest = best.expanded(padding: 3, width: width, height: height)
        for component in components {
            let shouldKeep: Bool
            if component === best {
                shouldKeep = true
            } else {
                let areaThreshold = max(10, best.area / 5)
                shouldKeep = component.area >= areaThreshold && component.intersects(expandedBest)
            }

            guard shouldKeep else {
                continue
            }
            for pixel in component.pixels {
                keep[pixel] = true
            }
        }

        for index in 0..<pixelCount where !keep[index] {
            let x = index % width
            let y = index / width
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            data[offset + 3] = 0
            data[offset] = 0
            data[offset + 1] = 0
            data[offset + 2] = 0
        }
    }

    private func componentScore(
        _ component: AlphaComponent,
        centerX: Double,
        centerY: Double,
        width: Int,
        height: Int
    ) -> Double {
        let cx = Double(component.sumX) / Double(component.area)
        let cy = Double(component.sumY) / Double(component.area)
        let dx = cx - centerX
        let dy = cy - centerY
        let distancePenalty = (dx * dx) + (dy * dy)
        let edgePenalty = (component.minX <= 1 || component.minY <= 1 || component.maxX >= width - 2 || component.maxY >= height - 2) ? 120.0 : 0.0
        return Double(component.area * 100) - (distancePenalty * 6.0) - edgePenalty
    }

    private func trimTransparentBounds(
        in image: CGImage,
        minimumAlpha: Int,
        padding: Int
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let alpha = Int(data[offset + 3])
                if alpha < minimumAlpha {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let startX = max(0, minX - padding)
        let startY = max(0, minY - padding)
        let endX = min(width - 1, maxX + padding)
        let endY = min(height - 1, maxY + padding)
        let rect = CGRect(
            x: startX,
            y: startY,
            width: max(1, endX - startX + 1),
            height: max(1, endY - startY + 1)
        )
        return image.cropping(to: rect)
    }

    private func averageColor(
        xRange: Range<Int>,
        yRange: Range<Int>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        data: UnsafePointer<UInt8>
    ) -> RGBColor {
        guard !xRange.isEmpty else {
            return RGBColor(red: 0, green: 0, blue: 0)
        }

        var redSum = 0
        var greenSum = 0
        var blueSum = 0
        var count = 0

        for y in yRange where y >= 0 && y < height {
            for x in xRange where x >= 0 && x < width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                redSum += Int(data[offset])
                greenSum += Int(data[offset + 1])
                blueSum += Int(data[offset + 2])
                count += 1
            }
        }

        guard count > 0 else {
            return RGBColor(red: 0, green: 0, blue: 0)
        }

        return RGBColor(
            red: redSum / count,
            green: greenSum / count,
            blue: blueSum / count
        )
    }

    private func interpolate(from start: Int, to end: Int, t: CGFloat) -> Int {
        Int((CGFloat(start) + (CGFloat(end - start) * t)).rounded())
    }

    private func blended(_ a: Int, _ b: Int, horizontalWeight: CGFloat) -> Int {
        let clamped = max(0, min(1, horizontalWeight))
        return Int((CGFloat(a) * clamped + CGFloat(b) * (1 - clamped)).rounded())
    }
}

private struct RGBColor {
    let red: Int
    let green: Int
    let blue: Int
}

private final class AlphaComponent {
    let pixels: [Int]
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
    let sumX: Int
    let sumY: Int

    init(pixels: [Int], minX: Int, maxX: Int, minY: Int, maxY: Int, sumX: Int, sumY: Int) {
        self.pixels = pixels
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.sumX = sumX
        self.sumY = sumY
    }

    var area: Int {
        pixels.count
    }

    func expanded(padding: Int, width: Int, height: Int) -> AlphaComponentBounds {
        AlphaComponentBounds(
            minX: max(0, minX - padding),
            maxX: min(width - 1, maxX + padding),
            minY: max(0, minY - padding),
            maxY: min(height - 1, maxY + padding)
        )
    }

    func intersects(_ bounds: AlphaComponentBounds) -> Bool {
        !(maxX < bounds.minX || minX > bounds.maxX || maxY < bounds.minY || minY > bounds.maxY)
    }
}

private struct AlphaComponentBounds {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
}
