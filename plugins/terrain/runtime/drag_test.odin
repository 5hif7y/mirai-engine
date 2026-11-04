package terrain

import "core:math/linalg"
import "core:testing"
import "mirai:std/geom"

@(test)
mesh_grab_keeps_initial_influence_across_chunks_and_can_return_to_its_origin :: proc(t:^testing.T) {
    height,source,baseline:Source
    defer source_destroy(&height);defer source_destroy(&source);defer source_destroy(&baseline)
    testing.expect(t,source_make(&height,.Heightfield,{17,1,17},1,4))
    testing.expect(t,source_convert_heightfield(&source,&height,4))
    testing.expect(t,source_clone(&baseline,&source,editable=false))
    original,actual:geom.Mesh_Buffer
    geom.mesh_buffer_init(&original);geom.mesh_buffer_init(&actual)
    defer geom.mesh_buffer_destroy(&original);defer geom.mesh_buffer_destroy(&actual)
    testing.expect(t,source_mesh_collect(&baseline,&original))
    for delta in ([4][3]f32{{6,3,0},{-5,4,3},{0,2,0},{0,0,0}}) {
        change:=source_edit(&source,{kind=.Grab,center={0,0,0},radius=2.5,amount=1,delta=delta},baseline=&baseline)
        if !testing.expect_value(t,change.error,Edit_Error.None) {return}
        testing.expect(t,source_mesh_collect(&source,&actual))
        testing.expect_value(t,len(actual.indices),len(original.indices))
        testing.expect(t,geom.mesh_is_closed(actual.positions[:],actual.indices[:]))
        for point in actual.positions {
            found:=false
            for p in original.positions {
                x:=max(1-linalg.length(p)/2.5,0)
                expected:=p+delta*(x*x*(3-2*x))
                if linalg.length(point-expected)<1e-5 {found=true;break}
            }
            if !testing.expect(t,found) {return}
        }
    }
    testing.expect_value(t,source_edit(&source,{kind=.Grab,radius=2,amount=1}).error,Edit_Error.Invalid)
}

@(test)
mesh_grow_follows_a_curved_tip_refines_locally_and_preserves_budget_atomicity :: proc(t:^testing.T) {
    height,source,before:Source
    defer source_destroy(&height);defer source_destroy(&source);defer source_destroy(&before)
    testing.expect(t,source_make(&height,.Heightfield,{17,1,17},1,4))
    testing.expect(t,source_convert_heightfield(&source,&height,4))
    testing.expect(t,source_clone(&before,&source,editable=false))
    brush:=Brush{kind=.Grow,center={-2,0,0},radius=1.5,amount=1,max_edge=0.5,delta={0,0.2,0}}
    testing.expect_value(t,source_edit(&source,brush,1).error,Edit_Error.Budget)
    for &chunk,i in source.mesh_chunks {testing.expect(t,mesh_equal(&chunk.geometry,&before.mesh_chunks[i].geometry))}
    center:=brush.center
    for delta in ([3][3]f32{{0,0.2,0},{0.14,0.14,0},{0.2,0,0}}) {
        for _ in 0..<12 {
            brush.center,brush.delta=center,delta
            change:=source_edit(&source,brush)
            if !testing.expect_value(t,change.error,Edit_Error.None) {return}
            testing.expect(t,change.changed)
            center+=delta
        }
    }
    collected:geom.Mesh_Buffer;geom.mesh_buffer_init(&collected);defer geom.mesh_buffer_destroy(&collected)
    testing.expect(t,source_mesh_collect(&source,&collected))
    testing.expect(t,geom.mesh_is_closed(collected.positions[:],collected.indices[:]))
    testing.expect(t,source_cost(&source)>source_cost(&before))
    nearest:=f32(1000)
    for p in collected.positions {nearest=min(nearest,linalg.length(p-center))}
    testing.expect(t,nearest<0.01)
    unchanged:=0
    for &chunk,i in source.mesh_chunks {if mesh_equal(&chunk.geometry,&before.mesh_chunks[i].geometry) {unchanged+=1}}
    testing.expect(t,unchanged>0)
}

@(test)
volume_grow_sweeps_connected_capsules_independently_of_event_spacing :: proc(t:^testing.T) {
    once,steps:Source
    defer source_destroy(&once);defer source_destroy(&steps)
    testing.expect(t,source_make(&once,.Volume,{25,25,25},0.5,4))
    testing.expect(t,grid_init(&once.distances,once.distances.size,once.cell*SDF_BAND_CELLS,once.allocator))
    testing.expect(t,source_clone(&steps,&once))
    start,delta:=[3]f32{-3,2,0},[3]f32{6,0,0}
    change:=source_edit(&once,{kind=.Grow,center=start,delta=delta,radius=1,amount=1})
    testing.expect(t,change.changed)
    for i in 0..<12 {
        testing.expect(t,source_edit(&steps,{kind=.Grow,center=start+delta*(f32(i)/12),delta=delta/12,radius=1,amount=1}).changed)
    }
    for z in 0..<25 {for y in 0..<25 {for x in 0..<25 {testing.expect(t,abs(source_value(&once,{x,y,z})-source_value(&steps,{x,y,z}))<1e-6)}}}
    for x in 6..=18 {testing.expect(t,source_value(&once,{x,16,12})<0)}
    testing.expect(t,!source_edit(&once,{kind=.Grow,center=start,delta=delta,radius=1,amount=1}).changed)
    for z in 0..<25 {for y in 0..<25 {for x in 0..<25 {
        if x==0 || y==0 || z==0 || x==24 || y==24 || z==24 {testing.expect(t,source_value(&once,{x,y,z})>0)}
    }}}
}

@(test)
mesh_grow_allocation_failures_leave_the_source_unchanged :: proc(t:^testing.T) {
    height,baseline:Source
    defer source_destroy(&height);defer source_destroy(&baseline)
    testing.expect(t,source_make(&height,.Heightfield,{9,1,9},1,4))
    testing.expect(t,source_convert_heightfield(&baseline,&height,4))
    for allocations in ([7]int{0,1,8,32,64,128,100000}) {
        failure:=Mesh_Conversion_Failure{context.allocator,100000}
        source:Source
        defer source_destroy(&source)
        if !testing.expect(t,source_clone(&source,&baseline,{mesh_conversion_failure_allocator,&failure})) {return}
        failure.remaining=allocations
        change:=source_edit(&source,{kind=.Grow,radius=2,amount=1,delta={0,0.2,0},max_edge=0.5})
        if allocations==100000 {testing.expect(t,change.changed && change.error==.None)}
        if change.error!=.None {
            testing.expect_value(t,change.error,Edit_Error.Out_Of_Memory)
            for &chunk,i in source.mesh_chunks {testing.expect(t,mesh_equal(&chunk.geometry,&baseline.mesh_chunks[i].geometry))}
        }
    }
}
