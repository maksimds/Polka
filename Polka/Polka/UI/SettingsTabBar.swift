import SwiftUI

/// The Settings window's tabs.
enum SettingsTab: Int, CaseIterable {
    case general
    case nearby

    var title: String {
        switch self {
        case .general: return "General"
        case .nearby: return "Nearby Sharing"
        }
    }

    /// Shown left of the tab's name.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .nearby: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Which tab Settings shows. The window controller follows it to size the window.
@MainActor
final class SettingsTabModel: ObservableObject {
    @Published var tab: SettingsTab {
        didSet {
            if tab != oldValue { onChange?(tab) }
        }
    }

    var onChange: ((SettingsTab) -> Void)?

    init(_ tab: SettingsTab = .general) {
        self.tab = tab
    }
}

/// The whole Settings window: the tab bar on top, the tab's form under it.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsTabModel
    let loginItem: LoginItem
    let screenshots: ScreenshotCatcher?
    let nearby: NearbyService

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $model.tab)
                .padding(.top, 4)
            switch model.tab {
            case .general: SettingsView(loginItem: loginItem, screenshots: screenshots)
            case .nearby: NearbySettingsView(nearby: nearby)
            }
        }
        .frame(width: SettingsView.width)
    }
}

/// A segmented control after the one System Settings shows over Trackpad's tabs
/// ("Point & Click", "Scroll & Zoom"): a flat rounded track as wide as the form's
/// sections, split into equal tabs, each its symbol left of its name, and the chosen
/// one on a lighter segment of its own that slides over when another is picked.
/// Cmd-1 and Cmd-2 pick them too.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var namespace
    @State private var hovered: SettingsTab?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 28
    /// Between the track's edge and the chosen tab's segment.
    static let inset: CGFloat = 2
    static let cornerRadius: CGFloat = 8
    /// The grouped form's own side margin, so the track lines up with its sections.
    static let sideMargin: CGFloat = 20

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .background { track }
        .padding(.horizontal, Self.sideMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
    }

    /// The control's groove: a shade darker or lighter than the window, with a hairline
    /// edge that's lit along the bottom, as macOS draws it.
    private var track: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return shape
            .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.055))
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: isDark
                                   ? [.white.opacity(0.07), .white.opacity(0.13)]
                                   : [.black.opacity(0.06), .black.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            }
    }

    /// The chosen tab's segment, which slides from tab to tab.
    private var segment: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset, style: .continuous)
        return shape
            .fill(isDark ? Color(white: 0.40) : .white)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: isDark
                                   ? [.white.opacity(0.16), .white.opacity(0.03)]
                                   : [.black.opacity(0.02), .black.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(isDark ? 0.30 : 0.14), radius: 1.25, y: 0.5)
    }

    private func item(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selection
        return Button {
            select(tab)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primary.opacity(isSelected || hovered == tab ? 1 : 0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        // Behind the button rather than in its label, so a press dims only the label.
        .background {
            if isSelected {
                segment.matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
        .keyboardShortcut(KeyEquivalent(Character(String(tab.rawValue + 1))), modifiers: .command)
        .onHover { inside in
            if inside {
                hovered = tab
            } else if hovered == tab {
                hovered = nil
            }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ tab: SettingsTab) {
        guard tab != selection else { return }
        if reduceMotion {
            selection = tab
        } else {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { selection = tab }
        }
    }
}

/// Dims a tab's symbol and name while it's held down, like a native segment.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
