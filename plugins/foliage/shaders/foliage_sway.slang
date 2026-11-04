// How the wind sways foliage, the one way of the hook of the vertices of its
// batches (foliage_vertex.slang) and of the compute of its variants
// (foliage_sway.comp.slang): how far a point `height` metres from where its
// plant stands moves along a wind of velocity `wind` (m/s) with `gusts`
// cycles per second, by `weight` (the red of its vertex color) and `amount`
// (metres per m/s of wind and metre of height: foliage.sway_amount of its
// type), at `phase` radians of its plant and `time` seconds.
#ifndef FOLIAGE_SWAY_SLANG
#define FOLIAGE_SWAY_SLANG
float3 foliage_sway_offset(float3 wind, float gusts, float height, float weight, float amount, float phase, float time) {
    float p = phase + time * gusts * 6.2831853;
    float sway = 0.6 + 0.4 * (sin(p) * 0.7 + sin(p * 2.3 + 1.7) * 0.3);
    return wind * (amount * weight * height * sway);
}
#endif
