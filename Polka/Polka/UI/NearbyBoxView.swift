import CryptoKit
import SwiftUI

/// What the Send To box beside the open panel shows (N5, NS-16). While a tile, or
/// something from another app, is dragged, it lists the Macs nearby to drop it on.
/// After a drop, it stays as a small sending indicator until each send has finished.
@MainActor
final class NearbyBoxModel: ObservableObject {
    /// A Mac nearby, as a row.
    struct Mac: Identifiable, Equatable {
        /// Its Bonjour name.
        let id: String
        let name: String
        /// The name's first letter or digit, on its circle.
        let initial: String
        /// Its circle's hue, from 0 to 1, made from its key so a Mac keeps its color.
        let hue: Double
        let isRemembered: Bool
        /// It can take what's being dragged.
        var canTake = true
        /// Why it can't, under its name.
        var note: String?
    }

    /// A send that started with a drop on the box.
    struct Send: Identifiable, Equatable {
        /// The transfer, for its ×.
        let id: UUID
        let mac: Mac
        var status: String
        /// How much has gone, from 0 to 1; nil while waiting for an answer.
        var fraction: Double?
        var isFinished = false
        var succeeded = false
    }

    /// One row: a Mac, and its send if there is one.
    struct Row: Identifiable, Equatable {
        let mac: Mac
        let send: Send?
        var id: String { send.map { $0.id.uuidString } ?? mac.id }
    }

    @Published var macs: [Mac] = []
    /// A drag that can be sent is going on: every Mac shows, to drop on.
    @Published var isDragging = false
    /// The Mac the drag is over.
    @Published var hoveredID: String?
    @Published var sends: [Send] = []
    /// A drag ended over the box, and its drop hasn't been read yet. AppKit can tell
    /// Polka the drag is over before it hands the box the drop, so the box waits for
    /// it, as it was, Macs and all.
    @Published var isAwaitingDrop = false
    /// The box is on screen (it fades in and out).
    @Published var isShown = false
    var onStop: ((UUID) -> Void)?

    var wantsToShow: Bool { listsMacs || !sends.isEmpty }

    /// The Macs show, to drop on: during a drag, and while its drop is on its way.
    var listsMacs: Bool { isDragging || isAwaitingDrop }

    /// While dragging, the Macs to drop on, each with its latest send; after, only
    /// the sends, so the box is an indicator of what's going.
    var rows: [Row] {
        guard listsMacs else { return sends.map { Row(mac: $0.mac, send: $0) } }
        return macs.map { mac in Row(mac: mac, send: sends.last { $0.mac.id == mac.id }) }
    }

    /// A Mac's row from what Nearby Sharing found. One that can't take what's being
    /// dragged is listed but dimmed: anything at all on N1's Polka, files on N2's.
    static func mac(_ peer: NearbyService.Peer, carryingFiles: Bool) -> Mac {
        let canTake = peer.takesOffers && (!carryingFiles || peer.version >= NearbyProtocol.fileVersion)
        return Mac(id: peer.id, name: peer.name, initial: initial(of: peer.name),
                   hue: hue(for: peer.publicKey ?? Data(peer.name.utf8)), isRemembered: peer.isRemembered,
                   canTake: canTake, note: canTake ? nil : "Needs a newer Polka")
    }

    static func initial(of name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    /// From the key's hash, so it's the same on every Mac and every launch.
    static func hue(for key: Data) -> Double {
        Double(Array(SHA256.hash(data: key))[0]) / 256
    }
}

/// Where each row and its circle are drawn, in the box's SwiftUI space (the hosting
/// view, from the top left), for the drop view to tell which Mac a drag is over. A
/// plain class, like `PressAreas`: nothing is drawn from it.
@MainActor
final class NearbyBoxGeometry {
    var rows: [String: CGRect] = [:]
    var circles: [String: CGRect] = [:]

    func mac(at point: CGPoint) -> String? {
        rows.first { $0.value.contains(point) }?.key
    }
}

/// The box: "Send To" over a row per Mac, on the panel's own glass.
struct NearbyBoxView: View {
    @ObservedObject var model: NearbyBoxModel
    let geometry: NearbyBoxGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(ShelfSettings.panelTransparencyKey) private var storedTransparency = ShelfSettings.defaultPanelTransparency
    @AppStorage(ShelfSettings.panelColorKey) private var storedColor = ""

    static let width: CGFloat = 232
    static let rowHeight: CGFloat = 44
    /// Rows past this many scroll.
    static let maxVisibleRows = 5
    static let titleHeight: CGFloat = 22
    static let padding: CGFloat = 8
    /// Room around the box for its shadow, inside its window.
    static let shadowMargin: CGFloat = 12

    /// The box's own size for this many rows, without the shadow's room.
    static func size(rows: Int) -> CGSize {
        let shown = CGFloat(min(max(rows, 1), maxVisibleRows))
        return CGSize(width: width, height: padding * 2 + titleHeight + shown * rowHeight)
    }

    private var transparency: Double {
        guard !reduceTransparency else { return 0 }
        return Double(ShelfSettings.panelTransparency(stored: storedTransparency)) / 100
    }

    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 0) {
            Text(model.listsMacs ? "Send To" : "Sending")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(height: Self.titleHeight, alignment: .center)
                .padding(.leading, 8)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        NearbyBoxRow(row: row, isHovered: model.hoveredID == row.mac.id && model.listsMacs,
                                     geometry: geometry, onStop: { model.onStop?($0) })
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
        }
        .padding(Self.padding)
        .frame(width: Self.width, height: Self.size(rows: rows.count).height, alignment: .top)
        .background(NearbyBoxBackground(transparency: transparency,
                                        color: ShelfSettings.panelColor(stored: storedColor)))
        .padding(Self.shadowMargin)
        // Out of the panel's side: it grows in from its right edge as it fades in.
        .scaleEffect(model.isShown || reduceMotion ? 1 : 0.9, anchor: .trailing)
        .opacity(model.isShown ? 1 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.2)
                   : model.isShown ? .spring(duration: 0.35, bounce: 0.12) : .easeIn(duration: 0.18),
                   value: model.isShown)
        .environment(\.colorScheme, .dark)
    }
}

/// One Mac: its circle, its name, and how a send to it is going.
private struct NearbyBoxRow: View {
    let row: NearbyBoxModel.Row
    let isHovered: Bool
    let geometry: NearbyBoxGeometry
    let onStop: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mac: NearbyBoxModel.Mac { row.mac }

    var body: some View {
        HStack(spacing: 10) {
            NearbyMacCircle(mac: mac, send: row.send)
                .scaleEffect(isHovered && !reduceMotion ? 1.12 : 1)
                .animation(.spring(duration: 0.25, bounce: 0.3), value: isHovered)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    geometry.circles[mac.id] = frame
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(mac.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHovered ? 1 : 0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let line = row.send?.status ?? mac.note {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let send = row.send {
                if !send.isFinished {
                    Button { onStop(send.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Stop Sending")
                } else if send.succeeded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: NearbyBoxView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(isHovered ? 0.12 : 0)))
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .opacity(mac.canTake || row.send != nil ? 1 : 0.45)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            geometry.rows[mac.id] = frame
        }
        // Gone, it's no longer something to drop on.
        .onDisappear {
            geometry.rows[mac.id] = nil
            geometry.circles[mac.id] = nil
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Mac's initial on a circle of its own color, with Polka's glass light on it, a
/// seal when it's remembered, and a ring while something is being sent to it.
struct NearbyMacCircle: View {
    let mac: NearbyBoxModel.Mac
    var send: NearbyBoxModel.Send? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let side: CGFloat = 30
    /// Polka's fixed blue, as on the active sort button: #2881DB.
    private static let sealColor = Color(red: 0x28 / 255, green: 0x81 / 255, blue: 0xDB / 255)

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hue: mac.hue, saturation: 0.42, brightness: 0.97),
                                                  Color(hue: mac.hue, saturation: 0.68, brightness: 0.70)],
                                         startPoint: .top, endPoint: .bottom))
            Circle().fill(PanelBackground.sheen)
            Circle().strokeBorder(Glass.rim, lineWidth: Glass.rimWidth)
            Text(mac.initial)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(alignment: .bottomTrailing) {
            if mac.isRemembered {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white, Self.sealColor)
                    .offset(x: 4, y: 3)
                    .accessibilityLabel("Remembered")
            }
        }
        .overlay {
            if let send, !send.isFinished {
                SendRing(fraction: send.fraction)
                    .frame(width: Self.side + 7, height: Self.side + 7)
            }
        }
    }
}

/// How far a send has gone, around the circle: an arc that fills, or while waiting
/// for an answer, a short arc that goes round (a still, faint ring with Reduce Motion).
private struct SendRing: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let fraction {
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: fraction)
        } else if reduceMotion {
            Circle().stroke(.white.opacity(0.35), lineWidth: 2)
        } else {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
        }
    }
}

/// The box's glass, as the open panel's (Settings' Transparency and Color), on a
/// rounded rectangle. Its top isn't the screen's edge, so its rim of light runs all the
/// way round, brightest along the top, like Polka's other glass.
struct NearbyBoxBackground: View {
    let transparency: Double
    let color: PanelColor?

    static let cornerRadius: CGFloat = 16
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }

    var body: some View {
        ZStack {
            // The shadow, with the box cut out of it so it doesn't show through glass.
            shape.fill(Color.black)
                .shadow(color: .black.opacity(0.3), radius: 9, y: 6)
                .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
                .compositingGroup()
            if transparency > 0 {
                PanelGlass().clipShape(shape)
            }
            if let color {
                ZStack {
                    shape.fill(color.gradient.linear)
                    shape.fill(PanelBackground.sheen)
                }
                .opacity(1 - (1 - PanelBackground.leastTint) * transparency)
            }
            shape.fill(Color.black.opacity(color == nil ? 1 - transparency : 0))
            shape.strokeBorder(Glass.rim, lineWidth: Glass.rimWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
