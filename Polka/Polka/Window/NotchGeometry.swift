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
