package terrain

import "core:testing"

@(test)
a_dug_volume_becomes_a_mesh_of_its_surface_with_its_layers_and_no_field :: proc(t:^testing.T) {
    source:Source
    defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Volume,{33,17,33},1,8))
    testing.expect(t,source_edit(&source,{kind=.Remove,center={0,0,0},radius=4,amount=1}).changed)
    testing.expect(t,source_layer_set(&source,0,{tiling=4}) && source_layer_set(&source,1,{tiling=4}))
    testing.expect(t,source_edit(&source,{kind=.Paint,layer=1,center={6,0,6},radius=3,amount=1}).changed)
    through,_,hit:=source_ray(&source,{0,20,0},{0,-1,0})
    testing.expect(t,hit)
    beside,_,hit_beside:=source_ray(&source,{10,20,10},{0,-1,0})
    testing.expect(t,hit_beside)
    revision:=source.revision
    testing.expect(t,source_convert_volume(&source,&source))
    testing.expect_value(t,source.kind,Source_Kind.Mesh)
    testing.expect_value(t,len(source.distances.pages),0)
    testing.expect_value(t,source.revision,revision)
    testing.expect_value(t,source.layer_count,u32(2))
    triangles:=0
    for &chunk in source.mesh_chunks {triangles+=len(chunk.geometry.indices)/3}
    testing.expect(t,triangles>0)
    // The same surface: the bottom of the pit and the top beside it.
    point,_,found:=source_ray(&source,{0,20,0},{0,-1,0})
    testing.expect(t,found && abs(point.y-through.y)<0.05)
    point,_,found=source_ray(&source,{10,20,10},{0,-1,0})
    testing.expect(t,found && abs(point.y-beside.y)<0.05)
    // What was painted stays where it was.
    testing.expect(t,source_weights_at(&source,{6,0,6})[1]>0.5)
    testing.expect(t,source_weights_at(&source,{-10,0,-10})[1]<0.01)
    heights:Source
    defer source_destroy(&heights)
    testing.expect(t,source_make(&heights,.Heightfield,{9,1,9},1,4))
    testing.expect(t,!source_convert_volume(&heights,&heights),"only a Volume")
}
