//! mirai surface Water_Surface
//! parameter tint {"default":[1,1,1],"min":0,"max":1,"color":true}
//! parameter roughness {"default":0.02,"min":0,"max":1}
//! parameter detail {"default":1,"min":0,"max":4}
#include "water.slang"
namespace Water_Surface {
struct Parameters {float3 tint;float roughness;float detail;};
// The surface of the water of the plugin water: a glass the small waves bend
// (water.slang, the same the caustics follow). tint filters what is seen
// through it.
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s=mirai_surface_default(ctx);
    float2 slope=water_detail_slope(water_detail_place(ctx.world_position.xz,ctx.origin),ctx.time)*p.detail;
    float3 bent=normalize(float3(-slope.x,1.0,-slope.y));
    s.normal=normalize(ctx.normal+bent-float3(0.0,1.0,0.0));
    s.base_color=p.tint;
    s.roughness=p.roughness;
    return s;
}
}
