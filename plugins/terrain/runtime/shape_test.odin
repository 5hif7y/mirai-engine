package terrain

import "core:testing"
import "mirai:std/geom"

@(test)
a_wide_smooth_reaches_past_the_samples_next_to_it :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{33,1,33},1,16));defer source_destroy(&source)
    testing.expect(t,source_edit(&source,{kind=.Raise,center={},radius=0.4,amount=1}).changed)
    narrow:=source_value(&source,{16,0,16})
    testing.expect(t,source_edit(&source,{kind=.Smooth,center={},radius=2,amount=1}).changed)
    testing.expect_value(t,source_value(&source,{18,0,16}),f32(0))
    testing.expect(t,source_value(&source,{16,0,16})<narrow)
    testing.expect(t,source_edit(&source,{kind=.Raise,center={},radius=0.4,amount=1}).changed)
    testing.expect(t,source_edit(&source,{kind=.Smooth,center={},radius=12,amount=1,falloff=.Constant}).changed)
    testing.expect(t,source_value(&source,{19,0,16})>0,"a radius of 12 cells averages 3 samples to each side")
}

@(test)
a_ramp_reaches_the_heights_of_its_ends_along_its_line :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Heightfield,{33,1,33},1,16));defer source_destroy(&source)
    // From A at sample (8,16), 2 high, to B at (24,16), 10 high.
    a:=source_point(&source,{8,0,16})+{0,2,0}
    change:=source_edit(&source,{kind=.Ramp,center=a,delta={16,8,0},radius=3,hardness=0.5,amount=1})
    testing.expect(t,change.changed)
    testing.expect_value(t,source_value(&source,{8,0,16}),f32(2))
    testing.expect_value(t,source_value(&source,{16,0,16}),f32(6))
    testing.expect_value(t,source_value(&source,{24,0,16}),f32(10))
    testing.expect_value(t,source_value(&source,{16,0,25}),f32(0))
    testing.expect(t,source_value(&source,{16,0,17})==6,"inside the hard part of its width")
    testing.expect(t,source_value(&source,{16,0,18})>0 && source_value(&source,{16,0,18})<6,"the sides fall off")
    testing.expect_value(t,source_edit(&source,{kind=.Ramp,center=a,delta={16,8,0},radius=3,amount=1}).error,Edit_Error.None)
    volume:Source;testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,8));defer source_destroy(&volume)
    testing.expect_value(t,source_edit(&volume,{kind=.Ramp,center={},delta={2,1,0},radius=1,amount=1}).error,Edit_Error.Invalid)
}

@(test)
volume_shapes_join_and_carve_and_a_blend_softens_the_join :: proc(t:^testing.T) {
    source:Source;testing.expect(t,source_make(&source,.Volume,{33,33,33},1,16));defer source_destroy(&source)
    air:=source.cell*SDF_BAND_CELLS
    for &page in source.distances.pages {page_free(page);page.values=nil;page.fill=air}
    capsule:=Brush{kind=.Union,shape=.Capsule,center=source_point(&source,{8,16,16}),delta={16,0,0},radius=3,amount=1}
    testing.expect(t,source_edit(&source,capsule).changed)
    testing.expect(t,source_value(&source,{16,16,16})<0,"the middle of the capsule is solid")
    testing.expect(t,source_value(&source,{8,16,16})<0 && source_value(&source,{24,16,16})<0)
    testing.expect(t,source_value(&source,{16,21,16})>0,"two cells past its radius is air")
    box:=Brush{kind=.Subtract,shape=.Box,center=source_point(&source,{16,16,16}),extent={2,2,2},rotation=1,amount=1}
    testing.expect(t,source_edit(&source,box).changed)
    testing.expect(t,source_value(&source,{16,16,16})>0,"the box takes the middle away")
    testing.expect(t,source_value(&source,{9,16,16})<0,"and leaves the rest of the capsule")
    hard,soft:=source_value(&source,{16,22,16}),f32(0)
    sphere:=Brush{kind=.Union,shape=.Sphere,center=source_point(&source,{16,26,16}),radius=3,amount=1,blend=4}
    testing.expect(t,source_edit(&source,sphere).changed)
    soft=source_value(&source,{16,22,16})
    testing.expect(t,soft<min(hard,1),"between two solids a blend fills more than their union")
    testing.expect_value(t,source_edit(&source,{kind=.Union,shape=.Box,center={},extent={0,1,1},amount=1}).error,Edit_Error.Invalid)
    testing.expect(t,smooth_min(1,1,2)<1 && smooth_min(1,5,2)==1 && smooth_min(1,3,0)==1)
}

@(test)
mesh_shapes_join_a_closed_solid_and_keep_it_closed :: proc(t:^testing.T) {
    height,source:Source
    defer source_destroy(&height);defer source_destroy(&source)
    testing.expect(t,source_make(&height,.Heightfield,{9,1,9},1,4))
    testing.expect(t,source_convert_heightfield(&source,&height,6))
    merged:geom.Mesh_Buffer;geom.mesh_buffer_init(&merged);defer geom.mesh_buffer_destroy(&merged)
    testing.expect(t,source_mesh_collect(&source,&merged))
    before:=geom.mesh_volume(merged.positions[:],merged.indices[:])
    for brush in ([2]Brush{{kind=.Union,shape=.Capsule,center={-2,0,0},delta={4,0,0},radius=1,amount=1},{kind=.Subtract,shape=.Box,center={2.3,0.1,-2.4},extent={1,1,1},rotation=1,amount=1}}) {
        change:=source_edit(&source,brush)
        testing.expect_value(t,change.error,Edit_Error.None)
        testing.expect(t,change.changed)
    }
    geom.mesh_buffer_clear(&merged)
    testing.expect(t,source_mesh_collect(&source,&merged))
    testing.expect(t,geom.mesh_is_closed(merged.positions[:],merged.indices[:]))
    after:=geom.mesh_volume(merged.positions[:],merged.indices[:])
    // Half the capsule rises over the top; the box takes what it has under it, 3.6 cubic units.
    testing.expect(t,abs(after-(before+(4*1*1*3.14159265+4.0/3*3.14159265)*0.5-3.6))<0.6,"the volume grows by half the capsule and loses half the box")
}

@(test)
falloffs_go_from_one_to_zero_and_hardness_keeps_the_middle_full :: proc(t:^testing.T) {
    for falloff in geom.Falloff {
        testing.expect_value(t,geom.falloff_weight(falloff,0,0),f32(1))
        testing.expect_value(t,geom.falloff_weight(falloff,0,1),f32(0))
        testing.expect_value(t,geom.falloff_weight(falloff,0.5,0.4),f32(1))
        if falloff!=.Constant {testing.expect(t,geom.falloff_weight(falloff,0,0.5)<1)}
    }
    testing.expect(t,geom.falloff_weight(.Sharp,0,0.5)<geom.falloff_weight(.Linear,0,0.5))
    testing.expect(t,geom.falloff_weight(.Sphere,0,0.5)>geom.falloff_weight(.Smooth,0,0.5))
}
