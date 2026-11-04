package mirai_physics

import "core:testing"
import "core:fmt"

@(test)
box_topology_table_matches_the_builder :: proc(t:^testing.T) {
    counts:=BOX_FACE_COUNTS
    indices:=BOX_FACE_INDICES
    edges:[24]Half_Edge
    face_edges:[6]u16
    testing.expect(t,hull_topology_build(8,counts[:],indices[:],edges[:],face_edges[:]))
    if edges!=BOX_EDGES || face_edges!=BOX_FACE_EDGES {
        fmt.println("BOX",edges,face_edges)
        testing.fail(t)
    }
    tri_counts:=[2]u8{3,3}
    tri_indices:=[6]u8{0,1,2, 0,2,1}
    tri_edges:[6]Half_Edge
    tri_face_edges:[2]u16
    testing.expect(t,hull_topology_build(3,tri_counts[:],tri_indices[:],tri_edges[:],tri_face_edges[:]))
    if tri_edges!=TRIANGLE_EDGES || tri_face_edges!=TRIANGLE_FACE_EDGES {
        fmt.println("TRI",tri_edges,tri_face_edges)
        testing.fail(t)
    }
}
