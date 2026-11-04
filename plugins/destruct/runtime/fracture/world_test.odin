package fracture

import sim "plugins:physics/runtime/sim"

FRACTURE_BENCH :: #config(FRACTURE_BENCH,false)

// A simulation world with its fracture, stepped and saved together. A save keeps one copy of the
// fracture beside the bytes of the world: the last one taken. A restore keeps the hulls of the world.
@(private)
World :: struct {
    sim:sim.World,
    fracture:Fracture,
    saved:Fracture,
}

@(private)
world_init :: proc(w:^World,desc:sim.World_Desc,fracture:=Desc{}) -> bool {
    if !sim.world_init(&w.sim,desc) {return false}
    d:=fracture
    if d.pieces==0 {d=desc_default();d.destructibles,d.connections=8,4096}
    if d.events==0 {d.events=desc.event_capacity}
    d.bodies=w.sim.desc.body_capacity
    if fracture_init(&w.fracture,d) && fracture_init(&w.saved,d) {return true}
    world_destroy(w)
    return false
}

@(private)
world_destroy :: proc(w:^World) {
    fracture_destroy(&w.fracture)
    fracture_destroy(&w.saved)
    sim.world_destroy(&w.sim)
}

@(private)
world_step :: proc(w:^World,dt:f32) {
    sim.world_step(&w.sim,dt)
    fracture_update(&w.fracture,&w.sim)
}

@(private)
world_snapshot :: proc(w:^World,buffer:[]byte) -> (int,bool) {
    size,ok:=sim.world_snapshot(&w.sim,buffer)
    if ok {fracture_copy(&w.saved,&w.fracture)}
    return size,ok
}

@(private)
world_restore :: proc(w:^World,buffer:[]byte) -> bool {
    if !sim.world_restore(&w.sim,buffer) {return false}
    return fracture_copy(&w.fracture,&w.saved,geometry=false)
}

@(private) world_snapshot_size :: proc(w:^World) -> int {return sim.world_snapshot_size(&w.sim)}
@(private) world_snapshot_capacity :: proc(w:^World) -> int {return sim.world_snapshot_capacity(&w.sim)}

@(private)
world_hash :: proc(w:^World) -> u64 {
    return sim.world_hash(&w.sim)~(fracture_hash(&w.fracture)*0x9e3779b97f4a7c15)
}

@(private)
test_ground :: proc(w:^World,half:Vec3={50,1,50}) -> Body_Handle {
    desc:=sim.BODY_DESC_DEFAULT
    desc.type=.Static
    desc.position={0,-half.y,0}
    ground:=sim.body_create(&w.sim,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Box{half}
    sim.shape_create(&w.sim,ground,shape)
    return ground
}

@(private)
test_body :: proc(w:^World,geometry:sim.Geometry,position:Vec3,type:=sim.Body_Type.Dynamic) -> Body_Handle {
    desc:=sim.BODY_DESC_DEFAULT
    desc.type=type
    desc.position=position
    body:=sim.body_create(&w.sim,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=geometry
    sim.shape_create(&w.sim,body,shape)
    return body
}

@(private)
test_steps :: proc(w:^World,count:int,dt:f32=1.0/60) {
    for _ in 0..<count {world_step(w,dt)}
}
