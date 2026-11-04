//! mirai hook vertex foliage_sway
// How the wind moves a vertex of an instance of foliage drawn by its batch
// alone, which no ray meets swaying (a type without shadows): along the wind
// where the instance stands, all of it (on a planet the wind is not level),
// more the farther it is from its place, which on any ground is how high it
// grows. params.x is the sway of its type (Batch_Desc.vertex). Each instance
// sways in a phase of its own, of the place of the world. The benders near it
// lean it away from them about its place, by the red of its vertex color as
// the wind does: grass where a body passes.
#include "foliage_sway.slang"

// The lean of the benders at a plant standing at pivot: along x and z of the
// world, radians long. The call for the motion vectors (time of the frame
// before) takes where they were then.
float2 foliage_bend(float3 pivot, float time) {
    bool before = time != frame.time.x;
    float2 lean = float2(0.0);
    uint count = min(frame.foliage_wind.count.x, uint(FOLIAGE_BENDERS));
    for (uint i = 0u; i < count; i++) {
        Foliage_Bender_Frame b = frame.foliage_wind.benders[i];
        float3 away = pivot - (before ? b.previous : b.position);
        float reach = 1.0 - smoothstep(0.4 * b.radius, b.radius, length(away));
        if (!(reach > 0.0)) continue;
        float across = length(away.xz);
        float2 side = across > 1e-4 ? away.xz / across : float2(1.0, 0.0);
        lean += side * (b.lean * reach);
    }
    float angle = length(lean);
    return angle > FOLIAGE_BEND_LEAN_MAX ? lean * (FOLIAGE_BEND_LEAN_MAX / angle) : lean;
}

float3 foliage_sway(float3 world, float3 pivot, float4 color, float4 params, float time) {
    float4 wind = wind_at(frame.foliage_wind.wind, pivot);
    // The phase of the place of the world, whose two waves repeat together every 20 pi radians: what the origin adds to it.
    float shift = origin_phase(frame.origin.xyz, float3(0.37, 0.0, 0.71) / 62.831853) * 62.831853;
    float phase = shift + dot(pivot.xz, float2(0.37, 0.71));
    float3 offset = world - pivot;
    float3 moved = world + foliage_sway_offset(wind.xyz, wind.w, length(offset), color.r, params.x, phase, time);
    float2 lean = foliage_bend(pivot, time) * color.r;
    float angle = length(lean);
    if (angle > 1e-4) {
        // Turned about the place of the plant, away from the benders: what stands up leans and comes down.
        float height = max(offset.y, 0.0);
        float2 side = lean / angle;
        moved += float3(side.x * sin(angle), cos(angle) - 1.0, side.y * sin(angle)) * height;
    }
    return moved;
}
