package animation_physics

import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// Locomotion animated by the physics. Every tick, each Character with an Animation tells its
// motion matching (a .match in Animation.asset) what its body did in the simulation of this tick:
// the mode its locomotion is in, of which the Character is the only writer, the velocity of the
// body, the velocity its Move_Input asks of that mode at the acceleration of the mode, where it
// turns (toward its move, or where it looks when it moves relative to its look), the wall it
// leans on, which its trajectory does not go into, and when it lands while it falls. While it
// walks a clip of matching, the warping of its Animation.motion stretches the stride to the speed
// of the root of its pose. A game writes no code for locomotion; the clips and their modes are in
// the .match.
@(step="fixed",before="animation_sample")
animation_locomotion :: proc(characters:core.Read(phys.Character),found:core.Read(phys.Character_State),animations:core.Read(anim.Animation),motions:core.Read(core.Motion),inputs:core.Read(inp.Move_Input),walks:core.Read(phys.Walk),flights:core.Read(phys.Fly),swims:core.Read(phys.Swim),worlds:core.Read(core.World_Transform),playback:core.Ref(anim.Playback),requests:^anim.Animation_Requests,warps:^anim.Motion_Requests,problems:^core.Problems) {
    for row in 0..<core.count(characters) {
        entity:=core.entity_at(characters,row)
        animation,animated:=core.get(animations,entity)
        if !animated || animation.asset=={} {continue}
        character:=core.at(characters,row)
        going,_:=core.get(motions,entity)
        input,_:=core.get(inputs,entity)
        placed,_:=core.get(worlds,entity)
        wish:=phys.move_wish(input,mm.QUAT_IDENTITY)
        facing:=mm.quat_rotate(placed.rotation,mm.Vec3{0,0,1}) if character.move_relative_to==.Look else wish
        state,_:=core.get(found,entity)
        goal:=anim.Match_Goal{rig=entity,mode=u16(character.mode),velocity=going.linear,facing=facing,wall=state.wall_normal,turn_rate=character.turn_speed,time_to_land=state.land_time}
        switch character.mode {
        case phys.MODE_SWIMMING:
            if swim,ok:=core.get(swims,entity);ok {goal.desired,goal.acceleration,goal.braking=wish*swim.speed,swim.acceleration,swim.acceleration}
        case phys.MODE_FLYING:
            if fly,ok:=core.get(flights,entity);ok {goal.desired,goal.acceleration,goal.braking=wish*fly.speed,fly.acceleration,fly.acceleration}
        case:
            if walk,ok:=core.get(walks,entity);ok {goal.desired,goal.acceleration,goal.braking=wish*walk.max_speed,walk.acceleration,walk.braking}
        }
        if !anim.match_goal(requests,goal) {
            core.report(problems,entity,"animation.match_goal","the locomotion of this Character was not told to its motion matching: a value of its body is not finite, its mode is past 31, or more than %d characters animate in one tick; fix its Character, or animate fewer of them",anim.MATCH_GOAL_CAPACITY)
            continue
        }
        if animation.motion=={} {continue}
        playing,matching:=anim.animation_match(playback.ptr,entity)
        if !matching {continue}
        anim.motion_locomotion(warps,{rig=entity,velocity={playing.velocity.x,0,playing.velocity.z},source_velocity=mm.quat_rotate(placed.rotation,mm.Vec3{0,0,playing.speed}),weight=1,enabled=character.mode==phys.MODE_WALKING && !playing.forced && playing.speed>0})
    }
}
