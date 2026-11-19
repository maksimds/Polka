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

    /// Filled symbols, as in an iOS tab bar.
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

/// A capsule of tabs after the iOS 26 tab bar (Apple Music's, for one): each tab a
/// filled symbol over its name, the chosen one on a lighter capsule of its own,
/// tinted Polka's blue, that slides over when another is picked. Cmd-1 and Cmd-2 pick
/// them too.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var namespace
    @State private var hovered: SettingsTab?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Polka's fixed blue, as on the active sort button: #2881DB.
    static let tint = Color(red: 0x28 / 255, green: 0x81 / 255, blue: 0xDB / 255)
    static let itemWidth: CGFloat = 135
    static let itemHeight: CGFloat = 39
    /// Between the track's edge and the chosen tab's capsule.
    static let inset: CGFloat = 3

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        .padding(Self.inset)
        .background {
            Capsule()
                .fill(isDark ? Color(white: 0.09) : Color.black.opacity(0.06))
                .overlay(Capsule().strokeBorder(rim(strength: isDark ? 0.10 : 0.07), lineWidth: 0.75))
                .shadow(color: .black.opacity(isDark ? 0.35 : 0.06), radius: 4.5, y: 1.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
    }

    private func item(_ tab: SettingsTab) -> some View {
        let isSelected = tab == selection
        return Button {
            select(tab)
        } label: {
            VStack(spacing: 1) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 18)
                Text(tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Self.tint : Color.primary.opacity(hovered == tab ? 1 : 0.82))
            .frame(width: Self.itemWidth, height: Self.itemHeight)
            .background {
                if isSelected {
                    Capsule()
                        .fill(isDark
                              ? LinearGradient(colors: [Color(white: 0.24), Color(white: 0.19)], startPoint: .top, endPoint: .bottom)
                              : LinearGradient(colors: [.white, .white], startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(rim(strength: isDark ? 0.14 : 0.05), lineWidth: 0.75))
                        .shadow(color: .black.opacity(isDark ? 0.4 : 0.12), radius: 2.25, y: 0.75)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(tab.rawValue + 1))), modifiers: .command)
        .onHover { inside in
            if inside {
                hovered = tab
            } else if hovered == tab {
                hovered = nil
            }
        }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// A thin line of light around a capsule, brightest along its top, as on Polka's glass.
    private func rim(strength: Double) -> LinearGradient {
        let color: Color = isDark ? .white : .black
        return LinearGradient(colors: [color.opacity(strength), color.opacity(strength * 0.35)],
                              startPoint: .top, endPoint: .bottom)
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
