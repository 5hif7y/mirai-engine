//! mirai surface Terrain_Layers
//! parameter color0 {"kind":"texture","srgb":true}
//! parameter color1 {"kind":"texture","srgb":true}
//! parameter color2 {"kind":"texture","srgb":true}
//! parameter color3 {"kind":"texture","srgb":true}
//! parameter normal0 {"kind":"texture"}
//! parameter normal1 {"kind":"texture"}
//! parameter normal2 {"kind":"texture"}
//! parameter normal3 {"kind":"texture"}
//! parameter layer0 {"default":[1,1,1,1],"min":0,"max":1}
//! parameter layer1 {"default":[1,1,1,1],"min":0,"max":1}
//! parameter layer2 {"default":[1,1,1,1],"min":0,"max":1}
//! parameter layer3 {"default":[1,1,1,1],"min":0,"max":1}
//! parameter detail0 {"default":[4,0,0,0],"min":0,"max":10000}
//! parameter detail1 {"default":[4,0,0,0],"min":0,"max":10000}
//! parameter detail2 {"default":[4,0,0,0],"min":0,"max":10000}
//! parameter detail3 {"default":[4,0,0,0],"min":0,"max":10000}
#include "terrain_projection.slang"
namespace Terrain_Layers {
// The terrain plugin fills these from the materials of the layers of a source.
// layerN: base color and roughness; detailN: metres of the tiling, height
// blend, metallic and normal map strength. The weights of the four layers
// arrive in uv0 and uv1.
struct Parameters {
    uint color0;uint color1;uint color2;uint color3;
    uint normal0;uint normal1;uint normal2;uint normal3;
    float4 layer0;float4 layer1;float4 layer2;float4 layer3;
    float4 detail0;float4 detail1;float4 detail2;float4 detail3;
};
// The base color (its alpha the height) of a layer and its normal in the
// world: each projection turns its normal map onto the surface (whiteout).
void layer_read(Mirai_Surface_Context ctx, uint color, uint normal_map, float4 detail, float3 n, float3 weights, out float4 c, out float3 bent) {
    c = float4(0.0);
    bent = float3(0.0);
    for (int which = 0; which < 3; which++) {
        float w = weights[which];
        if (w <= 0.0) continue;
        Projection p = projection(which, n);
        c += w * mirai_sample_texture_projected(ctx, color, p.u, p.v, detail.x);
        float3 t = float3(0.0, 0.0, 1.0);
        if (detail.w > 0.0) {
            float2 xy = (mirai_sample_texture_projected(ctx, normal_map, p.u, p.v, detail.x).rg * 2.0 - 1.0) * detail.w;
            t = float3(xy, sqrt(saturate(1.0 - dot(xy, xy))));
        }
        float3 r = float3(t.x + dot(n, p.u), t.y + dot(n, p.up), abs(t.z) * dot(n, p.axis));
        bent += w * (r.x * p.u + r.y * p.up + r.z * p.axis);
    }
}
Mirai_Surface evaluate(Mirai_Surface_Context ctx, Parameters p) {
    Mirai_Surface s = mirai_surface_default(ctx);
    float4 w = max(float4(ctx.uv0, ctx.uv1), float4(0.0));
    float total = w.x + w.y + w.z + w.w;
    w = total > 0.0 ? w / total : float4(1.0, 0.0, 0.0, 0.0);
    uint colors[4] = {p.color0, p.color1, p.color2, p.color3};
    uint normals[4] = {p.normal0, p.normal1, p.normal2, p.normal3};
    float4 layers[4] = {p.layer0, p.layer1, p.layer2, p.layer3};
    float4 details[4] = {p.detail0, p.detail1, p.detail2, p.detail3};
    float3 n = ctx.normal;
    float3 weights = projection_weights(ctx.vertex_normal, ctx.ray);
    // A point of a single layer, as most of a terrain is, shades it alone:
    // the same surface the blend below gives, without its loops.
    if (w.y + w.z + w.w <= 0.0) {
        float4 c;
        float3 bent0;
        layer_read(ctx, p.color0, p.normal0, p.detail0, n, weights, c, bent0);
        s.normal = dot(bent0, bent0) > 1e-12 ? normalize(bent0) : n;
        s.base_color = c.rgb * p.layer0.rgb * ctx.vertex_color.rgb;
        s.roughness = p.layer0.w;
        s.metallic = p.detail0.z;
        return s;
    }
    float3 albedo[4];
    float3 bent[4];
    float4 blend = float4(0.0);
    for (int i = 0; i < 4; i++) {
        albedo[i] = float3(0.0);
        bent[i] = n;
        if (w[i] <= 0.0) continue;
        float4 c;
        layer_read(ctx, colors[i], normals[i], details[i], n, weights, c, bent[i]);
        albedo[i] = c.rgb * layers[i].rgb;
        // The alpha of the base color map is the height of the layer: where
        // layers meet the higher texels show through.
        blend[i] = w[i] * exp2(5.0 * details[i].y * c.a);
    }
    float sum = blend.x + blend.y + blend.z + blend.w;
    blend = sum > 0.0 ? blend / sum : w;
    float3 color = float3(0.0);
    float3 normal = float3(0.0);
    float roughness = 0.0;
    float metallic = 0.0;
    for (int i = 0; i < 4; i++) {
        color += albedo[i] * blend[i];
        normal += bent[i] * blend[i];
        roughness += layers[i].w * blend[i];
        metallic += details[i].z * blend[i];
    }
    s.normal = dot(normal, normal) > 1e-12 ? normalize(normal) : n;
    // The colors of a Mesh source tint the layers, as they tint a material.
    s.base_color = color * ctx.vertex_color.rgb;
    s.roughness = roughness;
    s.metallic = metallic;
    return s;
}
}
