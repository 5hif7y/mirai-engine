package physics

import "core:math/linalg"
import "core:testing"
import input "mirai:engine/input"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// A character of the solver that crouches, slides and mantles as locomotion_step and the step
// drive one of the world: the mantle is looked for before the locomotion takes the jump, and the
// capsule is made as tall as the locomotion asks before every step.
@(private="file")
Moves_Test :: struct {
    w:sim.World,
    ch:sim.Character_Handle,
    loco:Character,
    walk:Walk,
    slide:Maybe(Slide),
    mantle:Maybe(Mantle),
    asked:f32,
}

@(private="file")
moves_init :: proc(f:^Moves_Test,position:[3]f32,ground:=true) -> bool {
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.character_capacity=16,16,256,2
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=1,1,1,64
    if !sim.world_init(&f.w,desc) {return false}
    if ground {moves_box(f,{50,1,50},{0,-1,0})}
    f.loco,f.walk,f.asked=character_default(),WALK_DEFAULT,sim.CHARACTER_DESC_DEFAULT.height
    f.ch=sim.character_create(&f.w,sim.CHARACTER_DESC_DEFAULT,position)
    return f.ch!={}
}

@(private="file")
moves_box :: proc(f:^Moves_Test,half,position:[3]f32,rotation:=mm.QUAT_IDENTITY) {
    desc:=sim.BODY_DESC_DEFAULT
    desc.type,desc.position,desc.rotation=.Static,position,rotation
    body:=sim.body_create(&f.w,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Box{half}
    sim.shape_create(&f.w,body,shape)
}

@(private="file")
moves_tick :: proc(f:^Moves_Test,move:[3]f32,ticks:=1,buttons:=input.Action_Mask(0),yaw:f32=0) {
    dt:=f32(1.0/60)
    for _ in 0..<ticks {
        found:=character_state_of(sim.character_state(&f.w,f.ch))
        found.height=sim.character_desc(&f.w,f.ch).height
        found.cramped=found.height<f.asked-HEIGHT_EPSILON
        given:=input.Move_Input{move=move,look_yaw=yaw,buttons=buttons}
        if mantle,has:=f.mantle.?;has && (f.loco.mode==MODE_WALKING || f.loco.mode==MODE_FALLING || f.loco.mode==MODE_CROUCHING) {
            if wanted,from_ground:=mantle_wanted(&f.loco,mantle,found,given,TEST_JUMP);wanted {
                facing:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},yaw),{0,0,-1})
                if to,height,ok:=ledge_find(&f.w,f.ch,facing,mantle,from_ground);ok {mantle_start(&f.loco,sim.character_position(&f.w,f.ch),to,height)}
            }
        }
        m:sim.Character_Move
        if f.loco.mode==MODE_MANTLING {
            m=mantle_move(&f.loco,f.mantle.?,1,sim.character_position(&f.w,f.ch),given,TEST_JUMP,dt)
        } else {
            m=locomotion_move(&f.loco,f.walk,{},nil,f.slide,found,1,given,TEST_JUMP,TEST_SPRINT,TEST_CROUCH,sim.character_velocity(&f.w,f.ch),f.w.gravity,dt)
        }
        f.asked=f.loco.crouched?f.walk.crouch_height:sim.CHARACTER_DESC_DEFAULT.height
        if abs(sim.character_desc(&f.w,f.ch).height-f.asked)>HEIGHT_EPSILON {_=sim.character_set_height(&f.w,f.ch,f.asked)}
        sim.character_set_move(&f.w,f.ch,m)
        sim.world_step(&f.w,dt)
    }
}

@(private="file")
flat_speed :: proc(f:^Moves_Test) -> f32 {
    v:=sim.character_velocity(&f.w,f.ch)
    return linalg.length(v.xz)
}

@(private="file") CROUCH :: input.Action_Mask(1)<<u64(TEST_CROUCH)
@(private="file") JUMP :: input.Action_Mask(1)<<u64(TEST_JUMP)

// Crouch held makes the capsule crouch_height tall and walks at crouch_speed; let go under a roof
// lower than standing it stays crouched (cramped) and stands up past the roof.
@(test)
crouching_walks_short_and_slow_and_stands_up_where_there_is_room :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    moves_box(&f,{2,0.1,1.5},{0,1.5,-3.5}) // a roof from 1.4 to 1.6 m over z -5..-2
    moves_tick(&f,{},30)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    moves_tick(&f,{0,0,-1},90,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    testing.expectf(t,abs(sim.character_desc(&f.w,f.ch).height-f.walk.crouch_height)<1e-4,"height %v",sim.character_desc(&f.w,f.ch).height)
    testing.expectf(t,abs(flat_speed(&f)-f.walk.crouch_speed)<0.05,"crouched speed %v",flat_speed(&f))
    z:=sim.character_position(&f.w,f.ch).z
    testing.expectf(t,z<-2.5 && z>-4.5,"under the roof at z %v",z)
    moves_tick(&f,{0,0,-1},10)
    state:=character_state_of(sim.character_state(&f.w,f.ch))
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    testing.expect(t,abs(sim.character_desc(&f.w,f.ch).height-f.walk.crouch_height)<1e-4,"the roof keeps it crouched")
    testing.expect(t,state.standing)
    moves_tick(&f,{0,0,-1},60)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    testing.expectf(t,abs(sim.character_desc(&f.w,f.ch).height-sim.CHARACTER_DESC_DEFAULT.height)<1e-4,"past the roof it stands: %v",sim.character_desc(&f.w,f.ch).height)
}

// Crouch at a run slides on at the speed it ran (friction 0) crouched for time, then stands up when it
// moves, even with crouch held, which crouches again only once let go; without a move it ends crouched.
// Crouch from a walk slower than start_speed crouches; a slide starts again only after cooldown.
@(test)
a_slide_keeps_the_run_for_its_time_and_ends_standing_or_crouched :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0,0}))
    defer sim.world_destroy(&f.w)
    f.slide=SLIDE_DEFAULT
    moves_tick(&f,{},20)
    moves_tick(&f,{0,0,-1},40)
    testing.expectf(t,abs(flat_speed(&f)-5)<0.05,"running %v",flat_speed(&f))
    moves_tick(&f,{0,0,-1},1,CROUCH)
    moves_tick(&f,{0,0,-1},1,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    moves_tick(&f,{1,0,-1},60,CROUCH) // steering right turns the course at most steer_angle
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    testing.expectf(t,abs(flat_speed(&f)-5)<0.1,"slides at the run %v",flat_speed(&f))
    testing.expectf(t,abs(sim.character_desc(&f.w,f.ch).height-f.walk.crouch_height)<1e-4,"slides crouched %v",sim.character_desc(&f.w,f.ch).height)
    v:=sim.character_velocity(&f.w,f.ch)
    turned:=linalg.atan2(v.x,-v.z)
    testing.expectf(t,turned>0.1 && turned<=SLIDE_DEFAULT.steer_angle+0.01,"steered by %v rad",turned)
    moves_tick(&f,{0,0,-1},20,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    testing.expect(t,f.loco.crouch_lock,"crouch held after a slide that ends moving does not crouch")
    moves_tick(&f,{},30,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_WALKING)
    moves_tick(&f,{},1)
    moves_tick(&f,{},5,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
    // Without a move at the end of a slide it stays crouched.
    moves_tick(&f,{0,0,-1},60)
    moves_tick(&f,{0,0,-1},2,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    moves_tick(&f,{},90,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_CROUCHING)
}

// Down a slope steeper than downhill_angle gravity speeds the slide up and keeps it going past its
// time; a jump leaves it in the air with its speed.
@(test)
a_slide_downhill_speeds_up_past_its_time_and_a_jump_leaves_it :: proc(t:^testing.T) {
    f:Moves_Test
    testing.expect(t,moves_init(&f,{0,0.2,0},false))
    defer sim.world_destroy(&f.w)
    moves_box(&f,{5,0.5,40},{0,-0.5,0},mm.quat_axis_angle({1,0,0},-15*mm.RAD_PER_DEG)) // down toward -Z
    f.slide=SLIDE_DEFAULT
    moves_tick(&f,{},30)
    testing.expect(t,character_state_of(sim.character_state(&f.w,f.ch)).standing)
    moves_tick(&f,{0,0,-1},40)
    moves_tick(&f,{0,0,-1},2,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    moves_tick(&f,{},120,CROUCH)
    testing.expect_value(t,f.loco.mode,MODE_SLIDING)
    speed:=linalg.length(sim.character_velocity(&f.w,f.ch))
    testing.expectf(t,speed>8,"gravity sped it up to %v m/s",speed)
    moves_tick(&f,{},1,CROUCH|JUMP)
    testing.expect_value(t,f.loco.mode,MODE_FALLING)
    testing.expect(t,f.loco.jumped)
    moves_tick(&f,{},2)
    testing.expectf(t,flat_speed(&f)>7,"the jump keeps the speed of the slide: %v",flat_speed(&f))
}

// Jump facing a wall whose top is over ground_height climbs onto it in time and stands there; one
// lower is jumped onto, one over max_height, with a roof over its top or behind it is not climbed.
@(test)
jump_facing_a_ledge_mantles_onto_it_where_it_fits :: proc(t:^testing.T) {
    Case :: struct {top:f32,roof:bool,yaw:f32,mantles:bool}
    cases:=[]Case{
        {top=1.8,mantles=true},
        {top=1.0},
        {top=3.0},
        {top=1.8,roof=true},
        {top=1.8,yaw=mm.PI},
    }
    for c in cases {
        f:Moves_Test
        testing.expect(t,moves_init(&f,{0,0,0}))
        defer sim.world_destroy(&f.w)
        f.mantle=MANTLE_DEFAULT
        moves_box(&f,{2,c.top*0.5,0.5},{0,c.top*0.5,-1.3}) // its face at z -0.8
        if c.roof {moves_box(&f,{2,0.1,1},{0,c.top+1.2,-1.8})}
        moves_tick(&f,{},30,yaw=c.yaw)
        moves_tick(&f,{},1,JUMP,yaw=c.yaw)
        testing.expectf(t,(f.loco.mode==MODE_MANTLING)==c.mantles,"%v: mode %v",c,f.loco.mode)
        if !c.mantles {continue}
        testing.expectf(t,abs(f.loco.mantle_height-c.top)<0.01,"%v: ledge %v",c,f.loco.mantle_height)
        ticks:=0
        for f.loco.mode==MODE_MANTLING && ticks<120 {
            moves_tick(&f,{},1,yaw=c.yaw)
            ticks+=1
        }
        testing.expectf(t,ticks>=int(MANTLE_DEFAULT.time*60) && ticks<=int(MANTLE_DEFAULT.time*60)+2,"%v: climbed in %d ticks",c,ticks)
        moves_tick(&f,{},20,yaw=c.yaw)
        at:=sim.character_position(&f.w,f.ch)
        state:=character_state_of(sim.character_state(&f.w,f.ch))
        testing.expectf(t,state.standing && abs(at.y-c.top)<0.05 && at.z<-1.05,"%v: stands on the top at %v",c,at)
        testing.expect_value(t,f.loco.mode,MODE_WALKING)
    }
}
