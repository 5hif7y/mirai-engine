#include "native.slang"
// Shadows, second pass: shadow_trace.comp traced one pixel of each block
// (of 2x2, or the pixel itself), and this averages them over the frames in
// which each took its turn. The block takes its rays when the traced pixel lies on the surface
// the block stands for; otherwise it keeps its history. Without history, a
// ray from another surface says nothing of its own (the jitter moves the
// pixel of the block across an edge, and the face beyond, which no light
// faces, would light the one in shadow), nor does a pixel with no light above
// its horizon, which traced none (on a wall that faces away from the sun, the
// side of a joint its normal map tilts toward the sun would take it whole):
// the block holds no frames, the filter and lighting.comp pass it by, and its
// pixels trace rays of their own. The blur the penumbras ask for is averaged alongside: that of the
// rays that met a caster, and the share of the rays that did.
//
// What casts a shadow can move while the surface under it stays: the history
// is kept within what this frame's rays around the block say, so the shadow
// leaves no trail where it was and shows at once where it is; and the further
// the clamp moved the history beyond the half width of the box, the fewer
// frames it counts for, as SIGMA of NRD shortens it: what it held of the
// shadow that left does not linger. A clamp within the half width is the
// spread of the rays around a thin shadow, not a change, and shortens nothing:
// shortened in every frame, its history stayed halfway to the edge of the box. A block whose
// ray met what casts shadows and changed, or a light that moved
// (SHADOW_RAY_MOVED), starts again from this frame's ray, with the width of
// its penumbra. The box of what changed holds where it was too, so the ray of
// a shadow that leaves meets it in the frame it leaves; starting again in the
// frame after as well threw away a ray taken where the caster already was. The
// mark goes on in the widths for the TAA (taa.comp).
//
// Where the surface moves on screen, the history is read again from between
// the blocks of the frame before every frame, and what it holds spreads along
// the motion (a patch of sun through stained glass trails behind itself): the
// faster it moves, the fewer frames it keeps, and it keeps within the rays of
// the blocks right around it. Where it stays still, the history goes on over
// what the ray of the block sees in a round of its pattern (params.still_history):
// the light points of a block are the same in every frame, and what changes
// is the pixel of the block that traces and the jitter of the view.
#include "scene.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

// block: pixels along each side of a block.
struct Params_Block { float max_history; float history_valid; float still_history; uint block; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
[[vk::binding(SLOT_PASS0, 0)]] Texture2D<float4> current_shadow : register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float4> current_geometry : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> previous_geometry : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> previous_history : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);
[[vk::binding(SLOT_PASS4, 0)]] Texture2D<float4> previous_widths : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
[[vk::binding(SLOT_PASS5, 0)]] Texture2D<float4> g_motion : register(MIRAI_REGISTER(t, SLOT_PASS5), space0);
#define GBUFFER_NORMAL SLOT_PASS6
#include "gbuffer.slang"
#include "pixel.slang"
[[vk::binding(SLOT_PASS7, 0)]] Texture2D<float4> g_depth : register(MIRAI_REGISTER(t, SLOT_PASS7), space0);
[[vk::binding(SLOT_PASS8, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_history : register(MIRAI_REGISTER(u, SLOT_PASS8), space0); // rgb share, a frames of history
[[vk::binding(SLOT_PASS9, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> out_widths : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);  // x: widths of the rays that met a caster; y: the share of the rays that did; z: 1 where the ray of the frame met what changed

// How far the history may be from the mean of the rays around the block,
// beyond their deviation.
static const float HISTORY_SLACK = 0.06;
// Pixels a surface moves on screen in a frame below which it counts as still.
static const float HISTORY_STILL = 0.25;

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 dispatch_id : SV_DispatchThreadID) {
    int2 cell = int2(dispatch_id.xy);
    int2 size = texture_size(out_history);
    if (any(((cell) >= (size)))) return;
    float4 geometry = current_geometry.Load(int3(cell, 0));
    if (depth_empty(geometry.w)) {
        out_history[cell] = float4(1.0, 1.0, 1.0, 0.0);
        out_widths[cell] = float4(0.0);
        return;
    }
    int2 full = int2(frame.resolution);
    int span = int(params.block);
    int2 reference = min(cell * span, full - 1);
    int2 traced = min(cell * span + block_pixel(frame.frame_index, params.block), full - 1);
    float4 raw = current_shadow.Load(int3(cell, 0));
    bool changed = shadow_ray_moved(raw.a);
    raw.a = shadow_ray_state(raw.a);
    float2 motion = g_motion.Load(int3(reference, 0)).rg;
    float2 uv = (float2(reference) + 0.5) * frame.inv_resolution;
    // Block q stands for full-res pixel q * span (center q * span + 0.5).
    float2 previous_pixel = ((uv + motion) * frame.resolution - 0.5) / float(span);
    // The depth the surface had for the previous camera: a camera that moves
    // along its view changes every depth at once without uncovering anything.
    float expected = previous_depth(reference, geometry.w, pixel_at(reference, uv, geometry.w).position);
    int2 base = int2(floor(previous_pixel));
    float2 f = previous_pixel - float2(base);
    float4 history = float4(0.0);
    float2 widths = float2(0.0);
    float weight_sum = 0.0;
    for (int i = 0; i < 4; i++) {
        int2 offset = int2(i & 1, i >> 1);
        int2 q = base + offset;
        if (any(((q) < (int2(0)))) || any(((q) >= (size)))) continue;
        float4 g = previous_geometry.Load(int3(q, 0));
        // Of whichever view: a camera carried into a nested view finds its past there.
        if (depth_empty(g.w) || abs(depth_distance(g.w) - expected) > 0.1 * expected || dot(g.xyz, geometry.xyz) < 0.9) continue;
        float4 kept = previous_history.Load(int3(q, 0));
        if (kept.a < 0.5) continue;
        float w = (offset.x == 1 ? f.x : 1.0 - f.x) * (offset.y == 1 ? f.y : 1.0 - f.y);
        float4 kept_widths = previous_widths.Load(int3(q, 0));
        history += kept * w;
        widths += kept_widths.xy * w;
        weight_sum += w;
    }
    float length_frames = 0.0;
    if (weight_sum > 0.01 && params.history_valid > 0.5) {
        history /= weight_sum;
        widths /= weight_sum;
        length_frames = history.a;
    }
    float moved = length(motion * frame.resolution);
    float longest = moved > HISTORY_STILL ? max(params.max_history / (1.0 + moved), 2.0) : params.still_history;
    length_frames = min(length_frames, longest);
    if (changed) length_frames = 0.0;
    float3 unclamped = history.rgb;
    // Half the width of the box the history is kept in.
    float3 spread = float3(1e30);
    if (length_frames >= 0.5 && moved > HISTORY_STILL) {
        float3 low = float3(1e30), high = float3(-1e30);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 q = clamp(cell + int2(dx, dy), int2(0), size - 1);
                float4 r = current_shadow.Load(int3(q, 0));
                if (r.a < 0.5) continue;
#ifdef MIRAI_NESTED_VIEWS
                if (!depth_same_side(current_geometry.Load(int3(q, 0)).w, geometry.w)) continue;
#endif
                low = min(low, r.rgb);
                high = max(high, r.rgb);
            }
        }
        if (all(low <= high)) {
            history.rgb = clamp(history.rgb, low, high);
            spread = (high - low) * 0.5;
        }
    } else if (length_frames >= 0.5) {
        float3 sum = float3(0.0);
        float3 squares = float3(0.0);
        float count = 0.0;
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                int2 q = clamp(cell + int2(dx, dy), int2(0), size - 1);
                float4 r = current_shadow.Load(int3(q, 0));
                if (r.a < 0.5) continue;
#ifdef MIRAI_NESTED_VIEWS
                if (!depth_same_side(current_geometry.Load(int3(q, 0)).w, geometry.w)) continue;
#endif
                sum += r.rgb;
                squares += r.rgb * r.rgb;
                count += 1.0;
            }
        }
        if (count > 0.0) {
            float3 mean = sum / count;
            float3 reach = sqrt(max(squares / count - mean * mean, float3(0.0))) + HISTORY_SLACK;
            history.rgb = clamp(history.rgb, mean - reach, mean + reach);
            spread = reach;
        }
    }
    // A history the clamp moved by the slack or more past the half width counts as one frame.
    float3 beyond = abs(history.rgb - unclamped) - spread;
    float clipped = max(beyond.r, max(beyond.g, beyond.b));
    if (clipped > 0.0) length_frames = min(length_frames, max(HISTORY_SLACK / clipped, 1.0));
    float2 fresh = raw.a >= 1.5 ? float2(raw.a - 2.0, 1.0) : float2(0.0);
    // Whether this frame's ray left from the surface the block stands for:
    // asked of a ray that met a light, and of a block with no history.
    bool own = true;
    if ((raw.a > 0.5 || length_frames < 0.5) && any(traced != reference)) {
        float d = g_depth.Load(int3(traced, 0)).r;
        float3 n = gbuffer_normal(traced);
        own = !depth_empty(d) && depth_same_side(d, geometry.w) && abs(depth_distance(d) - depth_distance(geometry.w)) <= 0.1 * depth_distance(geometry.w) && dot(n, geometry.xyz) >= 0.9;
    }
    bool sampled = raw.a > 0.5 && own;
    if (length_frames < 0.5) {
        // Nothing to go on: this frame's ray, if it came from the surface. A
        // pixel that saw no light above its horizon traced none, and says
        // nothing of the pixels of the block whose normal map tilts toward one.
        bool told = own && raw.a > 0.5;
        history.rgb = raw.rgb;
        widths = told ? fresh : float2(0.0);
        length_frames = told ? 1.0 : 0.0;
        sampled = false;
    }
    if (sampled) {
        length_frames = min(length_frames + 1.0, longest);
        float alpha = 1.0 / length_frames;
        history.rgb = lerp(history.rgb, raw.rgb, alpha);
        widths = lerp(widths, fresh, alpha);
    }
    out_history[cell] = float4(history.rgb, length_frames);
    out_widths[cell] = float4(widths, changed ? 1.0 : 0.0, 0.0);
}
