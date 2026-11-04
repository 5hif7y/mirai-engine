#include "native.slang"
// A group per emitter, once a frame: the indirect draw of what is alive, and
// for an emitter that sorts, its list back to front (a ribbon: youngest
// first, the order it was laid along its path).
#define PARTICLES_WRITABLE
#define PARTICLES_COUNTED
#include "particles.slang"
#define MIRAI_GROUP_X 512
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

struct Params_Block { uint mode; uint emitters; uint count; uint parity; uint step; uint last; uint pad0; uint pad1; };
[[vk::binding(SLOT_PARAMS, 0)]] ConstantBuffer<Params_Block> params : register(MIRAI_REGISTER(b, SLOT_PARAMS), space0);
// The counters "particles" (render.pass_counters): those alive and the emitters that have some.
[[vk::binding(SLOT_PASS9, 0)]] RWStructuredBuffer<uint> counted : register(MIRAI_REGISTER(u, SLOT_PASS9), space0);

groupshared float keys[PARTICLE_SORT_MAX];
groupshared uint values[PARTICLE_SORT_MAX];

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID) {
    uint slot = group.x;
    uint t = local.x;
    Particle_Emitter e = particle_emitters[slot];
    bool active = (e.range.w & PARTICLE_FLAG_ACTIVE) != 0u;
    uint alive = active ? min(particle_states[slot].alive, e.range.y) : 0u;
    bool ribbon = e.kinds.y == PARTICLE_RENDER_RIBBON;
    if (t == 0u) {
        bool mesh = e.kinds.y == PARTICLE_RENDER_MESH;
        particle_states[slot].index_count = mesh ? e.mesh.x : 6u;
        particle_states[slot].instance_count = ribbon ? max(alive, 1u) - 1u : alive;
        particle_states[slot].first_index = 0u;
        particle_states[slot].vertex_offset = 0;
        particle_states[slot].first_instance = 0u;
        if (alive > 0u) {
            InterlockedAdd(counted[0], alive);
            InterlockedAdd(counted[1], 1u);
        }
    }
    if ((e.range.w & PARTICLE_FLAG_SORT) == 0u || alive < 2u) return;
    uint n = min(alive, PARTICLE_SORT_MAX);
    uint size = 2u;
    while (size < n) size <<= 1u;
    uint drawn = e.program.y + e.range.x;
    for (uint i = t; i < size; i += MIRAI_GROUP_X) {
        if (i < n) {
            uint index = particle_lists[drawn + i];
            Particle p = particles[index];
            float3 world = particle_world(slot, p.position);
            keys[i] = ribbon ? p.age : -dot(world - frame.camera_position.xyz, frame.camera_forward.xyz);
            values[i] = index;
        } else {
            keys[i] = FLT_MAX;
            values[i] = 0u;
        }
    }
    GroupMemoryBarrierWithGroupSync();
    for (uint k = 2u; k <= size; k <<= 1u) {
        for (uint j = k >> 1u; j > 0u; j >>= 1u) {
            for (uint i = t; i < size; i += MIRAI_GROUP_X) {
                uint other = i ^ j;
                if (other > i) {
                    bool ascending = (i & k) == 0u;
                    if ((keys[i] > keys[other]) == ascending) {
                        float key = keys[i]; keys[i] = keys[other]; keys[other] = key;
                        uint value = values[i]; values[i] = values[other]; values[other] = value;
                    }
                }
            }
            GroupMemoryBarrierWithGroupSync();
        }
    }
    for (uint i = t; i < n; i += MIRAI_GROUP_X) particle_lists[drawn + i] = values[i];
}
