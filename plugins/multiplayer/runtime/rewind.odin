package multiplayer

import "core:math/linalg"
import "mirai:core"
import mm "mirai:std/math"

// Lag compensation: the server sees the world as a player saw it.
//
// A client shows the others interpolated, Clock.display behind the server:
// half the round trip, twice the jitter and the interpolation delay. What a
// player aims at is where the others were that long ago. Every input a client
// sends carries how far behind its tick it showed them
// (Input_Packet.view_behind, kept in Remote_Input.view as a tick), and the
// server remembers, tick by tick, the pose it published of each entity with
// Rewind. A game that judges an instant hit (a shot, a melee swing) asks
// rewind_tick for the tick that player saw and rewind_pose for where each
// target was then, and judges against that: nothing moves, and the world is
// never put back.

// The ticks a server remembers: more than REWIND_SECONDS at any tick rate up
// to 256 Hz.
REWIND_TICKS :: 128
// The entities with Rewind a tick remembers; the rest of a tick is a problem.
REWIND_ENTITIES :: 64
// How far back a player can be seen by default.
REWIND_SECONDS :: f32(0.5)
// A move longer than this between two ticks is a teleport, metres: the pose
// is not interpolated across it.
REWIND_TELEPORT :: f32(2)

@(component,description="The server remembers its pose of the last ticks, so a hit is judged where the player who aimed saw it (lag compensation).")
Rewind :: struct {}

Rewind_Pose :: struct {
    entity:core.Entity,
    position:[3]f32,
    rotation:mm.Quat,
}

Rewind_Frame :: struct {
    tick:u64, // 0: empty
    count:int,
    poses:[REWIND_ENTITIES]Rewind_Pose,
}

// Server: the poses of the entities with Rewind, a frame per tick in a ring.
// It is of this end: neither copied with the world nor sent.
@(storage,copy=false)
Rewind_History :: struct {
    frames:[REWIND_TICKS]Rewind_Frame,
}

// At the end of a tick, with what the server publishes: the Transform of
// every entity with Rewind, under the number of the tick.
@(step="fixed",loops="game",stage="end",before="net_tick_tail")
rewind_record :: proc(session:core.Ref(Net_Session),time:core.Time,marked:core.Read(Rewind),transforms:core.Read(core.Transform),history:^Rewind_History,problems:^core.Problems) {
    if session.ptr==nil || session.mode!=.Server || time.resimulating {return}
    frame:=&history.frames[time.tick%REWIND_TICKS]
    frame.tick,frame.count=time.tick,0
    for row in 0..<core.count(marked) {
        e:=core.entity_at(marked,row)
        placed,has:=core.get(transforms,e)
        if !has {continue}
        if frame.count==REWIND_ENTITIES {
            core.report(problems,e,"multiplayer.rewind","its pose is not remembered for lag compensation: more than %d entities have Rewind; give it to fewer",REWIND_ENTITIES)
            continue
        }
        frame.poses[frame.count]={e,placed.position,placed.rotation}
        frame.count+=1
    }
}

// Server: the tick, with fraction, that the client of a connection showed the
// others at when it sent the input of the tick being simulated: no later than
// that tick, and no more than max_seconds before it. false without an input
// that says it (a connection that sent none yet, or a lost one).
rewind_tick :: proc(inputs:core.Ref(Remote_Inputs),connection:Connection,time:core.Time,max_seconds:=REWIND_SECONDS) -> (tick:f64,ok:bool) {
    entry:=remote_entry(inputs.ptr,connection)
    if entry==nil || entry.status==.None || entry.view<=0 {return}
    now:=f64(time.tick)
    oldest:=now-(time.dt>0?f64(max_seconds/time.dt):0)
    return clamp(entry.view,max(oldest,0),now),true
}

// Where an entity with Rewind was at a tick with fraction, as the server
// published it: between the poses of the two ticks around it, or the one
// before a teleport. false when the history does not have it then.
rewind_pose :: proc(history:^Rewind_History,e:core.Entity,tick:f64) -> (position:[3]f32,rotation:mm.Quat,ok:bool) {
    if history==nil || tick<0 {return}
    whole:=u64(tick)
    before,has_before:=rewind_find(history,e,whole)
    if !has_before {return}
    after,has_after:=rewind_find(history,e,whole+1)
    fraction:=f32(tick-f64(whole))
    if !has_after || fraction<=0 || linalg.length(after.position-before.position)>REWIND_TELEPORT {
        return before.position,before.rotation,true
    }
    return linalg.lerp(before.position,after.position,fraction),mm.quat_nlerp(before.rotation,after.rotation,fraction),true
}

@(private)
rewind_find :: proc(history:^Rewind_History,e:core.Entity,tick:u64) -> (pose:Rewind_Pose,ok:bool) {
    frame:=&history.frames[tick%REWIND_TICKS]
    if frame.tick!=tick || tick==0 {return}
    for p in frame.poses[:frame.count] {
        if p.entity==e {return p,true}
    }
    return
}
