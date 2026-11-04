package physics

import cmath "core:math"
import "core:math/linalg"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"
import sim "plugins:physics/runtime/sim"

// How a Character moves by its Move_Input. The Character holds its mode and
// the state between ticks; each mode has its parameters in a component of its
// own, and an entity can use the modes whose components it has: Walk for
// walking and falling, Fly for flying, Swim for swimming, the component of a
// mode a game declares (a constant of Locomotion_Mode with @(name_requires):
// climbing). Before every step locomotion_step writes the Character_Move of
// the character from its input and from the ground and the fluid the last step
// found, in the frame of its vertical (core.Vertical): the look turns about
// its up, and ground, jump and air are measured along it. The simulation
// decides whether it stands. Falling and walking follow the ground and go
// into swimming where the water is deeper than Swim.depth, swimming comes out
// of it onto shallow ground, flying holds until another mode is asked, and a
// mode of a game is written by a function of the game that runs before this
// one, every tick, over which this one adds the layered moves. Modes and layered moves are
// asked through Locomotion_Requests. The components replicate: every end of a
// network session runs the same locomotion from the same state. The
// Move_Input and the Character_Move of a Character are added while it plays.

@(names="MODE_")
Locomotion_Mode :: distinct u16
@(name_requires="Walk") MODE_FALLING :: Locomotion_Mode(0)
@(name_requires="Walk") MODE_WALKING :: Locomotion_Mode(1)
@(name_requires="Fly") MODE_FLYING :: Locomotion_Mode(2)
@(name_requires="Swim") MODE_SWIMMING :: Locomotion_Mode(3)

// What forward is for the seat that drives a Character: where its Move_Input
// comes from while a seat drives it.
Move_Relative :: enum u8 {
    Look,   // where it looks; the look action of the seat turns it and tilts its look: first person, a camera on its head
    Camera, // where the camera of its Drivable looks; it turns toward its move: a camera that orbits it
    World,  // -Z of the world; it turns toward its move: seen from above
    Game,   // the game writes its Move_Input
    View,   // Look while the camera of its Drivable looks with it (Eyes, or an Orbit that aims), Camera otherwise: for a camera that changes mode
}

LAYERED_MOVE_CAPACITY :: 4

Move_Mix :: enum u8 {
    Additive, // added to the velocity the locomotion drives toward
    Override, // replaces it on every axis, without gravity or ground, for as long as it lasts
}

// A velocity on top of the locomotion for a number of ticks: dash, wind, conveyor.
Layered_Move :: struct {
    velocity:[3]f32 `mirai:"unit=m/s"`, // world axes
    force:f32 `mirai:"min=0,unit=N"`,   // limit of the force of an Override; 0 takes the traction force
    ticks:u32,                          // left
    mix:Move_Mix,
    id:u32,                             // meaning given by the game
}

@(component,replicated,description="The character can walk, jump and fall (modes walking and falling of its Character).")
Walk :: struct {
    max_speed:f32 `mirai:"min=0,unit=m/s"`,
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
    braking:f32 `mirai:"min=0,unit=m/s2"`,
    air_control:f32 `mirai:"min=0,max=1"`,  // share of the acceleration and of the traction left in the air
    jump_height:f32 `mirai:"min=0,unit=m"`,
    coyote_time:f32 `mirai:"min=0,unit=s"`, // after walking off a ledge, in which a jump still starts
}

WALK_DEFAULT :: Walk{max_speed=5,acceleration=30,braking=40,air_control=0.3,jump_height=1.2,coyote_time=0.1}

@(component,replicated,description="The character can fly (mode flying of its Character): toward the move in the axes of the look, without gravity.")
Fly :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
}

FLY_DEFAULT :: Fly{speed=8,acceleration=30}

@(component,replicated,description="The character can swim (mode swimming of its Character): in water deeper than depth, toward the move in the axes of the look, with its head out at the surface. Jump climbs out onto a ledge.")
Swim :: struct {
    speed:f32 `mirai:"min=0,unit=m/s"`,
    acceleration:f32 `mirai:"min=0,unit=m/s2"`,
    depth:f32 `mirai:"min=0,unit=m"`,          // of water over the ground from which it swims instead of walking
    surface_offset:f32 `mirai:"min=0,unit=m"`, // of the head over the surface while it swims on it
}

SWIM_DEFAULT :: Swim{speed=2,acceleration=4,depth=1.2,surface_offset=0.25}

Locomotion_Request_Kind :: enum u8 {
    Add_Move,
    Remove_Moves, // those of the id of the move
    Set_Mode,
}

Locomotion_Request :: struct {
    entity:core.Entity,
    kind:Locomotion_Request_Kind,
    move:Layered_Move,
    mode:Locomotion_Mode,
}

// The game asks for layered moves and modes by pushing here; locomotion_step
// takes them before it moves the characters.
@(storage,queue)
Locomotion_Requests :: struct {
    queue:core.Queue(Locomotion_Request),
}

add_move :: proc(requests:^Locomotion_Requests,e:core.Entity,move:Layered_Move) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Add_Move,move=move})
}
remove_moves :: proc(requests:^Locomotion_Requests,e:core.Entity,id:u32) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Remove_Moves,move={id=id}})
}
set_mode :: proc(requests:^Locomotion_Requests,e:core.Entity,mode:Locomotion_Mode) {
    core.push(&requests.queue,Locomotion_Request{entity=e,kind=.Set_Mode,mode=mode})
}

@(step="fixed",stage="simulate",before="physics_prepare")
locomotion_step :: proc(
    characters:^core.Table(Character),moves:^core.Table(Character_Move),inputs:^core.Table(input.Move_Input),
    walks:core.Read(Walk),flights:core.Read(Fly),swims:core.Read(Swim),found:core.Read(Character_State),motions:core.Read(core.Motion),
    worlds:core.Read(core.World_Transform),remotes:core.Read(core.Remote),physics:core.Ref(Physics_State),
    paces:core.Read(core.Own_Pace),requests:^Locomotion_Requests,time:core.Time,clock:core.Clock,problems:^core.Problems,
) {
    for asked in core.take(&requests.queue) {
        c:=core.get(characters,asked.entity)
        if c==nil {
            core.report(problems,asked.entity,"locomotion.request","a layered move or a mode was asked for this entity, which has no Character; give it one")
            continue
        }
        switch asked.kind {
        case .Add_Move:
            if asked.move.ticks==0 || c.move_count>=LAYERED_MOVE_CAPACITY {
                core.report(problems,asked.entity,"locomotion.request",asked.move.ticks==0?"a layered move without ticks was asked; give it the ticks it lasts":"a layered move was asked of a Character that carries LAYERED_MOVE_CAPACITY of them; end some with remove_moves")
                continue
            }
            c.moves[c.move_count]=asked.move
            c.move_count+=1
        case .Remove_Moves:
            moves_remove(c,asked.move.id)
        case .Set_Mode:
            if missing:=mode_missing(asked.mode,asked.entity,walks,flights,swims);missing!="" {
                core.report(problems,asked.entity,"locomotion.mode_component","the mode %s was asked of an entity without %s; give it a %s, which holds the parameters of that mode",mode_label(asked.mode),missing,missing)
                continue
            }
            c.mode,c.jumped,c.coyote=asked.mode,false,0
        }
    }
    if !time.playing || time.dt<=0 {return}
    for row in 0..<core.count(characters) {
        e:=core.entity_at(characters,row)
        c:=core.at(characters,row)
        frame:=up_frame_of(physics,e)
        move_input:=core.get(inputs,e)
        if move_input==nil {
            // Whoever drives it writes into the one it gets here, looking where it stands.
            first:input.Move_Input
            if placed,ok:=core.get(worlds,e);ok {first.look_yaw=look_yaw_of(frame,placed.rotation)}
            core.add(inputs,e,first)
            move_input=core.added(inputs,e)
            c.ready=true
        }
        if !c.ready {
            // It looks where it stands, where this end decides it.
            if placed,ok:=core.get(worlds,e);ok && core.owned(remotes,e) {move_input.look_yaw=look_yaw_of(frame,placed.rotation)}
            c.ready=true
        }
        given:input.Move_Input
        if move_input!=nil {given=move_input^}
        pace:=core.pace_of(clock,paces,e)
        ground,_:=core.get(found,e)
        motion,_:=core.get(motions,e)
        next:Character_Move
        walk:Maybe(Walk)
        if found_walk,has:=core.get(walks,e);has {walk=found_walk}
        fly,_:=core.get(flights,e)
        swim:Maybe(Swim)
        if found_swim,has:=core.get(swims,e);has {swim=found_swim}
        if missing:=mode_missing(c.mode,e,walks,flights,swims);missing!="" {
            core.report(problems,e,"locomotion.mode_component","its Character is in the mode %s and it has no %s; give it a %s, which holds the parameters of that mode, or start it in another mode",mode_label(c.mode),missing,missing)
            // It falls when it can, and otherwise stands.
            if core.has(walks,e) {c.mode=MODE_FALLING}
        }
        if mode_missing(c.mode,e,walks,flights,swims)!="" {
            next.value={}
        } else if c.mode>MODE_SWIMMING {
            if written:=core.get(moves,e);written!=nil {next=written^}
            layers_apply(c,&next.value,c.traction_force,pace)
            move_paced(&next.value,c,pace,motion.linear,ground,frame)
        } else {
            next.value=locomotion_move_paced(c,walk,fly,swim,ground,frame,given,motion.linear,gravity_of_entity(physics,e)*c.gravity_scale,time.dt,pace)
        }
        if row:=core.row_of(moves,e);row<0 {
            core.add(moves,e,next)
        } else if moves.values[row]!=next {core.at(moves,row)^=next}
    }
}

// Direction of the move of the input in the world, across the up of the frame
// of the vertical, at most 1 long.
move_wish :: proc "contextless" (move_input:input.Move_Input,frame:mm.Quat) -> [3]f32 {
    s,c:=cmath.sincos(move_input.look_yaw)
    m:=move_input.move
    wish:=[3]f32{c*m.x+s*m.z,0,c*m.z-s*m.x}
    if l:=linalg.length(wish);l>1 {wish/=l}
    return mm.quat_rotate(frame,wish)
}

// The Character_Move of one tick of a mode of the locomotion: from the input,
// the ground and the fluid the last step left, the frame of its vertical, the
// velocity of the body and its gravity, all in its own time, which runs pace
// times the time of the world (dt is that of its own time). walking and swim
// are nil for a character that cannot walk or swim: one that only swims stays
// in the mode out of the water.
locomotion_move :: proc(loco:^Character,walking:Maybe(Walk),fly:Fly,swim:Maybe(Swim),ground:Character_State,frame:mm.Quat,move_input:input.Move_Input,velocity,gravity:[3]f32,dt:f32,pace:f32=1) -> (move:sim.Character_Move) {
    up:=mm.quat_rotate(frame,{0,1,0})
    across :: proc "contextless" (v,up:[3]f32) -> [3]f32 {return v-up*linalg.dot(v,up)}
    look:=frame*mm.quat_axis_angle({0,1,0},move_input.look_yaw)*mm.quat_axis_angle({1,0,0},move_input.look_pitch)
    walk,walks:=walking.?
    move.yaw=move_input.look_yaw
    traction:=loco.traction_force
    held:=move_input.buttons&input.action_bit(JUMP)!=0
    pressed:=held && !loco.jump_held && walk.jump_height>0
    loco.jump_held=held
    v:=velocity-loco.added
    wish:=move_wish(move_input,frame)
    // Into the water and out of it by the depth of the water over the ground, the same both ways; never in
    // the middle of a move that overrides the locomotion, as climbing out.
    if swim,swims:=swim.?;swims && loco.mode!=MODE_FLYING && !overriding(loco) {
        within:=ground.walkable && ground.ground_distance<=loco.step_height
        deep:=water_depth(loco,ground)>swim.depth
        if loco.mode==MODE_SWIMMING {
            if walks && .In_Fluid not_in ground.fluid {
                loco.mode=MODE_FALLING
            } else if walks && within && !deep {loco.mode=MODE_WALKING}
        } else if .In_Fluid in ground.fluid && deep {loco.mode=MODE_SWIMMING}
    }
    if swim,swims:=swim.?;swims && loco.mode==MODE_SWIMMING {
        loco.jumped,loco.coyote=false,0
        current:=ground.fluid_velocity
        relative:=v-current
        aim:=move_input.move
        if l:=linalg.length(aim);l>1 {aim/=l}
        aim=mm.quat_rotate(look,aim)
        surfaced:=ground.head_depth<=0 && linalg.dot(aim,up)>=0
        flat:=across(relative,up)
        drift:=across(current,up)
        if surfaced {
            move.air={mm.approach_point(flat,across(aim,up)*swim.speed,swim.acceleration*dt)+drift,traction}
            move.flags={.Airborne,.Float}
            move.float_height=swim.surface_offset
            // Out onto a ledge or a raft: a climb, for a jump against the drag of the water takes no one out.
            // It takes the feet to the surface at the speed of a jump, which then takes them jump_height over it.
            if speed:=cmath.sqrt(2*linalg.length(gravity)*walk.jump_height);pressed && speed*dt>0 && loco.move_count<LAYERED_MOVE_CAPACITY {
                loco.moves[loco.move_count]={velocity=up*speed+wish*swim.speed,ticks=max(u32(cmath.ceil(max(ground.depth,0)/(speed*dt))),1),mix=.Override}
                loco.move_count+=1
                loco.mode,loco.jumped=MODE_FALLING,true
            }
        } else if aim!={} {
            move.air={mm.approach_point(relative,aim*swim.speed,swim.acceleration*dt)+current,traction}
            move.flags={.Airborne,.Drive_Vertical}
        } else {
            // Still, what the buoyancy has over the weight, or the weight over it, takes it up or down slowly.
            move.air={mm.approach_point(flat,{},swim.acceleration*dt)+drift,traction}
            move.flags={.Airborne}
        }
    } else if loco.mode==MODE_FLYING {
        loco.jumped,loco.coyote=false,0
        aim:=move_input.move
        if l:=linalg.length(aim);l>1 {aim/=l}
        aim=mm.quat_rotate(look,aim)
        move.air={mm.approach_point(v,aim*fly.speed,fly.acceleration*dt),traction}
        move.flags={.Airborne,.Drive_Vertical,.No_Gravity}
    } else {
        if ground.standing {
            loco.jumped,loco.coyote=false,0
        } else if loco.mode==MODE_WALKING && !loco.jumped {
            loco.coyote=walk.coyote_time
        } else {loco.coyote=max(loco.coyote-dt,0)}
        loco.mode=ground.standing?MODE_WALKING:MODE_FALLING

        n:=ground.ground_normal
        if linalg.dot(n,up)<=0 {n=up}
        desired:[3]f32
        if wish!={} {
            along:=wish-up*(linalg.dot(wish,n)/linalg.dot(n,up))
            desired=along*(walk.max_speed*linalg.length(wish)/linalg.length(along))
        }
        relative:=v-ground.ground_velocity
        current:=relative-n*linalg.dot(relative,n)
        rate:=desired=={}?walk.braking:walk.acceleration
        move.ground={mm.approach_point(current,desired,rate*dt),traction}

        move.air={velocity=across(v,up)}
        if wish!={} && walk.air_control>0 {
            move.air={mm.approach_point(move.air.velocity,wish*walk.max_speed,walk.air_control*walk.acceleration*dt),walk.air_control*traction}
            // Ground too steep to walk is not climbed from the air either.
            if ground.ground_normal!={} && !ground.walkable && ground.ground_distance<=loco.step_height {
                flat:=across(ground.ground_normal,up)
                if into:=linalg.dot(move.air.velocity,flat);into<0 && flat!={} {move.air.velocity-=flat*(into/linalg.dot(flat,flat))}
            }
        }

        if pressed && (ground.standing || loco.coyote>0 && !loco.jumped) {
            base:=linalg.dot(ground.standing?v-ground.ground_velocity:v,up)
            move.launch=up*(cmath.sqrt(2*linalg.length(gravity)*walk.jump_height)-base)
            if ground.standing {move.air={velocity=across(v,up)}}

            loco.mode,loco.jumped,loco.coyote=MODE_FALLING,true,0
        }
    }
    layers_apply(loco,&move,traction,pace)
    return
}

// The layered moves of a locomotion on top of a move, each for pace more
// ticks of its own time. locomotion_step applies them to the move of a mode of
// the game.
layers_apply :: proc(loco:^Character,move:^sim.Character_Move,traction:f32,pace:f32=1) {
    added:[3]f32
    kept:u32
    loco.layer_time+=pace
    spent:=u32(loco.layer_time)
    loco.layer_time-=f32(spent)
    for i in 0..<loco.move_count {
        layered:=loco.moves[i]
        switch layered.mix {
        case .Additive:
            added+=layered.velocity
            if move.ground.force==0 {move.ground.force=traction}
            if move.air.force==0 {move.air.force=traction}
        case .Override:
            added={}
            drive:=sim.Drive{layered.velocity,layered.force>0?layered.force:traction}
            move.ground,move.air=drive,drive
            move.flags+={.Airborne,.Drive_Vertical,.No_Gravity}
            move.flags-={.Float}
        }
        layered.ticks-=min(spent,layered.ticks)
        if layered.ticks>0 {
            loco.moves[kept]=layered
            kept+=1
        }
    }
    for i in kept..<loco.move_count {loco.moves[i]={}}
    loco.move_count=kept
    loco.added=added
    move.ground.velocity+=added
    move.air.velocity+=added
}

// A move of the time of a character in the time of the world, at its pace:
// velocities by it and forces by its square. When its pace changes, a launch
// keeps the velocity it had in its own time (across its up while it stands,
// relative to the ground).
move_paced :: proc "contextless" (move:^sim.Character_Move,loco:^Character,pace:f32,velocity:[3]f32,ground:Character_State,frame:mm.Quat) {
    before:=loco.pace>0?loco.pace:1
    loco.pace=pace
    if pace==1 && before==1 {return}
    felt:=pace*pace
    move.ground.velocity*=pace
    move.ground.force*=felt
    move.air.velocity*=pace
    move.air.force*=felt
    move.launch*=pace
    if pace!=before {
        kept:=(ground.standing?velocity-ground.ground_velocity:velocity)*(pace/before-1)
        if ground.standing {
            up:=mm.quat_rotate(frame,{0,1,0})
            kept-=up*linalg.dot(kept,up)
        }
        move.launch+=kept
    }
    move.pace=pace
}

// The Character_Move of one tick of the world for a character whose time runs
// pace times it (core.pace_of): locomotion_move in its own time, from the
// ground, the velocity and the dt of the world.
locomotion_move_paced :: proc(loco:^Character,walking:Maybe(Walk),fly:Fly,swim:Maybe(Swim),ground:Character_State,frame:mm.Quat,move_input:input.Move_Input,velocity,gravity:[3]f32,dt,pace:f32) -> (move:sim.Character_Move) {
    own:=ground
    own.ground_velocity/=pace
    own.fluid_velocity/=pace
    move=locomotion_move(loco,walking,fly,swim,own,frame,move_input,velocity/(loco.pace>0?loco.pace:1),gravity,dt*pace,pace)
    move_paced(&move,loco,pace,velocity,ground,frame)
    return
}

// Whether a layered move overrides the locomotion now.
@(private)
overriding :: proc "contextless" (loco:^Character) -> bool {
    for layered in loco.moves[:loco.move_count] {if layered.mix==.Override {return true}}
    return false
}

// m of water over the walkable ground in reach of the feet, else over the feet.
@(private)
water_depth :: proc "contextless" (loco:^Character,ground:Character_State) -> f32 {
    if ground.walkable && ground.ground_distance<=loco.step_height {return ground.depth+ground.ground_distance}
    return ground.depth
}

// The component a mode of the engine needs that the entity lacks; "" when it has it or the mode is of a game.
@(private)
mode_missing :: proc(mode:Locomotion_Mode,e:core.Entity,walks:core.Read(Walk),flights:core.Read(Fly),swims:core.Read(Swim)) -> string {
    switch mode {
    case MODE_FALLING,MODE_WALKING: if !core.has(walks,e) {return "Walk"}
    case MODE_FLYING:               if !core.has(flights,e) {return "Fly"}
    case MODE_SWIMMING:             if !core.has(swims,e) {return "Swim"}
    }
    return ""
}

@(private)
mode_label :: proc(mode:Locomotion_Mode) -> string {
    switch mode {
    case MODE_FALLING: return "falling"
    case MODE_WALKING: return "walking"
    case MODE_FLYING:  return "flying"
    case MODE_SWIMMING: return "swimming"
    }
    return "of the game"
}

@(private)
moves_remove :: proc(loco:^Character,id:u32) {
    kept:u32
    for i in 0..<loco.move_count {
        if loco.moves[i].id==id {continue}
        loco.moves[kept]=loco.moves[i]
        kept+=1
    }
    for i in kept..<loco.move_count {loco.moves[i]={}}
    loco.move_count=kept
}
