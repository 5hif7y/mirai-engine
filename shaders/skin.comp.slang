#include "native.slang"
#include "common.slang"
// Poses a skinned mesh: a group a cluster of the levels it poses, a thread a
// vertex of it. A vertex at rest is that of its cluster (geometry.slang) with
// what the morph targets add at their weights; the palette takes it where it
// is now and where it was in the frame before, as Posed_Vertex.
#define MIRAI_GROUP_X 64
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1
struct Skin_Joint { float4 current[3]; float4 previous[3]; };
// clusters: those it poses, from its first; output, previous: where the vertices go, words of the vertex pool.
struct Params_Block { uint mesh; uint clusters; uint output; uint previous; uint morph_count; uint pad0; uint pad1; uint pad2; };
struct Morph_Range { uint first; uint count; };
struct Morph_Delta { float3 position; float3 normal; float3 tangent; uint target; };
[[vk::binding(SLOT_PARAMS,0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b,SLOT_PARAMS),space0);
// The influences of each vertex of the mesh (asset.Skin_Vertex): eight joints in four words, eight weights of 255ths in two.
[[vk::binding(SLOT_PASS0,0)]] StructuredBuffer<uint> influences : register(MIRAI_REGISTER(t,SLOT_PASS0),space0);
[[vk::binding(SLOT_PASS1,0)]] StructuredBuffer<Skin_Joint> joints : register(MIRAI_REGISTER(t,SLOT_PASS1),space0);
[[vk::binding(SLOT_PASS2,0)]] StructuredBuffer<Morph_Range> morph_ranges : register(MIRAI_REGISTER(t,SLOT_PASS2),space0);
[[vk::binding(SLOT_PASS3,0)]] StructuredBuffer<Morph_Delta> morph_deltas : register(MIRAI_REGISTER(t,SLOT_PASS3),space0);
// Of each target, its weight now and in the frame before.
[[vk::binding(SLOT_PASS4,0)]] StructuredBuffer<float2> morph_weights : register(MIRAI_REGISTER(t,SLOT_PASS4),space0);
[[vk::binding(SLOT_MESHES,0)]] StructuredBuffer<Mesh> meshes : register(MIRAI_REGISTER(t,SLOT_MESHES),space0);
[[vk::binding(SLOT_VERTICES,0)]] RWStructuredBuffer<uint> vertex_words : register(MIRAI_REGISTER(u,SLOT_VERTICES),space0);
[[vk::binding(SLOT_INDICES,0)]] StructuredBuffer<uint> indices : register(MIRAI_REGISTER(t,SLOT_INDICES),space0);
#define MIRAI_POSED_STORE
#include "geometry.slang"

[shader("compute")]
[numthreads(MIRAI_GROUP_X,MIRAI_GROUP_Y,MIRAI_GROUP_Z)]
void main(uint3 group:SV_GroupID,uint3 lane:SV_GroupThreadID) {
    if (group.x>=params.clusters) return;
    Mesh mesh=meshes[params.mesh];
    Cluster c=mesh_cluster(mesh,group.x);
    for (uint local=lane.x;local<cluster_vertex_count(c);local+=MIRAI_GROUP_X) {
        uint index=c.vertex_first+local;
        float4 rows[3]={float4(0),float4(0),float4(0)};
        float4 old_rows[3]={float4(0),float4(0),float4(0)};
        uint packed_weights[2]={influences[index*6u+4u],influences[index*6u+5u]};
        for (uint i=0;i<8u;++i) {
            float weight=float((packed_weights[i>>2u]>>((i&3u)*8u))&255u)/255.0;
            if (weight==0) continue;
            uint id=(influences[index*6u+(i>>1u)]>>((i&1u)*16u))&65535u;
            Skin_Joint joint=joints[id];
            for (uint row=0;row<3u;++row) {
                rows[row]+=joint.current[row]*weight;
                old_rows[row]+=joint.previous[row]*weight;
            }
        }
        Mesh_Point rest=cluster_point_at(mesh,c,local,INVALID);
        float3 position=rest.position;
        float3 old_position=rest.position;
        float3 n=rest.normal;
        float4 tangent=rest.tangent;
        // The targets move the bind shape: the skin poses what they made of it.
        if (params.morph_count>0) {
            Morph_Range range=morph_ranges[index];
            float3 t=tangent.xyz;
            for (uint d=0;d<range.count;++d) {
                Morph_Delta delta=morph_deltas[range.first+d];
                float2 weight=morph_weights[delta.target];
                position+=delta.position*weight.x;
                n+=delta.normal*weight.x;
                t+=delta.tangent*weight.x;
                old_position+=delta.position*weight.y;
            }
            n=dot(n,n)>1e-20?normalize(n):rest.normal;
            t-=n*dot(n,t);
            if (dot(t,t)>1e-20) tangent.xyz=normalize(t);
        }
        float3 cof0=cross(rows[1].xyz,rows[2].xyz);
        float3 cof1=cross(rows[2].xyz,rows[0].xyz);
        float3 cof2=cross(rows[0].xyz,rows[1].xyz);
        float determinant=dot(rows[0].xyz,cof0);
        float3 normal=float3(dot(cof0,n),dot(cof1,n),dot(cof2,n));
        if (dot(normal,normal)>1e-20) n=normalize(normal)*(determinant<0?-1.0:1.0);
        uint packed_normal=packSnorm2x16(oct_encode(n));
        // The tangent is a direction along the surface: it goes with the rows, and
        // a reflection turns the side its bitangent is on.
        float3 t=float3(dot(rows[0].xyz,tangent.xyz),dot(rows[1].xyz,tangent.xyz),dot(rows[2].xyz,tangent.xyz));
        uint packed_tangent=pack_tangent(dot(t,t)>1e-20?normalize(t):tangent.xyz,determinant<0?-tangent.w:tangent.w);
        Posed_Vertex now,before;
        now.position=transform_point(rows,position);now.normal=packed_normal;now.tangent=packed_tangent;
        before.position=transform_point(old_rows,old_position);before.normal=packed_normal;before.tangent=packed_tangent;
        posed_store(params.output,index,now);
        posed_store(params.previous,index,before);
    }
}
