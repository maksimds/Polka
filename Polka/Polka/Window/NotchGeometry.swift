import AppKit

/// Where the notch is on a screen, in global screen coordinates (origin bottom-left).
/// Screens without a notch get a pill-sized area at the top center instead.
struct NotchGeometry {
    let screen: NSScreen
    let notchRect: CGRect
    let hasNotch: Bool

    init(screen: NSScreen) {
        self.screen = screen
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top

        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            notchRect = CGRect(x: frame.minX + left.width,
                               y: frame.maxY - topInset,
                               width: width,
                               height: topInset)
            hasNotch = true
        } else {
            let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)
            let width: CGFloat = 200
            notchRect = CGRect(x: frame.midX - width / 2,
                               y: frame.maxY - menuBarHeight,
                               width: width,
                               height: menuBarHeight)
            hasNotch = false
        }
    }

    /// The built-in notch display if there is one, otherwise the main display.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// The screen the pointer is on, or nil if it's on none of them.
    static func screen(containing point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        return frameIndex(containing: point, in: screens.map(\.frame)).map { screens[$0] }
    }

    /// Which of the frames holds a pointer location. `NSMouseInRect` counts a frame's
    /// top edge as inside and its bottom edge as outside (`CGRect.contains` does the
    /// opposite). That matters with a display placed above the MacBook: the pointer
    /// resting on the notch, at the very top of the built-in screen, must still count
    /// as on the built-in screen, not on the bottom edge of the one above.
    static func frameIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { NSMouseInRect(point, $0, false) }
    }

    /// Area that triggers hover expansion: the notch plus a little slack on each side.
    var hoverRect: CGRect {
        CGRect(x: notchRect.minX - 12,
               y: notchRect.minY - 4,
               width: notchRect.width + 24,
               height: notchRect.height + 8)
    }

    /// Area the expanded panel covers, hanging down from the top of the screen.
    func expandedRect(size: CGSize) -> CGRect {
        CGRect(x: notchRect.midX - size.width / 2,
               y: screen.frame.maxY - size.height,
               width: size.width,
               height: size.height)
    }
}
