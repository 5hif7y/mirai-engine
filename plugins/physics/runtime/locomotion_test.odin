package physics

import cmath "core:math"
import "core:testing"
import "mirai:core"
import input "mirai:engine/input"
import sim "plugins:physics/runtime/sim"

// A character of the solver driven by locomotion_move, as locomotion_step drives one of the world.
@(private="file")
Loco_Test :: struct {
    w:sim.World,
    ch:sim.Character_Handle,
    loco:Character,
    walk:Walk,
    fly:Fly,
    swim:Maybe(Swim),
}

@(private="file")
loco_test_init :: proc(f:^Loco_Test,position:[3]f32,ground:=true) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.character_capacity=16,16,128,2
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=1,1,1,64
    if !sim.world_init(&f.w,desc) {return false}
    if ground {loco_test_box(f,{50,1,50},{0,-1,0})}
    f.loco,f.walk=character_default(),WALK_DEFAULT
    f.ch=sim.character_create(&f.w,sim.CHARACTER_DESC_DEFAULT,position)
    return f.ch!={}
}

@(private="file")
loco_test_box :: proc(f:^Loco_Test,half,position:[3]f32) {
    desc:=sim.BODY_DESC_DEFAULT
    desc.type,desc.position=.Static,position
    body:=sim.body_create(&f.w,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Box{half}
    sim.shape_create(&f.w,body,shape)
}

@(private="file")
loco_test_tick :: proc(f:^Loco_Test,move:[3]f32,ticks:=1,buttons:=input.Action_Mask(0),yaw:f32=0,pitch:f32=0) {
    for _ in 0..<ticks {
        found:=character_state_of(sim.character_state(&f.w,f.ch))
        given:=input.Move_Input{move=move,look_yaw=yaw,look_pitch=pitch,buttons=buttons}
        m:=locomotion_move(&f.loco,f.walk,f.fly,f.swim,found,1,given,sim.character_velocity(&f.w,f.ch),f.w.gravity,1.0/60)
        sim.character_set_move(&f.w,f.ch,m)
        sim.world_step(&f.w,1.0/60)
    }
}

@(private="file")
near :: proc(a,b,tolerance:f32) -> bool {return abs(a-b)<=tolerance}

@(test)
walking_reaches_the_speed_of_the_locomotion_and_brakes :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    loco_test_tick(&f,{},30)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    loco_test_tick(&f,{0,0,-1},10)
    // 30 m/s2 for 10 ticks; the first tick decides on the ground the step before it found.
    v:=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.z,-5,0.1),"velocity %v",v)
    loco_test_tick(&f,{0,0,-1},50)
    v=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.z,-5,0.02) && abs(v.x)<0.01 && abs(v.y)<0.01,"velocity %v",v)
    // The look yaw turns the move: a quarter turn to the left makes forward point to -X.
    loco_test_tick(&f,{0,0,-1},40,yaw=0.5*cmath.PI)
    v=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.x,-5,0.02) && abs(v.z)<0.02,"turned velocity %v",v)
    loco_test_tick(&f,{},20)
    testing.expect(t,abs(sim.character_velocity(&f.w,f.ch).x)<0.01)
}

@(test)
a_jump_reaches_the_height_of_the_locomotion_once_per_press :: proc(t:^testing.T) {
    for height in ([2]f32{0.6,1.5}) {
        f:Loco_Test
        testing.expect(t,loco_test_init(&f,{0,0,0}))
        f.walk.jump_height=height
        loco_test_tick(&f,{},30)
        apex:f32
        for i in 0..<120 {
            // The button stays down: only the press jumps.
            loco_test_tick(&f,{},1,input.action_bit(JUMP))
            apex=max(apex,sim.character_position(&f.w,f.ch).y)
            if i==5 {testing.expect(t,f.loco.mode==MODE_FALLING && f.loco.jumped)}
        }
        testing.expectf(t,near(apex,height,0.03*height),"apex %v for a jump of %v",apex,height)
        testing.expect_value(t,f.loco.mode,MODE_WALKING)
        sim.world_destroy(&f.w)
    }
}

@(test)
coyote_time_allows_a_jump_just_after_walking_off_a_ledge :: proc(t:^testing.T) {
    for wait,i in ([2]int{2,20}) {
        f:Loco_Test
        testing.expect(t,loco_test_init(&f,{0,0,-1},false))
        loco_test_box(&f,{2,1,2},{0,-1,0})
        loco_test_tick(&f,{},30)
        for f.loco.mode==MODE_WALKING {loco_test_tick(&f,{0,0,-1})}
        testing.expect(t,f.loco.coyote>0)
        loco_test_tick(&f,{0,0,-1},wait)
        loco_test_tick(&f,{0,0,-1},1,input.action_bit(JUMP))
        loco_test_tick(&f,{0,0,-1},1)
        if i==0 {
            testing.expect(t,f.loco.jumped && sim.character_velocity(&f.w,f.ch).y>4)
        } else {
            testing.expect(t,!f.loco.jumped && sim.character_velocity(&f.w,f.ch).y<-2)
        }
        sim.world_destroy(&f.w)
    }
}

@(test)
a_dash_overrides_the_locomotion_for_its_ticks_and_a_conveyor_adds_to_it :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    loco_test_tick(&f,{},30)
    f.loco.moves[0]={velocity={12,0,0},force=80*12*240,ticks=12,mix=.Override,id=7}
    f.loco.move_count=1
    loco_test_tick(&f,{},12)
    p:=sim.character_position(&f.w,f.ch)
    testing.expectf(t,near(p.x,2.4,0.05) && near(p.y,0,0.01),"dashed to %v",p)
    testing.expect(t,near(sim.character_velocity(&f.w,f.ch).x,12,0.05))
    testing.expect_value(t,f.loco.move_count,0)
    loco_test_tick(&f,{},30)
    testing.expect(t,abs(sim.character_velocity(&f.w,f.ch).x)<0.05)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)

    f.loco.moves[0]={velocity={0,0,2},ticks=1000,mix=.Additive,id=9}
    f.loco.move_count=1
    loco_test_tick(&f,{},30)
    testing.expect(t,near(sim.character_velocity(&f.w,f.ch).z,2,0.02))
    loco_test_tick(&f,{0,0,-1},30)
    testing.expectf(t,near(sim.character_velocity(&f.w,f.ch).z,-3,0.03),"against the conveyor %v",sim.character_velocity(&f.w,f.ch).z)
    moves_remove(&f.loco,9)
    testing.expect_value(t,f.loco.move_count,0)
    loco_test_tick(&f,{0,0,-1},30)
    testing.expect(t,near(sim.character_velocity(&f.w,f.ch).z,-5,0.03))
}

@(test)
a_flying_locomotion_flies_toward_the_look_and_holds_its_height :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    loco_test_tick(&f,{},30)
    f.loco.mode=MODE_FLYING
    f.fly=FLY_DEFAULT
    pitch:f32=30*cmath.RAD_PER_DEG
    loco_test_tick(&f,{0,0,-1},60,pitch=pitch)
    v:=sim.character_velocity(&f.w,f.ch)
    testing.expectf(t,near(v.y,8*cmath.sin(pitch),0.02) && near(v.z,-8*cmath.cos(pitch),0.02) && abs(v.x)<0.02,"flying %v",v)
    testing.expect_value(t,f.loco.mode,MODE_FLYING)
    loco_test_tick(&f,{},60)
    height:=sim.character_position(&f.w,f.ch).y
    loco_test_tick(&f,{},30)
    testing.expect(t,near(sim.character_position(&f.w,f.ch).y,height,0.001) && height>3)
    f.loco.mode=MODE_FALLING
    loco_test_tick(&f,{},150)
    testing.expect(t,f.loco.mode==MODE_WALKING && near(sim.character_position(&f.w,f.ch).y,0,0.01))
}

// A mode of the game writes its own move; the layered moves of the
// locomotion still go on top of it, one tick at a time.
@(test)
layered_moves_go_on_top_of_the_move_of_a_mode_of_the_game :: proc(t:^testing.T) {
    loco:=character_default()
    loco.mode=Locomotion_Mode(16)
    loco.moves[0]={velocity={0,0,2},ticks=2,mix=.Additive,id=3}
    loco.move_count=1
    swim:=sim.Character_Move{air={velocity={1,0,0},force=50},flags={.Airborne,.No_Gravity}}
    move:=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,move.air,sim.Drive{velocity={1,0,2},force=50})
    testing.expect_value(t,loco.added,[3]f32{0,0,2})
    testing.expect_value(t,loco.move_count,1)
    move=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,loco.move_count,0)
    move=swim
    layers_apply(&loco,&move,800)
    testing.expect_value(t,move,swim)
}

// A mode needs the component of its parameters: flying without a Fly, asked
// for or started in, is a problem and the character does not fly.
@(test)
a_mode_needs_its_component :: proc(t:^testing.T) {
    es:core.Entities
    core.entities_init(&es)
    defer core.entities_destroy(&es)
    moves:core.Table(Character_Move);inputs:core.Table(input.Move_Input)
    walks:core.Table(Walk);flights:core.Table(Fly);swims:core.Table(Swim);characters:core.Table(Character);found:core.Table(Character_State)
    motions:core.Table(core.Motion);worlds:core.Table(core.World_Transform);remotes:core.Table(core.Remote)
    core.table_init(&moves,"Character_Move");core.table_init(&inputs,"Move_Input")
    core.table_init(&walks,"Walk");core.table_init(&flights,"Fly");core.table_init(&swims,"Swim");core.table_init(&characters,"Character");core.table_init(&found,"Character_State")
    core.table_init(&motions,"Motion");core.table_init(&worlds,"World_Transform");core.table_init(&remotes,"Remote")
    defer {
        core.table_destroy(&moves);core.table_destroy(&inputs);core.table_destroy(&walks);core.table_destroy(&flights);core.table_destroy(&swims);core.table_destroy(&characters)
        core.table_destroy(&found);core.table_destroy(&motions);core.table_destroy(&worlds);core.table_destroy(&remotes)
    }
    walker,flier:=core.create(&es),core.create(&es)
    starts_flying:=character_default()
    starts_flying.mode=MODE_FLYING
    core.add(&characters,walker,starts_flying)
    core.add(&characters,flier,character_default())
    core.add(&flights,flier,FLY_DEFAULT)
    for e in ([2]core.Entity{walker,flier}) {core.add(&walks,e,WALK_DEFAULT)}
    core.table_settle(&walks,&es);core.table_settle(&flights,&es);core.table_settle(&characters,&es)
    requests:Locomotion_Requests
    defer delete(requests.queue.items)
    set_mode(&requests,flier,MODE_FLYING)
    physics:Physics_State
    problems:core.Problems
    locomotion_step(&characters,&moves,&inputs,core.read(&walks),core.read(&flights),core.read(&swims),core.read(&found),core.read(&motions),core.read(&worlds),core.read(&remotes),core.ref(&physics),{},&requests,{playing=true,dt=1.0/60},core.CLOCK_DEFAULT,&problems)
    walking,_:=core.get(core.read(&characters),walker)
    flying,_:=core.get(core.read(&characters),flier)
    testing.expect(t,walking.mode!=MODE_FLYING,"without a Fly it does not fly")
    testing.expect_value(t,flying.mode,MODE_FLYING)
    testing.expect(t,core.problem_find(&problems,walker,"locomotion.mode_component")!=nil)
    set_mode(&requests,walker,MODE_FLYING)
    locomotion_step(&characters,&moves,&inputs,core.read(&walks),core.read(&flights),core.read(&swims),core.read(&found),core.read(&motions),core.read(&worlds),core.read(&remotes),core.ref(&physics),{},&requests,{playing=true,dt=1.0/60},core.CLOCK_DEFAULT,&problems)
    walking,_=core.get(core.read(&characters),walker)
    testing.expect(t,walking.mode!=MODE_FLYING,"asking for flying without a Fly is refused")
    core.table_settle(&inputs,&es);core.table_settle(&moves,&es)
    testing.expect(t,core.has(&inputs,walker) && core.has(&moves,walker),"playing adds its Move_Input and its Character_Move")
}

// Walks in from the shallows, swims on the surface with its head out, dives,
// comes back up and climbs out onto a ledge.
@(test)
a_swimmer_walks_in_swims_dives_surfaces_and_climbs_out_onto_a_ledge :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,5},false))
    defer sim.world_destroy(&f.w)
    loco_test_box(&f,{10,1,10},{0,-1,10})       // the shallows, a metre under the sea, toward +Z
    loco_test_box(&f,{10,1,10},{0,-7,-10})      // the deep, toward -Z
    loco_test_box(&f,{10,3.65,2},{0,-2.35,-14}) // a ledge 0.3 m over the sea
    testing.expect(t,sim.fluid_create(&f.w,{shape=.Plane,position={0,1,0},density=1000})!={})
    f.swim=SWIM_DEFAULT
    head :: proc(f:^Loco_Test) -> f32 {return sim.character_state(&f.w,f.ch).head_depth}
    loco_test_tick(&f,{},30)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    expect_near(t,head(&f),1-1.8,0.02)
    for i:=0;i<300 && f.loco.mode!=MODE_SWIMMING;i+=1 {loco_test_tick(&f,{0,0,-1})}
    testing.expect_value(t,f.loco.mode,MODE_SWIMMING)
    loco_test_tick(&f,{},300)
    testing.expectf(t,near(head(&f),-SWIM_DEFAULT.surface_offset,0.03),"on the surface the head is %v under it",head(&f))
    testing.expect(t,abs(sim.character_velocity(&f.w,f.ch).y)<0.05)
    // Looking down and forward it dives.
    loco_test_tick(&f,{0,0,-1},90,pitch=-60*cmath.RAD_PER_DEG)
    state:=sim.character_state(&f.w,f.ch)
    testing.expectf(t,state.head_depth>1 && .Underwater in state.fluid,"dived to %v",state.head_depth)
    // Let go, the water stops it and it rises slowly back to the surface, and floats there.
    rise:f32
    for i:=0;i<1200 && head(&f)>0;i+=1 {
        loco_test_tick(&f,{})
        if head(&f)>0.5 {rise=max(rise,sim.character_velocity(&f.w,f.ch).y)}
    }
    testing.expectf(t,rise>0 && rise<0.5,"rises at %v m/s at most",rise)
    loco_test_tick(&f,{},240)
    testing.expect_value(t,f.loco.mode,MODE_SWIMMING)
    testing.expectf(t,near(head(&f),-SWIM_DEFAULT.surface_offset,0.03),"back on the surface, head %v",head(&f))
    // To the ledge, and out onto it.
    for i:=0;i<600 && sim.character_position(&f.w,f.ch).z>-11.6;i+=1 {loco_test_tick(&f,{0,0,-1})}
    loco_test_tick(&f,{0,0,-1},1,input.action_bit(JUMP))
    testing.expect_value(t,f.loco.mode,MODE_FALLING)
    loco_test_tick(&f,{0,0,-1},40)
    loco_test_tick(&f,{},80)
    state=sim.character_state(&f.w,f.ch)
    p:=sim.character_position(&f.w,f.ch)
    testing.expectf(t,f.loco.mode==MODE_WALKING && .Standing in state.ground && near(p.y,1.3,0.02),"out at %v in mode %v",p,f.loco.mode)
    testing.expect_value(t,state.fluid,sim.Fluid_Flags{})
    expect_near(t,state.head_depth,-(0.3+1.8),0.02)
}

@(private="file")
expect_near :: proc(t:^testing.T,value,expected,tolerance:f32,loc:=#caller_location) {
    testing.expectf(t,abs(value-expected)<=tolerance,"got %v, expected %v",value,expected,loc=loc)
}

@(test)
without_gravity_a_swimmer_on_the_surface_does_not_climb :: proc(t:^testing.T) {
    f:Loco_Test
    testing.expect(t,loco_test_init(&f,{0,0,0},false))
    defer sim.world_destroy(&f.w)
    f.loco.mode,f.swim=MODE_SWIMMING,SWIM_DEFAULT
    found:sim.Character_State
    found.fluid,found.head_depth,found.depth={.In_Fluid},-0.25,1.55
    given:=input.Move_Input{buttons=input.action_bit(JUMP)}
    move:=locomotion_move(&f.loco,f.walk,f.fly,f.swim,character_state_of(found),1,given,{},{},1.0/60)
    testing.expect_value(t,f.loco.mode,MODE_SWIMMING)
    testing.expect_value(t,f.loco.move_count,0)
    testing.expect(t,.Float in move.flags)
}
