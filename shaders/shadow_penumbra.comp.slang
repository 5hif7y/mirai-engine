#include "native.slang"
// Shadows, last pass. The rays of the blocks of each 4x4 go to sixteen
// points of each light, so where a penumbra spans more than a block the share
// of neighbors differs. This filter smooths that into the penumbra the
// history holds: the trace stores how far each block asks to be blurred, the
// first two steps spread it to the blocks around a shadow, lit ones
// included, and the last two blur the share with it. Distances are measured
// along the surface, in metres, so a floor seen at a grazing angle blurs as
// much across the view as along it.
#include "scene.slang"
#include "pixel.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// step: 0 spreads the widths along x and 1 along y; 2 blurs the share along x and 3 along y.
// block: pixels along each side of a block.
struct Params_Block { uint step; uint block; uint pad1; uint pad2; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> source : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> geometry : register(MIRAI_REGISTER(t, SLOT_PASS1), space0); // normal and depth of each block
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> widths : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);   // steps 2 and 3: the standard deviation of the blur around each block, metres
[[vk::binding(SLOT_PASS3, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> target : register(MIRAI_REGISTER(u, SLOT_PASS3), space0);
// Step 0: the light that reaches each block with nothing in the way (shadow_trace.comp).
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float> light : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);

// Blocks to each side, closer together near the middle, and how much of the
// line each one stands for.
static const int TAPS = 7;
static const int OFFSETS[TAPS] = {0, 1, 2, 3, 4, 6, 9};
static const float SPANS[TAPS] = {1.0, 1.0, 1.0, 1.0, 1.5, 2.5, 3.0};
// The blurs the blocks around ask for count less the farther they are: the
// standard deviation of their weights, in blocks.
static const float WIDTH_REACH = 3.0;
// How far a block with one frame of history blurs, in blocks, and the
// frames of history from which it blurs no more than the others.
static const float YOUNG_BLUR_BLOCKS = 2.0;
static const float HISTORY_FULL = 8.0;
// A block is a pixel or more: never less blur than this many blocks.
static const float BLUR_MIN_BLOCKS = 0.5;
// The sixteen points of a light fall on the blocks of a 4x4: across a penumbra
// they leave a pattern that steps the edge every block. A penumbra blurs at
// least this many times what it asks for, up to PATTERN_BLOCKS blocks, which
// smooths the pattern: a contact shadow, which asks for nothing, stays sharp.
static const float PATTERN_SPREAD = 3.0;
static const float PATTERN_BLOCKS = 1.25;

// Whether block q lies on the plane of the surface of a block with geometry
// g, at the depth `expected` along it.
bool same_surface(int2 q, int2 size, float4 g, float expected, float distance) {
    if (any(((q) < (int2(0)))) || any(((q) >= (size)))) return false;
    float4 gq = geometry.Load(int3(q, 0));
    return !depth_empty(gq.w) && depth_same_side(gq.w, g.w) && abs(depth_distance(gq.w) - expected) <= 0.03 * distance && dot(gq.xyz, g.xyz) >= 0.9;
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 p = int2(dispatch_id.xy);
    int2 size = texture_size(target);
    if (any(((p) >= (size)))) return;
    float4 center = source.Load(int3(p, 0));
    float4 g = geometry.Load(int3(p, 0));
    if (depth_empty(g.w)) { target[p] = center; return; }
    int2 axis = (params.step & 1u) != 0u ? int2(0, 1) : int2(1, 0);
    // One block along the axis, on the plane of the surface: how many metres,
    // and how much deeper.
    int2 reference = min(p * int(params.block), int2(frame.resolution) - 1);
    float2 uv = (float2(reference) + 0.5) * frame.inv_resolution;
    float3 position = pixel_at(reference, uv, g.w).position;
    // The ray of the view of the block through the next block along the axis.
    float3 eye, ray;
    pixel_ray(reference, uv + float2(axis) * float(params.block) * frame.inv_resolution, g.w, eye, ray);
    ray = normalize(ray);
    float facing = dot(ray, g.xyz);
    float pitch = 1e3;
    float slope = 0.0;
    if (abs(facing) > 1e-3) {
        float3 next = eye + ray * (dot(position - eye, g.xyz) / facing) - position;
        pitch = length(next);
        slope = dot(next, pixel_forward(reference, g.w));
    }
    float distance = depth_distance(g.w);
    if (params.step < 2u) {
        // x: widths of the rays that met a caster, summed; y: how many did.
        // z: the light that reaches the blocks around, their mean: it comes
        // from the groups of the cut of each block, which change from one
        // to the next, and is wanted smooth.
        float2 sum = center.xy;
        float reached = params.step == 0u ? light.Load(int3(p, 0)) : center.z;
        float weight_sum = 1.0;
        for (int i = 1; i < TAPS; i++) {
            float near = float(OFFSETS[i]) / WIDTH_REACH;
            float w = SPANS[i] * exp(-0.5 * near * near);
            for (int side = -1; side <= 1; side += 2) {
                int2 q = p + axis * (OFFSETS[i] * side);
                if (!same_surface(q, size, g, distance + slope * float(OFFSETS[i] * side), distance)) continue;
                float4 tap = source.Load(int3(q, 0));
                sum += tap.xy * w;
                reached += (params.step == 0u ? light.Load(int3(q, 0)) : tap.z) * w;
                weight_sum += w;
            }
        }
        reached /= weight_sum;
        target[p] = params.step == 0u ? float4(sum, reached, 0.0) : float4(sum.y > 1e-4 ? sum.x / sum.y : 0.0, 0.0, reached, 0.0);
        return;
    }
    float asked = widths.Load(int3(p, 0)).x;
    float sigma = max(max(asked, pitch * BLUR_MIN_BLOCKS), min(asked * PATTERN_SPREAD, pitch * PATTERN_BLOCKS));
    // A block just uncovered holds the rays of one pixel, which went to one
    // point of each light: it blurs as far as its neighbors join them, less
    // as its frames add the others.
    sigma = max(sigma, pitch * YOUNG_BLUR_BLOCKS * saturate((HISTORY_FULL - center.a) / (HISTORY_FULL - 1.0)));
    float3 sum = center.rgb;
    float weight_sum = 1.0;
    for (int i = 1; i < TAPS; i++) {
        float d = float(OFFSETS[i]) * pitch / sigma;
        if (d > 3.0) break;
        float w = exp(-0.5 * d * d) * SPANS[i];
        for (int side = -1; side <= 1; side += 2) {
            int2 q = p + axis * (OFFSETS[i] * side);
            if (!same_surface(q, size, g, distance + slope * float(OFFSETS[i] * side), distance)) continue;
            float4 tap = source.Load(int3(q, 0));
            // A block with no frames holds no share of its surface (shadow_temporal.comp).
            if (tap.a < 0.5) continue;
            sum += tap.rgb * w;
            weight_sum += w;
        }
    }
    target[p] = float4(sum / weight_sum, center.a);
}
