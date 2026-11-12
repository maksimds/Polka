import Metal
import Testing
@testable import Polka

/// The dust a removed tile turns into (`DustEffect.metal`, `DustView.swift`).
@MainActor
struct DustTests {
    @Test func theShadersCompileAndTheirPipelinesBuild() {
        #expect(DustPipelines.shared != nil)
    }

    /// Swift fills the structs the shaders read, so both must lay them out the same.
    /// Metal reports the sizes it compiled them to.
    @Test func swiftAndMetalAgreeOnTheSharedLayouts() throws {
        let pipelines = try #require(DustPipelines.shared)
        let library = try #require(pipelines.device.makeDefaultLibrary())
        let drift = try #require(library.makeFunction(name: "dustDrift"))
        var reflection: MTLAutoreleasedComputePipelineReflection?
        _ = try pipelines.device.makeComputePipelineState(function: drift,
                                                           options: [.bindingInfo],
                                                           reflection: &reflection)
        let buffers = (reflection?.bindings ?? []).compactMap { $0 as? MTLBufferBinding }
        let sizes = Dictionary(uniqueKeysWithValues: buffers.map { ($0.index, $0.bufferDataSize) })
        #expect(sizes[0] == MemoryLayout<DustGrain>.stride)
        #expect(sizes[1] == MemoryLayout<DustPiece>.stride)
    }

    // MARK: - Placing a picture

    private let wholePanel = CGRect(x: 0, y: 0, width: 520, height: 270)

    /// On the pixel grid, as the tile was drawn, so the dust's first frame matches it.
    @Test func aPictureInViewIsPlacedWholeOnThePixelGrid() throws {
        let placement = try #require(DustPlacement(pictureWidth: 100, pictureHeight: 60, scale: 2,
                                                   origin: CGPoint(x: 10.3, y: 20.2),
                                                   visibleArea: wholePanel))
        #expect(placement.crop == CGRect(x: 0, y: 0, width: 100, height: 60))
        #expect(placement.frame == CGRect(x: 10.5, y: 20, width: 50, height: 30))
    }

    /// A tile half scrolled out of sight only turns its visible half to dust.
    @Test func aPictureCutByTheGridsEdgeKeepsOnlyWhatShows() throws {
        let placement = try #require(DustPlacement(pictureWidth: 100, pictureHeight: 60, scale: 2,
                                                   origin: CGPoint(x: 10, y: 80),
                                                   visibleArea: CGRect(x: 0, y: 100, width: 520, height: 150)))
        #expect(placement.crop == CGRect(x: 0, y: 40, width: 100, height: 20))
        #expect(placement.frame == CGRect(x: 10, y: 100, width: 50, height: 10))
    }

    @Test func aPictureOutOfSightTurnsToNoDust() {
        #expect(DustPlacement(pictureWidth: 100, pictureHeight: 60, scale: 2,
                              origin: CGPoint(x: 10, y: 300),
                              visibleArea: wholePanel) == nil)
        #expect(DustPlacement(pictureWidth: 100, pictureHeight: 60, scale: 2,
                              origin: CGPoint(x: 10, y: 99.9),
                              visibleArea: CGRect(x: 0, y: 130, width: 520, height: 100)) == nil)
    }

    // MARK: - Removing

    /// Without the dust's view on screen (as in tests, or without Metal), items leave
    /// the shelf at once, as they did before there was dust.
    @Test func withoutTheDustsViewRemovedItemsLeaveAtOnce() {
        let store = ShelfStore()
        store.add(["a", "b", "c"].map { ShelfItem.Draft(fileURL: URL(fileURLWithPath: "/tmp/\($0)")) })
        let model = NotchViewModel(store: store)
        model.state = .expanded
        let ids = store.items.map(\.id)
        model.click(ids[1], .only)

        model.remove([ids[1]])

        #expect(store.items.map(\.id) == [ids[0], ids[2]])
        #expect(model.dissolvingItemIDs.isEmpty)
        #expect(model.selection.isEmpty)
    }
}
