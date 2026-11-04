//! mirai needs nested_views
#include "native.slang"
// The pixels of a view that look into a mirror (nested_face.slang). Their depth
// becomes that of the face, which is in front of the body that reflects for the
// rays.
#include "nested_face.slang"

struct Params_Block {
    float4 to_local[3]; // rows: the world into the space of the mirror, where its face is the unit square of z = 0 and z is metres in front of it
    uint index;         // of its nested view
    uint ellipse;
    uint pad0;
    uint pad1;
};
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);

[shader("fragment")]
Nested_Face_Output main(float4 pixel : SV_Position) {
    float3 crossing;
    if (!nested_face_crossing(pixel, params.to_local[2], crossing)) discard;
    float2 at = float2(dot(params.to_local[0].xyz, crossing) + params.to_local[0].w, dot(params.to_local[1].xyz, crossing) + params.to_local[1].w);
    if (params.ellipse != 0u ? dot(at, at) > 0.25 : any(abs(at) > float2(0.5))) discard;
    return nested_face_output(crossing, params.index);
}
