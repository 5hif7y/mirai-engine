//! mirai vfx Crowd
//! stage count over particles neighbors 0.3
// A particle counts the particles of its emitter within 0.3 m of it: what
// the tests of the plugin check of neighbors.
namespace Crowd {
struct Parameters { float unused; };
struct Attributes { float near; };

void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void count(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {
    Mirai_Vfx_Neighbors walk = mirai_vfx_neighbors(ctx, particle.position);
    Mirai_Vfx_Neighbor neighbor;
    float near = 0.0;
    while (mirai_vfx_neighbor_next(walk, neighbor)) near += 1.0;
    a.near = near;
}

void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a) {}

void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual) {}
}
