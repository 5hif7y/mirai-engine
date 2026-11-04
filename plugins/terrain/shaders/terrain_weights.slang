//! mirai surface Terrain_Weights
//! parameter inspect {"default":[1,0,0,0],"min":0,"max":3}
namespace Terrain_Weights {
// The weights of the layers of a terrain as the editor inspects them, from
// uv0 and uv1 as Terrain_Layers reads them, rules included: inspect.x 1, a
// color for each layer; 2, the layer inspect.y from black to white.
struct Parameters {
    float4 inspect;
};
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    float4 w = max(float4(ctx.uv0, ctx.uv1), float4(0.0));
    float total = w.x + w.y + w.z + w.w;
    w = total > 0.0 ? w / total : float4(1.0, 0.0, 0.0, 0.0);
    float3 shown;
    if (p.inspect.x < 1.5) {
        shown = w.x * float3(0.85, 0.22, 0.18) + w.y * float3(0.25, 0.75, 0.3) + w.z * float3(0.2, 0.4, 0.9) + w.w * float3(0.92, 0.8, 0.2);
    } else {
        float v = w[clamp(int(p.inspect.y + 0.5), 0, 3)];
        shown = float3(v, v, v);
    }
    s.base_color = shown;
    s.roughness = 1.0;
    s.metallic = 0.0;
    return s;
}
}
