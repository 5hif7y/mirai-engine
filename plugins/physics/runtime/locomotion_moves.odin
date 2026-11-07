package physics

import cmath "core:math"
import "core:math/linalg"
import input "mirai:engine/input"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// Crouch, slide and mantle, the modes of a character that walks beyond walking and falling.
// Crouching (the crouch action held while it stands, with a Walk whose crouch_height is not zero)
// makes its capsule that tall and walks at crouch_speed; it stands up again when the action is let go
// and what is over it lets it (Character_State.cramped meanwhile). A Slide turns a crouch at a run
// into a slide along the ground, and a Mantle turns a jump facing a ledge into a climb onto it.

@(component,replicated,description="The character can slide (mode sliding of its Character): crouching while it runs at start_speed or faster, or landing at land_speed with crouch pressed within buffer before (or held), it slides along the ground at its speed, at least min_speed and at most max_speed, which gravity changes on a slope and friction takes, steering toward its move a little. It stops after time unless the ground falls away along its course, when something stops it, or with a jump. It needs a Walk with a crouch_height, the height it slides at.")
Slide :: struct {
    start_speed:f32 `mirai:"min=0,unit=m/s"`, // across its up, from which crouch starts a slide
    land_speed:f32 `mirai:"min=0,unit=m/s"`,  // the same for crouch held when it lands
    max_speed:f32 `mirai:"min=0,unit=m/s"`,
    min_speed:f32 `mirai:"min=0,unit=m/s"`,   // its speed along its course while it slides is never under it
    buffer:f32 `mirai:"min=0,unit=s"`,        // a crouch pressed this long before landing slides on landing
    time:f32 `mirai:"min=0,unit=s"`,          // it slides at most this long, unless downhill
    friction:f32 `mirai:"min=0,unit=1/s"`,    // share of its speed lost every second
    downhill_angle:f32 `mirai:"angle,min=0"`, // ground that falls away along its course steeper than this keeps it sliding past time
    steer_angle:f32 `mirai:"angle,min=0"`,    // most its move turns its course from where it started
    steer_speed:f32 `mirai:"angle,min=0,unit=deg/s"`,
    cooldown:f32 `mirai:"min=0,unit=s"`,      // after a slide, before crouch starts another
}

SLIDE_DEFAULT :: Slide{start_speed=4.5,land_speed=1.5,max_speed=12,min_speed=4,buffer=1.5,time=1.25,friction=0,downhill_angle=10*mm.RAD_PER_DEG,steer_angle=20*mm.RAD_PER_DEG,steer_speed=15*mm.RAD_PER_DEG,cooldown=0.5}

@(component,replicated,description="The character can mantle (mode mantling of its Character): with jump, looking at a wall within reach whose top is between min_height and max_height over its feet, with room to stand there and on the way, it climbs onto it in time. Standing, a top lower than ground_height is jumped onto instead; in the air, jump held climbs once delay has passed since it left the ground. Its Character keeps the height of the ledge (mantle_height) for the animation of the climb. It needs a Walk.")
Mantle :: struct {
    reach:f32 `mirai:"min=0,unit=m"`,         // from its axis, ahead, where it looks for the wall
    min_height:f32 `mirai:"min=0,unit=m"`,
    max_height:f32 `mirai:"min=0,unit=m"`,
    ground_height:f32 `mirai:"min=0,unit=m"`, // standing, ledges at most this high are jumped onto
    facing:f32 `mirai:"angle,min=0"`,         // most the wall is off where it looks
    time:f32 `mirai:"min=0,unit=s"`,          // of the climb
    delay:f32 `mirai:"min=0,unit=s"`,         // in the air since it left the ground before jump held climbs
}

MANTLE_DEFAULT :: Mantle{reach=1,min_height=0.5,max_height=2.5,ground_height=1.2,facing=45*mm.RAD_PER_DEG,time=0.6,delay=0.25}

@(private) SLIDE_BLOCKED :: f32(0.5)     // share of the speed of the slide under which the body is held back
@(private) SLIDE_BLOCK_AFTER :: f32(0.1) // s into a slide before that is checked: it starts from the speed the body had
@(private) LEDGE_PROBE :: f32(0.5)     // share of its radius of the sphere that looks for the wall
@(private) LEDGE_WALL :: f32(0.7)      // least part of the normal of a wall across its up: within 45° of upright
@(private) LEDGE_INSET :: f32(0.05)    // m past the face, and over the top, the capsule is put
@(private) LEDGE_SWEEP :: f32(0.9)     // share of its radius the capsule swept along the way has
@(private) MANTLE_TOLERANCE :: f32(0.4) // m off the way at which a climb is given up: something pushed it
@(private) MANTLE_FORCE :: f32(10)     // times its traction force that drives the climb
@(private) MANTLE_RISE :: f32(0.6)     // share of the climb by which it has risen
@(private) MANTLE_ACROSS :: f32(0.4)   // and from which it moves across onto the top

// The top speed of a walk crouched: crouch_speed, which neither sprint nor moving back change.
@(private)
crouch_speed :: proc "contextless" (walk:Walk) -> f32 {return max(walk.crouch_speed,0)}

// The velocity along the ground of a tick of a slide, and whether it ends: its speed, which gravity
// along its course changes and friction takes, along its course, which the move turns toward itself
// at most steer_angle from where it started at steer_speed. n is the normal of the ground, current
// its velocity along it relative to the ground.
@(private)
slide_velocity :: proc(loco:^Character,slide:Slide,n,up,current,wish,gravity:[3]f32,dt:f32) -> (velocity:[3]f32,ended:bool) {
    loco.slide_time+=dt
    if flat:=wish-up*linalg.dot(wish,up);linalg.dot(flat,flat)>1e-8 {
        start:=loco.slide_course
        want:=clamp(linalg.atan2(linalg.dot(linalg.cross(start,flat),up),linalg.dot(start,flat)),-slide.steer_angle,slide.steer_angle)
        loco.slide_turn=mm.angle_approach(loco.slide_turn,want,slide.steer_speed*dt)
    }
    course:=mm.quat_rotate(mm.quat_axis_angle(up,loco.slide_turn),loco.slide_course)
    along:=course-n*linalg.dot(course,n)
    if l:=linalg.length(along);l>1e-6 {along/=l} else {along=course}
    moving:=linalg.length(current)
    speed:=clamp(moving+(linalg.dot(gravity,along)-slide.friction*moving)*dt,slide.min_speed,max(slide.max_speed,slide.min_speed))
    downhill:=-linalg.dot(along,up)>cmath.sin(slide.downhill_angle)
    // Something in the way: the body goes at under half the speed the slide drives it at.
    blocked:=loco.slide_time>SLIDE_BLOCK_AFTER && moving<SLIDE_BLOCKED*speed
    ended=blocked || loco.slide_time>=slide.time && !downhill
    return along*speed,ended
}

@(private)
slide_start :: proc "contextless" (loco:^Character,current,up:[3]f32) {
    course:=current-up*linalg.dot(current,up)
    if l:=linalg.length(course);l>1e-6 {course/=l}
    loco.slide_course,loco.slide_turn,loco.slide_time=course,0,0
}

// Whether a character asks to mantle this tick, before its locomotion takes the jump: jump pressed
// while it stands (from_ground), or jump held once it has been delay in the air.
mantle_wanted :: proc "contextless" (loco:^Character,mantle:Mantle,ground:Character_State,move_input:input.Move_Input,jump:input.Action) -> (wanted,from_ground:bool) {
    held:=move_input.buttons&input.action_bit(jump)!=0
    switch loco.mode {
    case MODE_WALKING,MODE_CROUCHING:
        if ground.standing && held && !loco.jump_held {return true,true}
    case MODE_FALLING:
        if !ground.standing && held && loco.air_time>=mantle.delay {return true,false}
    }
    return false,false
}

// Where a character can mantle onto ahead of it toward facing: its feet on the top of a ledge, height
// over its feet. A sphere half its radius from just over its step finds the wall within reach, which is
// within 45° of upright and within facing of where it looks; a ray down from max_height over its feet,
// a radius past the face, finds the top, walkable for it, between min_height and max_height (over
// ground_height from_ground). Its capsule fits standing there, and a thinner one goes up along the wall
// and across onto it without hitting anything.
ledge_find :: proc(w:^sim.World,h:sim.Character_Handle,facing:[3]f32,mantle:Mantle,from_ground:bool) -> (to:[3]f32,height:f32,found:bool) {
    if !sim.character_valid(w,h) || !(mantle.reach>0) || !(mantle.max_height>mantle.min_height) {return}
    desc:=sim.character_desc(w,h)
    frame:=sim.character_state(w,h).up_frame
    up:=mm.quat_rotate(frame,{0,1,0})
    ahead:=facing-up*linalg.dot(facing,up)
    if l:=linalg.length(ahead);l>1e-6 {ahead/=l} else {return}
    feet:=sim.character_position(w,h)
    filter:=sim.Query_Filter{filter=desc.filter,ignore_body=sim.character_body(w,h)}
    probe:=desc.radius*LEDGE_PROBE
    wall,hit:=sim.shape_cast_closest(w,sim.Sphere{probe},{feet+up*(desc.step_height+probe),mm.QUAT_IDENTITY},ahead*mantle.reach,filter)
    if !hit || !(wall.fraction>0) {return}
    across:=wall.normal-up*linalg.dot(wall.normal,up)
    span:=linalg.length(across)
    if span<LEDGE_WALL {return}
    into:=-across/span
    if linalg.dot(into,ahead)<cmath.cos(mantle.facing) {return}
    over:=wall.point+into*(desc.radius+LEDGE_INSET)
    over-=up*linalg.dot(over-feet,up)
    drop:=mantle.max_height+LEDGE_INSET-mantle.min_height
    top,landed:=sim.ray_cast_closest(w,over+up*(mantle.max_height+LEDGE_INSET),-up*drop,filter)
    if !landed || !(top.fraction>0) || linalg.dot(top.normal,up)<cmath.cos(desc.max_slope) {return}
    height=linalg.dot(top.point-feet,up)
    if height<mantle.min_height || height>mantle.max_height || from_ground && height<=mantle.ground_height {return}
    center:=desc.step_height+0.5*(desc.height-desc.step_height)
    capsule:=sim.Capsule{desc.radius,0.5*(desc.height-desc.step_height)-desc.radius}
    blocking:[1]sim.Shape_Handle
    if sim.overlap_shape(w,capsule,{top.point+up*(center+LEDGE_INSET),frame},blocking[:],filter)>0 {return}
    thin:=sim.Capsule{capsule.radius*LEDGE_SWEEP,capsule.half_height}
    start:=feet+up*center
    raised:=start+up*(height+LEDGE_INSET)
    if _,blocked:=sim.shape_cast_closest(w,thin,{start,frame},raised-start,filter);blocked {return}
    if _,blocked:=sim.shape_cast_closest(w,thin,{raised,frame},top.point+up*(center+LEDGE_INSET)-raised,filter);blocked {return}
    return top.point,height,true
}

// Starts a climb from where the feet are to the top a ledge_find gave.
mantle_start :: proc "contextless" (loco:^Character,from,to:[3]f32,height:f32) {
    loco.mode,loco.jumped,loco.coyote,loco.crouched=MODE_MANTLING,false,0,false
    loco.mantle_from,loco.mantle_to,loco.mantle_time,loco.mantle_height=from,to,0,height
}

// Where the feet are a share u of the way of a climb: up along the wall first, then across onto the
// top, the two overlapping (MANTLE_RISE, MANTLE_ACROSS) and each easing in and out.
mantle_point :: proc "contextless" (from,to,up:[3]f32,u:f32) -> [3]f32 {
    rise:=linalg.dot(to-from,up)
    flat:=to-from-up*rise
    return from+up*(rise*mm.smoothstep(0,MANTLE_RISE,u))+flat*mm.smoothstep(MANTLE_ACROSS,1,u)
}

// The Character_Move of a tick of a climb, from where its feet are: a drive that overrides gravity and
// the ground and takes the feet where the way puts them at the end of the tick. At the end of the way,
// or when something holds it off the way, it falls (and stands on what it climbed).
mantle_move :: proc(loco:^Character,mantle:Mantle,frame:mm.Quat,position:[3]f32,move_input:input.Move_Input,jump:input.Action,dt:f32) -> (move:sim.Character_Move) {
    up:=mm.quat_rotate(frame,{0,1,0})
    move.yaw=move_input.look_yaw
    loco.jump_held=move_input.buttons&input.action_bit(jump)!=0
    loco.crouched=false
    length:=max(mantle.time,dt)
    now:=mantle_point(loco.mantle_from,loco.mantle_to,up,min(loco.mantle_time/length,1))
    off:=position-now
    if loco.mantle_time>=length || linalg.dot(off,off)>MANTLE_TOLERANCE*MANTLE_TOLERANCE {
        loco.mode,loco.air_time=MODE_FALLING,0
        move.air={{},loco.traction_force}
        return
    }
    loco.mantle_time+=dt
    next:=mantle_point(loco.mantle_from,loco.mantle_to,up,min(loco.mantle_time/length,1))
    drive:=sim.Drive{(next-position)/dt,max(loco.traction_force,1)*MANTLE_FORCE}
    move.ground,move.air=drive,drive
    move.flags={.Airborne,.Drive_Vertical,.No_Gravity}
    return
}
