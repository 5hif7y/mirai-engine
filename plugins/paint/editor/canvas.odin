package paint_editor

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// A mesh held in memory to be painted: level 0 of its file decoded, with
// what goes with its vertices and everything else the file has, so the
// painted copy differs from its source in the colors of its vertices. It is
// saved again as one level (asset.mesh_build): the coarser levels of the
// source are not kept until the meshes made at run time take them.
Canvas :: struct {
    allocator:runtime.Allocator,
    vertices:[]asset.Vertex,
    indices:[]u32,
    skin:[]asset.Skin_Vertex,
    morphs:[]asset.Morph_Target,
    morph_deltas:[]asset.Morph_Delta, // by vertex of the canvas
    slots:[]asset.Material_Slot,
    skeleton:base.Asset_Id,
    joints:[]asset.Rig_Joint,
    colliders:[]asset.Collider,
    collision_points:[][3]f32,
    collision_indices:[]u32,
    flags:asset.Mesh_Flags,
}

canvas_destroy :: proc(c:^Canvas) {
    a:=c.allocator
    delete(c.vertices,a);delete(c.indices,a);delete(c.skin,a);delete(c.morphs,a);delete(c.morph_deltas,a);delete(c.slots,a)
    delete(c.joints,a);delete(c.colliders,a);delete(c.collision_points,a);delete(c.collision_indices,a)
    c^={}
}

// Reads a mesh asset whole, as the registry of the assets holds it: what its
// memory keeps unsaved, or the file. False, with the canvas empty, when it is
// not a mesh that can be drawn.
canvas_load :: proc(c:^Canvas,a:^host.Assets,id:base.Asset_Id,allocator:=context.allocator) -> bool {
    file:asset.Asset
    if host.assets_file(a,id,asset.KIND_MESH,&file)!=.None {return false}
    defer asset.asset_close(&file)
    view,error:=asset.mesh_view(&file,&a.types)
    if error!=.None || !asset.mesh_check_indices(view) {return false}
    vertices:=make([dynamic]asset.Vertex,allocator)
    indices:=make([dynamic]u32,allocator)
    skin:=make([dynamic]asset.Skin_Vertex,allocator)
    deltas:=make([dynamic]asset.Morph_Delta,allocator)
    morphs:=slice.clone(view.morphs,allocator)
    // The vertex of the canvas of each vertex of the mesh, or -1.
    canvas_vertex:=make([]i32,len(view.vertices),context.temp_allocator)
    for &at in canvas_vertex {at=-1}
    level:=view.levels[0]
    for cluster in view.clusters[level.first_cluster:][:level.cluster_count] {
        first:=u32(len(vertices))
        for local in 0..<asset.cluster_vertex_count(cluster) {
            canvas_vertex[cluster.vertex_first+local]=i32(len(vertices))
            append(&vertices,asset.cluster_vertex(view.geometry,cluster,local))
            if len(view.skin)>0 {append(&skin,view.skin[cluster.vertex_first+local])}
        }
        for t in 0..<asset.cluster_triangle_count(cluster) {
            corners:=asset.cluster_triangle(view.triangles,cluster,t)
            append(&indices,first+corners[0],first+corners[1],first+corners[2])
        }
    }
    for &target in morphs {
        first:=u32(len(deltas))
        for delta in view.morph_deltas[target.first:][:target.count] {
            if at:=canvas_vertex[delta.vertex];at>=0 {
                moved:=asset.morph_decode(delta,view.morph_step)
                moved.vertex=u32(at)
                append(&deltas,moved)
            }
        }
        target.first,target.count=first,u32(len(deltas))-first
    }
    c^={
        allocator=allocator,flags=view.info.flags,vertices=vertices[:],indices=indices[:],skin=skin[:],morphs=morphs,morph_deltas=deltas[:],
        slots=slice.clone(view.slots,allocator),skeleton=view.info.skeleton,joints=slice.clone(view.joints,allocator),colliders=slice.clone(view.colliders,allocator),
        collision_points=slice.clone(view.collision_points,allocator),collision_indices=slice.clone(view.collision_indices,allocator),
    }
    return true
}

// The mesh of a primitive, white, as the engine generates it. False for None.
canvas_shape :: proc(c:^Canvas,shape:host.Shape,allocator:=context.allocator) -> bool {
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer,allocator)
    defer geom.mesh_buffer_destroy(&buffer)
    switch shape {
    case .None:     return false
    case .Cube:     geom.cube_build(&buffer)
    case .Sphere:   geom.sphere_build(&buffer)
    case .Cylinder: geom.cylinder_build(&buffer)
    case .Cone:     geom.cone_build(&buffer)
    case .Capsule:  geom.capsule_build(&buffer)
    case .Plane:    geom.plane_build(&buffer)
    case .Prism:    geom.prism_build(&buffer)
    case .Pyramid:  geom.pyramid_build(&buffer)
    }
    if len(buffer.indices)==0 {return false}
    c^={allocator=allocator,indices=slice.clone(buffer.indices[:],allocator)}
    vertices:=make([dynamic]asset.Vertex,len(buffer.positions),allocator)
    for position,at in buffer.positions {
        vertices[at]={position=position,normal=mm.normal_pack(buffer.normals[at]),uv=buffer.uvs[at],uv1=buffer.uvs[at],color=0xffffffff}
    }
    if !asset.mesh_tangents(&vertices,c.indices) {
        delete(vertices)
        return false
    }
    c.vertices=vertices[:]
    return true
}

// The canvas as the file of a mesh asset of its own, with the colors it has
// now: bytes from allocator. Scratch from the temporary allocator.
canvas_bytes :: proc(c:^Canvas,id:base.Asset_Id,types:^asset.Types,allocator:=context.allocator) -> (data:[]u8,error:asset.Error) {
    source:=asset.Mesh_Source{vertices=c.vertices,skin=c.skin,morphs=c.morphs,morph_deltas=c.morph_deltas,flags=c.flags&{.Has_Uv1}+{.Has_Colors}}
    desc:=asset.Mesh_Desc{
        id=id,slots=c.slots,skeleton=c.skeleton,joints=c.joints,
        colliders=c.colliders,collision_points=c.collision_points,collision_indices=c.collision_indices,
    }
    if !asset.mesh_build(source,c.indices,nil,&desc.geometry,context.temp_allocator) {return nil,.Invalid}
    document:asset.Document
    asset.mesh_document(&document,types,desc,c.allocator) or_return
    defer asset.document_destroy(&document)
    return asset.document_bytes(&document,allocator)
}

// How much of the brush a point takes at a distance from its center, as a fraction of its radius: all of it at the center, none at the edge.
falloff :: proc "contextless" (t:f32) -> f32 {
    if t>=1 {return 0}
    return 1-t*t*(3-2*t)
}

// One stamp of the brush: raises the weight of every position within radius
// of center to the falloff there. A stroke keeps the most of its stamps, so
// going twice over a place within a stroke paints it once.
stamp :: proc(positions:[][3]f32,weights:[]f32,center:[3]f32,radius:f32) -> (changed:bool) {
    if radius<=0 {return false}
    limit:=radius*radius
    for position,at in positions {
        offset:=position-center
        squared:=linalg.dot(offset,offset)
        if squared>=limit {continue}
        weight:=falloff(math.sqrt(squared)/radius)
        if weight>weights[at] {
            weights[at]=weight
            changed=true
        }
    }
    return
}

// The stamps between two points of a stroke, spaced a quarter of the radius, the second point included.
stamp_segment :: proc(positions:[][3]f32,weights:[]f32,from,to:[3]f32,radius:f32) -> (changed:bool) {
    steps:=max(int(math.ceil(linalg.distance(from,to)/max(radius*0.25,1e-4))),1)
    for step in 1..=steps {
        if stamp(positions,weights,linalg.lerp(from,to,f32(step)/f32(steps)),radius) {changed=true}
    }
    return
}

// The colors of a stroke: each vertex goes from the color it had toward the
// color of the brush by strength times its weight. Alpha is kept.
colors_blend :: proc(vertices:[]asset.Vertex,before:[]u32,weights:[]f32,color:[3]f32,strength:f32) {
    target:=[3]f32{clamp(color.r,0,1),clamp(color.g,0,1),clamp(color.b,0,1)}*255
    for &vertex,at in vertices {
        amount:=clamp(strength*weights[at],0,1)
        packed:=before[at]
        if amount>0 {
            mixed:=packed&0xff000000
            for channel in 0..<3 {
                shift:=u32(channel)*8
                old:=f32((packed>>shift)&0xff)
                mixed|=u32(math.round(old+(target[channel]-old)*amount))<<shift
            }
            packed=mixed
        }
        vertex.color=packed
    }
}
