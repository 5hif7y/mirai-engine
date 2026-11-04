package asset

// The morph targets of a mesh: shapes its vertices blend toward by weight.
//
//   morphs         Morph_Target: a range of morph_deltas each
//   morph_deltas   bulk   Morph_Delta, by vertex inside each target
//
// A target moves the vertices its deltas name, of any level; the others stay.
// A mesh without them has neither table.

MESH_MAX_MORPHS :: 256
// Weights an entity sets by name over those of its mesh (Morph_Weights of
// the animation plugin): overrides and a node's own rest weights. Animation
// curves drive the others without one.
MORPH_WEIGHTS :: 16

Morph_Target :: struct {
    name:[64]u8 `mirai:"text"`,
    weight:f32,      // without animation or override
    first,count:u32, // rows of morph_deltas
}

// What a target at weight 1 adds to a vertex, in the space of the mesh: to
// its position, and to its normal and its tangent before they are made unit
// length again.
Morph_Delta :: struct {
    vertex:u32,
    position:[3]f32 `mirai:"unit=m"`,
    normal,tangent:[3]f32,
}

// The targets of mesh_check: named once each, with finite weights and
// consecutive ranges that cover the deltas.
@(private)
mesh_morph_check :: proc(view:Mesh_View) -> bool {
    if len(view.morphs)>MESH_MAX_MORPHS {return false}
    used:u64
    for &target,i in view.morphs {
        if target.name[0]==0 || !text_valid(target.name[:]) || !finite(target.weight) || u64(target.first)!=used {return false}
        for other in view.morphs[:i] {if other.name==target.name {return false}}
        used+=u64(target.count)
    }
    return used==u64(len(view.morph_deltas))
}

// The deltas of mesh_check_indices: each names a vertex, after the one before
// it in its target, and moves it by finite amounts.
@(private)
mesh_morph_check_deltas :: proc(view:Mesh_View) -> bool {
    for target in view.morphs {
        for delta,d in view.morph_deltas[target.first:][:target.count] {
            if int(delta.vertex)>=len(view.vertices) || d>0 && delta.vertex<=view.morph_deltas[int(target.first)+d-1].vertex {return false}
            if !finite(delta.position.x,delta.position.y,delta.position.z,delta.normal.x,delta.normal.y,delta.normal.z,delta.tangent.x,delta.tangent.y,delta.tangent.z) {return false}
        }
    }
    return true
}
