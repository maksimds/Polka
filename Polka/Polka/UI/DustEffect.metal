#include <metal_stdlib>

using namespace metal;

// A removed tile turning to dust, after Telegram's delete animation. A picture of the
// tile is cut into grains, one per point. A front sweeps across it from left to
// right, and each grain it passes breaks away in a random direction, rises like
// smoke and fades out. Until a grain moves it is exactly its square of the picture,
// so the dust starts out looking like the tile itself.
//
// Points run from the dust view's top left, y down, as in SwiftUI. Time is in
// simulation seconds, which run twice as fast as real ones (DustView.swift).

// Matches DustGrain in DustView.swift.
struct DustGrain {
    // How far the grain has drifted from its square, in points.
    float2 offset;
    // In points per simulation second.
    float2 velocity;
    // Simulation seconds left before the grain is gone.
    float life;
    float padding;
};

// One tile's dust. Matches DustPiece in DustView.swift.
struct DustPiece {
    // The picture's top left and size in the view, in points.
    float2 origin;
    float2 size;
    float2 viewSize;
    // Grains across and down.
    uint2 grid;
    // Real seconds since the tile was removed.
    float phase;
    // Simulation seconds since the last frame.
    float step;
    // Picks this tile's own random grains, so two tiles don't break up alike.
    uint seed;
    float padding;
};

// The front takes this long, in real seconds, to cross the tile.
constant float sweepDuration = 0.8;
// A grain gets up to speed while the front moves this far, as a part of the width,
// so the edge where the tile comes apart is soft rather than a line.
constant float releaseWidth = 0.8;
// How fast a grain breaks away, in points per simulation second.
constant float slowestBurst = 42.0;
constant float fastestBurst = 84.0;
// The pull that makes the dust rise, in points per simulation second squared.
constant float rise = 120.0;
// How long a grain lasts once it's moving, in simulation seconds. The longest life
// is also in DustView.swift, which works out from it when a tile's dust is gone.
constant float shortestLife = 0.7;
constant float longestLife = 1.5;
// A grain fades out over its last moments.
constant float fadeTime = 0.3;

// A random value in [0, 1) for a grain. `salt` gives the same grain independent values.
static float grainRandom(uint grain, uint salt, uint seed) {
    // Chris Wellons's "lowbias32" integer hash.
    uint x = grain * 0x9e3779b9u ^ (salt * 0x85ebca6bu) ^ seed;
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return float(x >> 8) * (1.0 / 16777216.0);
}

// How much of its full speed a grain at `x` (0 at the left edge, 1 at the right)
// moves with at `phase`: 0 until the front reaches it, then rising to 1.
static float releasePace(float phase, float x) {
    float sweep = clamp(phase / sweepDuration, 0.0, 1.0);
    // The front starts a release width before the left edge and ends at the right one.
    float front = mix(-releaseWidth, 1.0, sweep);
    return 1.0 - clamp((x - front) / releaseWidth, 0.0, 1.0);
}

// Each grain's burst and life, once, before the tile's first frame.
kernel void dustScatter(device DustGrain *grains [[buffer(0)]],
                        constant DustPiece &piece [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
    if (id >= piece.grid.x * piece.grid.y) {
        return;
    }
    float angle = grainRandom(id, 0, piece.seed) * 2.0 * M_PI_F;
    float speed = mix(slowestBurst, fastestBurst, grainRandom(id, 1, piece.seed));
    DustGrain grain;
    grain.offset = float2(0.0);
    grain.velocity = float2(cos(angle), sin(angle)) * speed;
    grain.life = mix(shortestLife, longestLife, grainRandom(id, 2, piece.seed));
    grain.padding = 0.0;
    grains[id] = grain;
}

// Moves every grain the front has reached on by one frame.
kernel void dustDrift(device DustGrain *grains [[buffer(0)]],
                      constant DustPiece &piece [[buffer(1)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= piece.grid.x * piece.grid.y) {
        return;
    }
    float x = (float(id % piece.grid.x) + 0.5) / float(piece.grid.x);
    float pace = releasePace(piece.phase, x);
    if (pace <= 0.0) {
        return;
    }
    DustGrain grain = grains[id];
    float step = piece.step * pace;
    grain.offset += grain.velocity * step;
    // Up is toward smaller y.
    grain.velocity.y -= rise * step;
    grain.life = max(0.0, grain.life - step);
    grains[id] = grain;
}

struct GrainFragment {
    float4 position [[position]];
    // Where the grain's corner is in the picture, 0 to 1 across and down.
    float2 pictureCoordinate;
    float opacity;
};

constant float2 grainCorners[6] = {
    float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
    float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0)
};

// Each grain is two triangles, one draw per tile with one instance per grain.
vertex GrainFragment dustGrainVertex(const device DustGrain *grains [[buffer(0)]],
                                     constant DustPiece &piece [[buffer(1)]],
                                     uint corner [[vertex_id]],
                                     uint id [[instance_id]]) {
    DustGrain grain = grains[id];
    float2 cell = float2(id % piece.grid.x, id / piece.grid.x);
    float2 grainSize = piece.size / float2(piece.grid);
    float2 inPicture = (cell + grainCorners[corner]) * grainSize;
    float2 point = piece.origin + inPicture + grain.offset;

    GrainFragment out;
    // Metal's clip space runs from -1 to 1, with y up.
    out.position = float4(point.x / piece.viewSize.x * 2.0 - 1.0,
                          1.0 - point.y / piece.viewSize.y * 2.0,
                          0.0, 1.0);
    out.pictureCoordinate = inPicture / piece.size;
    out.opacity = clamp(grain.life / fadeTime, 0.0, 1.0);
    if (out.opacity <= 0.0) {
        // A grain that's gone is moved off the view, so it isn't drawn at all.
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
    }
    return out;
}

// The grain's own bit of the picture, faded, and only inside the panel's outline.
fragment half4 dustGrainFragment(GrainFragment in [[stage_in]],
                                 texture2d<half> picture [[texture(0)]],
                                 texture2d<half, access::read> outline [[texture(1)]]) {
    constexpr sampler pictureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    half4 color = picture.sample(pictureSampler, in.pictureCoordinate);
    uint2 pixel = min(uint2(in.position.xy), uint2(outline.get_width() - 1, outline.get_height() - 1));
    half inside = outline.read(pixel).r;
    // The picture's colors are premultiplied, so fading scales all four.
    return color * half(in.opacity) * inside;
}
