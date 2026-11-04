package mirai_render

import "core:testing"
import "mirai:asset"
import mm "mirai:std/math"

// A deformable that keeps the levels of its source poses every vertex of
// its clusters three times (current, previous and rest) after its own copy of
// them; one without them poses those of level 0 alone and stays there.
@(test)
a_deformable_with_levels_keeps_the_levels_of_its_source_in_its_own_vertices :: proc(t: ^testing.T) {
	r:=new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	SIDE :: 33
	vertices := make([]asset.Vertex, SIDE * SIDE, context.temp_allocator)
	for &v, i in vertices {
		x, z := f32(i % SIDE), f32(i / SIDE)
		v = {position = {x, 0.3 * f32((i * 7) % 5), z}, normal = mm.normal_pack({0, 1, 0}), color = 0xffffffff, tangent = mm.tangent_pack({1, 0, 0}, 1), uv = {x / SIDE, z / SIDE}}
	}
	indices := make([dynamic]u32, context.temp_allocator)
	for z in 0 ..< SIDE - 1 {
		for x in 0 ..< SIDE - 1 {
			a := u32(z * SIDE + x)
			append(&indices, a, a + SIDE, a + 1, a + 1, a + SIDE, a + SIDE + 1)
		}
	}
	whole := len(indices)
	for q := 0; q < whole / 6; q += 2 {append(&indices, ..indices[q * 6:][:6])}
	levels := [2]asset.Level_Source{{0, u32(whole), 0}, {u32(whole), u32(len(indices) - whole), 0.1}}
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build({vertices = vertices}, indices[:], levels[:], &g, context.temp_allocator)) {return}
	source, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	original := r.scene.meshes[source]
	testing.expect_value(t, original.level_count, 2)
	with, made := deformable_create(r, source, true)
	if !testing.expect(t, made) {return}
	mesh := r.scene.meshes[with]
	count := original.vertex_count
	testing.expect_value(t, mesh.level_count, original.level_count)
	testing.expect(t, mesh.flags & MESH_FLAG_LEVEL0 == 0 && mesh.vertices_posed == count)
	testing.expect_value(t, mesh.vertex_span, original.vertex_span + 3 * count * POSED_WORDS)
	testing.expect_value(t, mesh.index_span, original.index_span)
	written, rest, posed, row, known := deformable_vertices(r, with)
	testing.expect_value(t, row, u32(with))
	testing.expect(t, known && posed == count && written == mesh.posed_word && rest == written + 2 * count * POSED_WORDS)
	testing.expect_value(t, gpu_mesh(mesh).previous_word, written + count * POSED_WORDS)
	without, _ := deformable_create(r, source)
	plain := r.scene.meshes[without]
	level0, _ := level0_vertices(&r.scene, original)
	testing.expect(t, plain.flags & MESH_FLAG_LEVEL0 != 0 && plain.vertices_posed == level0 && level0 < count)
	testing.expect(t, mesh_remove(r, with) && mesh_remove(r, without))
}
