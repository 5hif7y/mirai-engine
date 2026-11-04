package mirai_render

import "core:math/linalg"
import "core:math/rand"
import "core:testing"

@(test)
bvh_matches_brute_force :: proc(t: ^testing.T) {
	rng := rand.create(42)
	context.random_generator = rand.default_random_generator(&rng)
	COUNT :: 400
	items := make([]Bvh_Item, COUNT)
	defer delete(items)
	tris := make([][3]Vec3, COUNT)
	defer delete(tris)
	for i in 0 ..< COUNT {
		c := Vec3{rand.float32_range(-10, 10), rand.float32_range(-10, 10), rand.float32_range(-10, 10)}
		for k in 0 ..< 3 {tris[i][k] = c + Vec3{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)}}
		a, b, cc := tris[i][0], tris[i][1], tris[i][2]
		items[i] = {bounds_min = linalg.min(linalg.min(a, b), cc), bounds_max = linalg.max(linalg.max(a, b), cc), center = (a + b + cc) / 3}
	}
	nodes: [dynamic]Gpu_Bvh_Node
	order: [dynamic]u32
	defer delete(nodes)
	defer delete(order)
	testing.expect(t, bvh_build(items, 4, &nodes, &order))
	triangles := make([]Gpu_Bvh_Triangle, COUNT)
	defer delete(triangles)
	for primitive, i in order {
		a, b, c := tris[primitive][0], tris[primitive][1], tris[primitive][2]
		triangles[i] = {v0 = a, primitive = primitive, e1 = {b.x - a.x, b.y - a.y, b.z - a.z, 0}, e2 = {c.x - a.x, c.y - a.y, c.z - a.z, 0}}
	}
	// Depth bound required by the GPU traversal stack.
	max_depth := 0
	Entry :: struct {node, depth: int}
	stack := make([dynamic]Entry, 0, 64)
	append(&stack, Entry{0, 0})
	defer delete(stack)
	for len(stack) > 0 {
		e := pop(&stack)
		max_depth = max(max_depth, e.depth)
		n := nodes[e.node]
		if n.count == 0 {append(&stack, Entry{int(n.left_first), e.depth + 1}, Entry{int(n.left_first) + 1, e.depth + 1})}
	}
	testing.expect(t, max_depth <= BVH_MAX_DEPTH)
	mismatches := 0
	for _ in 0 ..< 2000 {
		origin := Vec3{rand.float32_range(-15, 15), rand.float32_range(-15, 15), rand.float32_range(-15, 15)}
		dir := linalg.normalize(Vec3{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)})
		bt, bp := bvh_ray_triangles(nodes[:], triangles, origin, dir, 1e9)
		// Brute force reference over the original triangle list.
		best := f32(1e9)
		best_p := -1
		for tri, i in tris {
			one := []Gpu_Bvh_Triangle{{v0 = tri[0], primitive = u32(i), e1 = {tri[1].x - tri[0].x, tri[1].y - tri[0].y, tri[1].z - tri[0].z, 0}, e2 = {tri[2].x - tri[0].x, tri[2].y - tri[0].y, tri[2].z - tri[0].z, 0}}}
			leaf := []Gpu_Bvh_Node{{bounds_min = {-1e9, -1e9, -1e9}, bounds_max = {1e9, 1e9, 1e9}, count = 1}}
			ht, hp := bvh_ray_triangles(leaf, one, origin, dir, best)
			if hp >= 0 {best, best_p = ht, hp}
		}
		if bp != best_p || (bp >= 0 && abs(bt - best) > 1e-3) {mismatches += 1}
	}
	testing.expect_value(t, mismatches, 0)
}
