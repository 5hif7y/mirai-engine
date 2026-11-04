#include "native.slang"
// The caustics over what is under the water (water.caustics_record): the
// direct light of each pixel in a fluid, under its surface, changed by the
// caustic pattern where the light of the sun that reaches it crossed the
// surface. Before the fog, which dims it with the depth.
#define WATER_STAGE
#include "scene.slang"
#include "water.slang"
#include "depth.slang"
#define MIRAI_GROUP_X 8
#define MIRAI_GROUP_Y 8
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> image : register(MIRAI_REGISTER(u, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] Texture2D<float> pattern : register(MIRAI_REGISTER(t, SLOT_PASS1), space0);
[[vk::binding(SLOT_PASS2, 0)]] Texture2D<float4> linear_depth : register(MIRAI_REGISTER(t, SLOT_PASS2), space0);
[[vk::binding(SLOT_PASS3, 0)]] Texture2D<float4> direct : register(MIRAI_REGISTER(t, SLOT_PASS3), space0);

// The pattern at a point in texels, repeating, between its four nearest.
float pattern_at(float2 texel) {
    float2 at = texel - 0.5;
    int2 base = int2(floor(at));
    float2 f = at - floor(at);
    int n = int(water.texels);
    float a = pattern.Load(int3(((base % n) + n) % n, 0));
    float b = pattern.Load(int3((((base + int2(1, 0)) % n) + n) % n, 0));
    float c = pattern.Load(int3((((base + int2(0, 1)) % n) + n) % n, 0));
    float d = pattern.Load(int3((((base + int2(1, 1)) % n) + n) % n, 0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 id : SV_DispatchThreadID) {
    int2 p = int2(id.xy);
    if (any(p >= int2(frame.resolution)) || frame.sun_direction.w < 0.5) return;
    float depth = linear_depth.Load(int3(p, 0)).r;
    if (depth_empty(depth) || depth_nested(depth)) return;
    float2 uv = (float2(p) + 0.5) * frame.inv_resolution;
    float3 position = position_from_depth(uv, depth_distance(depth));
    int at = water_at(position);
    if (at < 0) return;
    Water_Body b = bodies[at];
    bool plane = b.surface.y > 0.5;
    float under = (plane ? water_surface_at(b, position.xz) : b.surface.x) - position.y;
    if (!(under > 0.0) || !(b.look.x > 0.0)) return;
    // Up along the light to where it crossed the surface: on the waves, once more from the height there.
    float3 down = water_sun_under(b.look.z);
    float2 crossed = position.xz - down.xz * (under / max(-down.y, 0.2));
    if (plane && water_wave_count(b) > 0u) {
        under = max(water_surface_at(b, crossed) - position.y, 0.0);
        crossed = position.xz - down.xz * (under / max(-down.y, 0.2));
    }
    float gathered = pattern_at(water_detail_place(crossed, frame.origin.xyz) / WATER_DETAIL_SIZE * float(water.texels));
    // Sharp a little under the surface, softer deep down.
    float strength = b.look.x * saturate(under / 0.5) * exp(-under / 12.0);
    float4 color = image[p];
    color.rgb += direct.Load(int3(p, 0)).rgb * (gathered - 1.0) * strength;
    image[p] = float4(max(color.rgb, 0.0), color.a);
}
