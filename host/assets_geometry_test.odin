package host

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

@(test)
geometry_primitives_append_complete_white_attributes_and_relative_indices :: proc(t:^testing.T) {
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    for shape in ([8]Shape{.Cube,.Sphere,.Cylinder,.Cone,.Capsule,.Plane,.Prism,.Pyramid}) {
        first,indices:=len(buffer.positions),len(buffer.indices)
        testing.expect(t,assets_geometry(nil,{},shape,&buffer,true))
        testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
        testing.expect(t,len(buffer.positions)>first && len(buffer.indices)>indices)
        for index in buffer.indices[indices:] {testing.expect(t,index>=u32(first) && int(index)<len(buffer.positions))}
        for color in buffer.colors[first:] {testing.expect_value(t,color,geom.Vec4{1,1,1,1})}
    }
}

@(test)
geometry_generated_colors_are_owned_and_missing_colors_are_white :: proc(t:^testing.T) {
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root="assets",capacity=4})) {return}
    defer assets_destroy(&assets)
    colors:=[3]geom.Vec4{{0.1,0.2,0.3,0.4},{0.2,0.4,0.6,0.8},{1,0,0.5,1}}
    original:=colors
    source:=geom.Mesh{positions={{0,0,0},{1,0,0},{0,0,1}},indices={0,2,1},colors=colors[:]}
    id,created:=assets_mesh_generate(&assets,source,options={collision=true})
    if !testing.expect(t,created) {return}
    colors[0]={9,9,9,9}
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    testing.expect(t,assets_geometry(&assets,id,.None,&buffer,true))
    testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
    for color,i in buffer.colors {testing.expect_value(t,color,original[i])}
    testing.expect(t,assets_mesh_release(&assets,id))
    source.colors=nil
    id,created=assets_mesh_generate(&assets,source,options={collision=true})
    testing.expect(t,created && assets_geometry(&assets,id,.None,&buffer,true))
    for color in buffer.colors[3:] {testing.expect_value(t,color,geom.Vec4{1,1,1,1})}
    source.colors=colors[:2]
    _,created=assets_mesh_generate(&assets,source,options={collision=true})
    testing.expect(t,!created)
}

@(test)
geometry_file_preserves_packed_colors_normals_uvs_materials_and_slots :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-host-geometry-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/colored.mesh",root)
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove(root)
    defer os.remove(path)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{
        {position={0,0,0},normal=mm.normal_pack({0,1,0}),uv={0.1,0.2},uv1={0.7,0.8},color=0x80604020},
        {position={1,0,0},normal=mm.normal_pack({0,1,0}),uv={0.3,0.4},uv1={0.2,0.3},color=0xffffffff},
        {position={0,0,1},normal=mm.normal_pack({0,1,0}),uv={0.5,0.6},uv1={0.4,0.5},color=0xff0000ff},
    }
    id:=base.Asset_Id{0x63706f6c6f7273,1}
    slot:=[1]asset.Material_Slot{{id=1,material={5,5}}}
    order:=[3]u32{0,2,1}
    testing.expect_value(t,mesh_save_test(path,&types,id,vertices[:],order[:],slot[:],{.Has_Colors,.Has_Uv1}),asset.Error.None)
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=4})) {return}
    defer assets_destroy(&assets)
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    slots:Assets_Slots
    testing.expect(t,assets_geometry(&assets,id,.None,&buffer,true,&slots))
    testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
    testing.expect_value(t,len(buffer.positions),3)
    // The slots come from the file, which is not loaded for them.
    testing.expect(t,slots.count==1 && slots.materials[0]==base.Asset_Id{5,5})
    testing.expect(t,!(id in assets.index))
    // The corners of the triangle name the vertices it was given with, on the grids of the mesh.
    for source,corner in order {
        vertex,at:=vertices[source],buffer.indices[corner]
        testing.expect_value(t,buffer.positions[at],vertex.position)
        testing.expect_value(t,buffer.normals[at],mm.normal_unpack(vertex.normal))
        testing.expect(t,linalg.length(buffer.uvs[at]-vertex.uv)<1e-4)
        testing.expect_value(t,buffer.colors[at],mm.rgba8_unpack(vertex.color))
    }
    testing.expect_value(t,buffer.materials[0],u32(0))
}

@(test)
geometry_reservation_failure_preserves_existing_values_and_lengths :: proc(t:^testing.T) {
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    append(&buffer.positions,geom.Vec3{9,8,7});append(&buffer.normals,geom.Vec3{1,0,0});append(&buffer.uvs,geom.Vec2{0.4,0.6})
    saved_allocator:=buffer.colors.allocator
    buffer.colors.allocator=runtime.nil_allocator()
    testing.expect(t,!assets_geometry(nil,{},.Cube,&buffer,true))
    buffer.colors.allocator=saved_allocator
    testing.expect_value(t,len(buffer.positions),1);testing.expect_value(t,len(buffer.normals),1)
    testing.expect_value(t,len(buffer.uvs),1);testing.expect_value(t,len(buffer.colors),0)
    testing.expect_value(t,len(buffer.indices),0);testing.expect_value(t,len(buffer.materials),0)
    testing.expect_value(t,buffer.positions[0],geom.Vec3{9,8,7});testing.expect_value(t,buffer.uvs[0],geom.Vec2{0.4,0.6})
    testing.expect(t,assets_geometry(nil,{},.Cube,&buffer,true))
    testing.expect_value(t,buffer.colors[0],geom.Vec4{1,1,1,1})
    testing.expect(t,geom.mesh_is_valid(geom.mesh_buffer_view(&buffer)))
    testing.expect(t,!assets_geometry(nil,{},.None,&buffer,true))
    testing.expect(t,!assets_geometry(nil,{},.Cube,nil,true))
    geom.mesh_buffer_clear(&buffer)
    buffer.positions.allocator=runtime.nil_allocator()
    buffer.indices.allocator=runtime.nil_allocator()
    // Previously reserved geometry remains usable with a refusing allocator.
    testing.expect(t,assets_geometry(nil,{},.Cube,&buffer))
    buffer.positions.allocator=saved_allocator;buffer.indices.allocator=saved_allocator
    empty:geom.Mesh_Buffer;geom.mesh_buffer_init(&empty,runtime.nil_allocator());defer geom.mesh_buffer_destroy(&empty)
    testing.expect(t,!assets_geometry(nil,{},.Cube,&empty))
    testing.expect_value(t,len(empty.positions),0);testing.expect_value(t,len(empty.indices),0)
}

// The boxes, spheres and capsules a mesh stores are hulls of a collider of the mesh, where they lie.
@(test)
stored_boxes_spheres_and_capsules_are_the_hulls_of_a_collider_of_their_mesh :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-host-shapes-%d",directory,os.get_pid())
    path:=fmt.tprintf("%s/shapes.mesh",root)
    testing.expect_value(t,os.make_directory_all(root),nil)
    defer os.remove_all(root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    vertices:=[3]asset.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,0,1}}}
    order:=[3]u32{0,2,1}
    g:asset.Mesh_Geometry
    if !testing.expect(t,asset.mesh_build({vertices=vertices[:]},order[:],nil,&g,context.temp_allocator)) {return}
    colliders:=[3]asset.Collider{
        {kind=.Box,center={10,0,0},rotation=1,size={1,2,3}},
        {kind=.Sphere,center={0,10,0},rotation=1,size={0.5,0,0}},
        {kind=.Capsule,center={0,0,10},rotation=1,size={0.25,1,0}},
    }
    id:=base.Asset_Id{0x7368617065,2}
    testing.expect_value(t,asset.mesh_save(path,&types,{id=id,geometry=g,colliders=colliders[:]}),asset.Error.None)
    assets:Assets
    if !testing.expect(t,assets_init(&assets,{root=root,capacity=4})) {return}
    defer assets_destroy(&assets)
    hull:geom.Mesh_Buffer;geom.mesh_buffer_init(&hull);defer geom.mesh_buffer_destroy(&hull)
    stored,ok:=assets_collision(&assets,id,.None,.Hull,&hull)
    if !testing.expect(t,stored && ok,"the stored shapes are the geometry of a hull") {return}
    low,high:=geom.Vec3{max(f32),max(f32),max(f32)},geom.Vec3{min(f32),min(f32),min(f32)}
    for p in hull.positions {low,high=linalg.min(low,p),linalg.max(high,p)}
    testing.expectf(t,linalg.length(low-{-0.5,-2,-3})<1e-4,"lowest point of the shapes: %v",low)
    testing.expectf(t,linalg.length(high-{11,10.5,10.25})<1e-4,"highest point of the shapes: %v",high)
    surface:geom.Mesh_Buffer;geom.mesh_buffer_init(&surface);defer geom.mesh_buffer_destroy(&surface)
    stored,ok=assets_collision(&assets,id,.None,.Mesh,&surface)
    testing.expect(t,stored && ok && len(surface.indices)>=3*3*4,"each shape is a hull of triangles")
}
