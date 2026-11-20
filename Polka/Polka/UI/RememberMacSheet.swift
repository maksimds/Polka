import SwiftUI

/// The Remember a Nearby Mac sheet (NS-11), over the Nearby Sharing tab. While it's
/// open, Polka lists the Macs nearby and takes one remember request, for 2 minutes;
/// closing it cancels whatever is going on.
struct RememberMacSheet: View {
    @ObservedObject var nearby: NearbyService
    @AppStorage(ShelfSettings.nearbyReceiveFromKey) private var receiveFrom = NearbyReceiveFrom.everyone
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RememberSheetContent(
            phase: nearby.rememberPhase ?? .looking,
            macs: macs,
            visibleAs: receiveFrom == .remembered ? nearby.displayName : nil,
            onPick: { nearby.remember($0) },
            onConfirm: { nearby.confirmRememberCode() },
            onTryAgain: { nearby.rememberAgain() },
            onClose: { dismiss() }
        )
        .onAppear { nearby.startRemembering() }
        .onDisappear { nearby.stopRemembering() }
    }

    /// The Macs nearby that told their names, this Mac left out.
    private var macs: [RememberSheetContent.Mac] {
        nearby.peers.filter { $0.publicKey == nil || $0.publicKey != nearby.thisMacKey }.map { peer in
            if peer.isRemembered {
                return .init(id: peer.id, name: peer.name, note: "Remembered", canPick: false)
            } else if !peer.canRemember {
                return .init(id: peer.id, name: peer.name, note: "Needs a Newer Polka", canPick: false)
            }
            return .init(id: peer.id, name: peer.name, note: nil, canPick: true)
        }
    }
}

/// What the sheet shows for each step, from plain values, so every step can be drawn
/// without a connection.
struct RememberSheetContent: View {
    struct Mac: Identifiable, Equatable {
        let id: String
        let name: String
        /// Why it can't be picked, shown beside it.
        let note: String?
        let canPick: Bool
    }

    let phase: NearbyRememberPhase
    let macs: [Mac]
    /// This Mac's name, when it's hidden from strangers but shows while the sheet is
    /// open, to say so.
    let visibleAs: String?
    var onPick: (String) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var onTryAgain: () -> Void = {}
    var onClose: () -> Void = {}

    static let width: CGFloat = 420
    /// The list keeps one height as Macs come and go, so the sheet doesn't jump.
    static let listHeight: CGFloat = 168
    static let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(20)
        .frame(width: Self.width)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .looking:
            header("Remember a Nearby Mac",
                   "Ask the other person to choose Remember a Nearby Mac\u{2026} in Polka\u{2019}s Settings too, then pick their Mac. Once you remember each other, tiles between you arrive without asking.")
            list
            if let visibleAs {
                Text("While this is open, Macs nearby can see you as \u{201C}\(visibleAs)\u{201D}.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons { Button("Cancel", action: onClose).keyboardShortcut(.cancelAction) }
        case .stoppedLooking:
            header("Stopped Looking",
                   "Polka looks for Macs for 2 minutes at a time, and only while this is open.")
            buttons {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Look Again", action: onTryAgain).keyboardShortcut(.defaultAction)
            }
        case let .connecting(name, askedByThem):
            header(askedByThem ? "\(name) Wants to Remember This Mac" : "Asking \(name)\u{2026}",
                   askedByThem ? "Getting the code\u{2026}" : "Waiting for \(name)\u{2019}s Mac to answer.")
            spinnerRow
            buttons { Button("Cancel", action: onClose).keyboardShortcut(.cancelAction) }
        case let .comparing(name, code, askedByThem, confirmedHere):
            header(askedByThem ? "\(name) Wants to Remember This Mac" : "Remember \(name)?",
                   "Check that the same code shows on \(name). If it doesn\u{2019}t, cancel: another Mac may be answering in its place.")
            codeView(code)
            buttons {
                if confirmedHere {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(name)\u{2026}").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                if !confirmedHere {
                    Button("Codes Match", action: onConfirm).keyboardShortcut(.defaultAction)
                }
            }
        case let .remembered(name):
            result(symbol: "checkmark.circle.fill", color: .green, title: "\(name) Is Remembered",
                   detail: "Tiles between you now arrive without asking. You can forget it here at any time.")
            buttons { Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
        case let .failed(name, reason):
            let (title, detail) = Self.words(for: reason, name: name)
            result(symbol: "exclamationmark.triangle.fill", color: .yellow, title: title, detail: detail)
            buttons {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Try Again", action: onTryAgain).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Pieces

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func result(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.white, color)
            header(title, detail)
        }
    }

    /// The Macs nearby, in a box that keeps its height.
    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(macs.enumerated()), id: \.element.id) { index, mac in
                    if index > 0 { Divider().padding(.leading, 40) }
                    MacRow(mac: mac, onPick: onPick)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Before the overlay, which would otherwise take an empty list's zero width.
        .frame(maxWidth: .infinity)
        .frame(height: Self.listHeight)
        .overlay {
            if macs.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Macs\u{2026}").foregroundStyle(.secondary)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var spinnerRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: 64)
    }

    /// "131 485", large, in digits of one width, read out loud more easily in two parts.
    private func codeView(_ code: String) -> some View {
        Text(code)
            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
            .tracking(4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            .accessibilityLabel("Code \(code.map { String($0) }.joined(separator: " "))")
            .textSelection(.disabled)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Spacer()
            content()
        }
    }

    static func words(for reason: NearbyRememberFailure, name: String) -> (title: String, detail: String) {
        switch reason {
        case .notReady:
            return ("\(name) Isn\u{2019}t Ready",
                    "Make sure Remember a Nearby Mac\u{2026} is open on it too, then try again.")
        case .cancelledByThem:
            return ("\(name) Cancelled", "Nothing was remembered.")
        case .unreachable:
            return ("Couldn\u{2019}t Reach \(name)",
                    "Make sure it\u{2019}s nearby with Wi-Fi on, then try again. Nothing was remembered.")
        case .tooOld:
            return ("\(name) Needs a Newer Polka", "Its Polka can\u{2019}t remember Macs yet.")
        case .notVerified:
            return ("\(name) Couldn\u{2019}t Be Verified",
                    "Something didn\u{2019}t check out, so nothing was remembered. If it happens again, another Mac nearby may be answering in its place.")
        case .timedOut:
            return ("Not Confirmed in Time", "Nothing was remembered.")
        }
    }
}

/// One Mac in the sheet's list: picked with a click, highlighted under the pointer.
private struct MacRow: View {
    let mac: RememberSheetContent.Mac
    let onPick: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onPick(mac.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(mac.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let note = mac.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: RememberSheetContent.rowHeight)
            .contentShape(Rectangle())
            .background(isHovered && mac.canPick ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!mac.canPick)
        .opacity(mac.canPick ? 1 : 0.6)
        .onHover { isHovered = $0 }
    }
}
