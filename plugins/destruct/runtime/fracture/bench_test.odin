package fracture

import "core:testing"
import sim "plugins:physics/runtime/sim"
import "core:time"
import "core:fmt"
import "core:slice"
import "mirai:std/geom"

@(private="file") BENCH_SIDE :: 16  // cubes along x and z
@(private="file") BENCH_LAYERS :: 4 // cubes along y
@(private="file") BENCH_CUBE :: f32(0.25)

@(private="file")
bench_destruct_world :: proc(w:^World) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity=4096,4096,16384
    desc.hull_capacity=4096
    desc.sleep_disabled=true
    return world_init(w,desc,{destructibles=4,pieces=4096,connections=8192})
}

// A slab of 16 x 4 x 16 cubes of 25 cm whose faces bond, in four clusters under one root when `hierarchy`.
@(private="file")
bench_slab :: proc(w:^World,position:Vec3,hierarchy:bool) -> (h:Destructible_Handle,error:Destructible_Error) {
    f:geom.Fracture;geom.fracture_init(&f);defer geom.fracture_destroy(&f)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    membership:[dynamic]i32;defer delete(membership)
    index :: proc(x,y,z:int) -> u32 {return u32((y*BENCH_SIDE+z)*BENCH_SIDE+x)}
    for y in 0..<BENCH_LAYERS {for z in 0..<BENCH_SIDE {for x in 0..<BENCH_SIDE {
        first_vertex,first_index:=u32(len(f.mesh.positions)),u32(len(f.mesh.indices))
        center:=BENCH_CUBE*Vec3{f32(x)-0.5*BENCH_SIDE+0.5,f32(y)-0.5*BENCH_LAYERS+0.5,f32(z)-0.5*BENCH_SIDE+0.5}
        for point in cube.positions {append(&f.mesh.positions,point*BENCH_CUBE+center)}
        append(&f.mesh.indices,..cube.indices[:])
        for _ in 0..<len(cube.indices)/3 {append(&f.mesh.materials,0)}
        append(&f.pieces,geom.Fracture_Piece{site=index(x,y,z),first_vertex=first_vertex,vertex_count=u32(len(cube.positions)),
            first_index=first_index,index_count=u32(len(cube.indices)),volume=BENCH_CUBE*BENCH_CUBE*BENCH_CUBE,center=center})
        append(&membership,1+i32(x*2/BENCH_SIDE)+2*i32(z*2/BENCH_SIDE))
    }}}
    area:=BENCH_CUBE*BENCH_CUBE
    for y in 0..<BENCH_LAYERS {for z in 0..<BENCH_SIDE {for x in 0..<BENCH_SIDE {
        if x+1<BENCH_SIDE {append(&f.connections,geom.Fracture_Connection{index(x,y,z),index(x+1,y,z),area})}
        if y+1<BENCH_LAYERS {append(&f.connections,geom.Fracture_Connection{index(x,y,z),index(x,y+1,z),area})}
        if z+1<BENCH_SIDE {append(&f.connections,geom.Fracture_Connection{index(x,y,z),index(x,y,z+1),area})}
    }}}
    clusters:=[5]Cluster_Desc{{parent=-1,strength=100},{parent=0,strength=50},{parent=0,strength=50},{parent=0,strength=50},{parent=0,strength=50}}
    desc:=DESTRUCTIBLE_DESC_DEFAULT
    desc.fracture,desc.position=&f,position
    desc.impact_damage=false
    if hierarchy {desc.clusters,desc.piece_clusters=clusters[:],membership[:]}
    return destructible_create(&w.fracture,&w.sim,desc)
}

// Making a slab of 1,024 pieces, splitting it, and stepping it whole on the ground.
@(test)
bench_destruct :: proc(t:^testing.T) {
    if !FRACTURE_BENCH {return}
    ROUNDS :: 5
    build,flat_build,root,split:f64
    shapes,contacts:int
    step:f64
    for _ in 0..<ROUNDS {
        w:=new(World)
        if !bench_destruct_world(w) {free(w);return}
        test_ground(w)
        mark:=time.tick_now()
        h,error:=bench_slab(w,{0,0.5,0},true)
        build+=time.duration_milliseconds(time.tick_since(mark))/ROUNDS
        if error!=.None {fmt.printfln("BENCH destruct: %v",error);world_destroy(w);free(w);return}
        other,other_error:=bench_slab(w,{20,0.5,0},true)
        mark=time.tick_now()
        _,broke:=destructible_strain(&w.fracture,&w.sim,other,{20,0.5,0},100,1000)
        root+=time.duration_milliseconds(time.tick_since(mark))/ROUNDS
        destructible_destroy(&w.fracture,&w.sim,other)
        mark=time.tick_now()
        flat,flat_error:=bench_slab(w,{-20,0.5,0},false)
        flat_build+=time.duration_milliseconds(time.tick_since(mark))/ROUNDS
        mark=time.tick_now()
        _,split_broke,_:=destructible_field_body(&w.fracture,&w.sim,flat,-1,{point={-20,0.5,0},half_extents={0.1,10,10},rotation=sim.QUAT_IDENTITY,falloff=.Constant},1e9)
        split+=time.duration_milliseconds(time.tick_since(mark))/ROUNDS
        destructible_destroy(&w.fracture,&w.sim,flat)
        if other_error!=.None || flat_error!=.None || !broke || !split_broke {
            fmt.printfln("BENCH destruct: %v %v %v %v",other_error,flat_error,broke,split_broke)
            world_destroy(w);free(w);return
        }
        for _ in 0..<30 {world_step(w,1.0/60)}
        for _ in 0..<120 {
            mark=time.tick_now()
            world_step(w,1.0/60)
            step+=time.duration_milliseconds(time.tick_since(mark))/(120*ROUNDS)
        }
        shapes,contacts=sim.world_stats(&w.sim).shapes,sim.world_stats(&w.sim).active_contacts
        if destructible_revision(&w.fracture,h)!=0 {fmt.printfln("BENCH destruct: the slab broke while it stood")}
        world_destroy(w)
        free(w)
    }
    fmt.printfln("BENCH destruct 1024 pieces: build %.3f ms (flat %.3f), root break into 4 clusters %.3f ms, flat split in two %.3f ms",build,flat_build,root,split)
    fmt.printfln("BENCH destruct whole slab on the ground: %.4f ms/step, %v shapes, %v active contacts",step,shapes,contacts)
}

// A wall of 128 pieces anchored to the ground, broken by a 520 kg ball at 40 m/s.
@(test)
bench_wall :: proc(t:^testing.T) {
    if !FRACTURE_BENCH {return}
    w:=new(World)
    defer free(w)
    if !bench_destruct_world(w) {return}
    defer world_destroy(w)
    test_ground(w)
    mesh:geom.Mesh_Buffer
    geom.mesh_buffer_init(&mesh)
    defer geom.mesh_buffer_destroy(&mesh)
    geom.cube_build(&mesh,{8,4,0.5})
    sites:[128]Vec3
    geom.sites_generate(sites[:],{pattern=.Uniform,seed=11,lo={-4,-2,-0.25},hi={4,2,0.25}})
    anchors:=[1]Aabb{{{-4.1,-2.1,-0.4},{4.1,-1.95,0.4}}}
    desc:=DESTRUCTIBLE_DESC_DEFAULT
    desc.mesh,desc.sites,desc.anchors,desc.position=geom.mesh_buffer_view(&mesh),sites[:],anchors[:],{0,2,0}
    desc.damage_radius,desc.debris_volume=1.5,0.06
    mark:=time.tick_now()
    wall,error:=destructible_create(&w.fracture,&w.sim,desc)
    build:=time.duration_milliseconds(time.tick_since(mark))
    if error!=.None {
        fmt.printfln("BENCH wall: %v",error)
        return
    }
    desc.position={30,2,0}
    other,_:=destructible_create(&w.fracture,&w.sim,desc)
    mark=time.tick_now()
    _,broke:=destructible_damage(&w.fracture,&w.sim,other,{30,2,0.25},1.5,{0,0,-20000})
    damage:=time.duration_milliseconds(time.tick_since(mark))
    freed:=sim.world_stats(&w.sim).bodies-3
    destructible_destroy(&w.fracture,&w.sim,other)
    pieces:=destructible_pieces(&w.fracture,&w.sim,wall,nil)
    connections:=destructible_connections(&w.fracture,wall,nil)
    for _ in 0..<30 {world_step(w,1.0/60)}
    intact:f64
    for _ in 0..<60 {
        mark=time.tick_now()
        world_step(w,1.0/60)
        intact+=time.duration_milliseconds(time.tick_since(mark))/60
    }
    ball:=sim.body_create(&w.sim,{type=.Dynamic,position={0,2,4},rotation=sim.QUAT_IDENTITY,linear_velocity={0,0,-40},gravity_scale=1,bullet=true})
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Sphere{0.5}
    sim.shape_create(&w.sim,ball,shape)
    times:[120]f64
    breaking:f64
    events,most_contacts:=0,0
    for &ms in times {
        mark=time.tick_now()
        world_step(w,1.0/60)
        ms=time.duration_milliseconds(time.tick_since(mark))
        if events==0 && len(fracture_events(&w.fracture))>0 {breaking=ms}
        events+=len(fracture_events(&w.fracture))
        most_contacts=max(most_contacts,sim.world_stats(&w.sim).active_contacts)
    }
    worst,mean:f64
    for ms in times {worst,mean=max(worst,ms),mean+ms/len(times)}
    slice.sort(times[:])
    median:=times[len(times)/2]
    info:=make([]Piece_Info,pieces)
    defer delete(info)
    destructible_pieces(&w.fracture,&w.sim,wall,info)
    loose,debris:=0,0
    for piece in info {
        if piece.body!=destructible_body(&w.fracture,wall) {loose+=1}
        if .Debris in piece.flags {debris+=1}
    }
    mark=time.tick_now()
    _,cut:=destructible_slice(&w.fracture,&w.sim,wall,{0,2.9,0},{0,1,0.2})
    slice:=time.duration_milliseconds(time.tick_since(mark))
    stats:=sim.world_stats(&w.sim)
    fmt.printfln("BENCH wall of %v pieces and %v connections: build %.2f ms, intact step %.4f ms, step that breaks it %.3f ms; 120 steps after: median %.3f ms, mean %.3f, worst %.3f; %v events, %v pieces loose (%v debris), at most %v contacts; damage call that frees %v groups %.3f ms (%v), slice call %.3f ms (%v); bodies %v contacts %v",
        pieces,connections,build,intact,breaking,median,mean,worst,events,loose,debris,most_contacts,freed,damage,broke,slice,cut,stats.bodies,stats.active_contacts)
}
