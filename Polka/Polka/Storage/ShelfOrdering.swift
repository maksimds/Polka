import Foundation

extension Array where Element: Identifiable {
    /// The list with the elements in `ids` taken out and put back side by side, in
    /// the order they were in, so that the first of them lands at `index`.
    ///
    /// `index` counts among the elements that stay, so it runs from 0 (the front) to
    /// the number left over (the end). Anything outside that range is clamped.
    func moving(_ ids: Set<Element.ID>, to index: Int) -> [Element] {
        let moved = filter { ids.contains($0.id) }
        guard !moved.isEmpty else { return self }
        var rest = filter { !ids.contains($0.id) }
        rest.insert(contentsOf: moved, at: Swift.min(Swift.max(index, 0), rest.count))
        return rest
    }
}
