import AppKit
import SwiftUI

/// The Send To box's window (N5, NS-16): a small panel of its own floating left of the
/// open shelf, shown while something that can be sent is dragged and while what was
/// dropped on it is being sent.
///
/// A window of its own rather than more room in the panel's: the panel's window takes
/// clicks in its clear part while open, and a wider one would swallow clicks meant for
/// whatever is beside the shelf. This one is as big as the box and its shadow, and
/// takes mouse events only while the box shows. A window that ignores them is no drop
/// target either, so a drag passes straight through it to what's behind.
@MainActor
final class NearbyBoxController {
    let model = NearbyBoxModel()
    /// What was dropped on a Mac, and which (its Bonjour name).
    var onDrop: (([ShelfItem], String) -> Void)? {
        get { dropView.onDrop }
        set { dropView.onDrop = newValue }
    }
    /// What of the tiles being dragged can go, asked during a drop.
    var tilesToSend: (() -> [ShelfItem])? {
        get { dropView.tilesToSend }
        set { dropView.tilesToSend = newValue }
    }
    /// The box came on screen, or went: while it's up, the Macs it lists must stay
    /// found, so the controller keeps Nearby Sharing looking.
    var onShownChange: ((Bool) -> Void)?

    private let geometry = NearbyBoxGeometry()
    private let dropView = NearbyBoxDropView(frame: .zero)
    /// Made the first time the box shows.
    private var panel: NotchPanel?
    /// The open shelf on screen, and the line the box hangs from (the menu bar's
    /// bottom), from the last `place`.
    private var anchor: (shelf: CGRect, top: CGFloat)?
    private var hideTask: Task<Void, Never>?
    private var awaitTask: Task<Void, Never>?
    private var removals: [UUID: Task<Void, Never>] = [:]
    /// Whether `onShownChange` last said shown.
    private var isUp = false

    /// Between the shelf's side and the box.
    static let gap: CGFloat = 14
    /// How long the box waits for the drop of a drag that ended over it.
    static let dropWait: Duration = .seconds(1)
    /// How long a finished send stays in the box.
    static let finishedSendDuration: Duration = .seconds(2)

    init() {
        dropView.geometry = geometry
        // Only while the box lists the Macs, and only a Mac that can take what's dragged.
        dropView.canTake = { [weak model] id in
            guard let model, model.listsMacs else { return false }
            return model.macs.first { $0.id == id }?.canTake ?? false
        }
        dropView.onHover = { [weak model] id in
            guard model?.hoveredID != id else { return }
            model?.hoveredID = id
        }
    }

    /// Where the box goes: left of `shelf`, hanging from `top`, both in screen points.
    /// Shows or hides it as the model wants.
    func place(beside shelf: CGRect, top: CGFloat) {
        anchor = (shelf, top)
        refresh()
    }

    /// The box itself on screen, while it shows.
    func contains(_ point: NSPoint) -> Bool {
        boxFrame?.contains(point) ?? false
    }

    /// While the box shows, the shelf, the box and the room between them, as one: a
    /// drag on its way from the shelf to the box crosses the gap between them, and
    /// mustn't count as leaving for somewhere else, which shrinks the shelf (and the box
    /// with it). Just the shelf while it doesn't.
    func reaches(_ point: NSPoint, from shelf: CGRect) -> Bool {
        Self.area(box: boxFrame, shelf: shelf).contains(point)
    }

    static func area(box: CGRect?, shelf: CGRect) -> CGRect {
        box.map { $0.union(shelf) } ?? shelf
    }

    private var boxFrame: CGRect? {
        guard model.isShown, let panel, panel.isVisible else { return nil }
        let margin = NearbyBoxView.shadowMargin
        return panel.frame.insetBy(dx: margin, dy: margin)
    }

    /// A drag ended with the pointer over the box: it stays as it is, listing the
    /// Macs, until the drop arrives or `dropWait` passes. Whichever AppKit reports
    /// first, the drag's end or the drop, the drop finds the box and its Macs.
    func awaitDrop() {
        model.isAwaitingDrop = true
        awaitTask?.cancel()
        awaitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dropWait)
            guard !Task.isCancelled, let self else { return }
            self.awaitTask = nil
            self.model.isAwaitingDrop = false
            self.refresh()
        }
        refresh()
    }

    // MARK: - Sends

    /// A drop on the box started a send to `mac`: it shows in the box until it ends.
    func addSend(_ transfer: UUID, to mac: NearbyBoxModel.Mac) {
        model.sends.append(NearbyBoxModel.Send(id: transfer, mac: mac, status: "Waiting\u{2026}"))
        awaitTask?.cancel()
        awaitTask = nil
        model.isAwaitingDrop = false
        refresh()
    }

    /// How that send is going. Once it ends, it stays a moment, then goes.
    func update(_ transfer: UUID, _ status: NearbyOutgoingSession.Status) {
        guard let index = model.sends.firstIndex(where: { $0.id == transfer }) else { return }
        let shown = NearbyBoxModel.words(for: status)
        model.sends[index].status = shown.text
        model.sends[index].fraction = shown.fraction
        guard status.isFinished, !model.sends[index].isFinished else { return }
        model.sends[index].isFinished = true
        model.sends[index].succeeded = status == .sent
        removals[transfer] = Task { [weak self] in
            try? await Task.sleep(for: Self.finishedSendDuration)
            guard !Task.isCancelled, let self else { return }
            self.removals[transfer] = nil
            self.model.sends.removeAll { $0.id == transfer }
            self.refresh()
        }
    }

    // MARK: - Private

    private func refresh() {
        guard model.wantsToShow, let anchor else {
            hide()
            return
        }
        hideTask?.cancel()
        hideTask = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NearbyBoxView.size(rows: model.rows.count)
        let margin = NearbyBoxView.shadowMargin
        let frame = CGRect(x: anchor.shelf.minX - Self.gap - size.width - margin,
                           y: anchor.top - size.height - margin,
                           width: size.width + margin * 2,
                           height: size.height + margin * 2)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.ignoresMouseEvents = false
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !isUp {
            isUp = true
            onShownChange?(true)
        }
        guard !model.isShown else { return }
        Log.window.info("Send To box shows: \(self.model.rows.count, privacy: .public) row(s), \(self.model.isDragging ? "a drag" : "sends", privacy: .public)")
        // A pass later, so SwiftUI draws it hidden first and it fades in.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.wantsToShow else { return }
            self.model.isShown = true
        }
    }

    private func hide() {
        if model.hoveredID != nil { model.hoveredID = nil }
        if isUp {
            isUp = false
            onShownChange?(false)
        }
        guard let panel, model.isShown || panel.isVisible else { return }
        if model.isShown {
            model.isShown = false
            Log.window.info("Send To box hides")
        }
        panel.ignoresMouseEvents = true
        guard hideTask == nil else { return }
        hideTask = Task { [weak self] in
            // Once it has faded out.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            if !self.model.isShown { self.panel?.orderOut(nil) }
        }
    }

    /// Like the notch's own panel: borderless, transparent, never key, on every Space,
    /// above the menu bar.
    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        let host = NSHostingView(rootView: NearbyBoxView(model: model, geometry: geometry))
        host.sizingOptions = []
        dropView.embed(host)
        panel.contentView = dropView
        return panel
    }
}

extension NearbyBoxModel {
    /// A send's line under the Mac's name, and how far its ring goes.
    static func words(for status: NearbyOutgoingSession.Status) -> (text: String, fraction: Double?) {
        switch status {
        case .connecting, .waiting: return ("Waiting\u{2026}", nil)
        case let .sending(fraction): return ("Sending \(Int(fraction * 100))%", fraction)
        case .sent: return ("Sent", 1)
        case .declined: return ("Declined", nil)
        case .cancelled: return ("Stopped", nil)
        case .failed(.tooOld): return ("Needs a newer Polka", nil)
        case .failed(.unreachable), .failed(.wrongMac): return ("Couldn\u{2019}t reach it", nil)
        case .failed(.tooLarge): return ("Over 1 GB", nil)
        case .failed(.unreadable): return ("Couldn\u{2019}t read a file", nil)
        case .failed(.nothingToSend): return ("Nothing to send", nil)
        }
    }
}
