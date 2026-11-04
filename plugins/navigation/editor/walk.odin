package navigation_editor

import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:std/base"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// play.walk: the body a seat drives walks to a point through the meshes of
// navigation, as a seated Nav_Agent whose steering writes its Move_Input each
// fixed tick, with the seat's buttons. It runs the ticks itself, as play.step
// does, so the same call on the same game gives the same walk.

WALK_STUCK_SECONDS :: 2   // s of game time moving less than WALK_STUCK_DISTANCE: stuck
WALK_STUCK_DISTANCE :: 0.25 // m

Walk_Params :: struct {
    to:[3]f32 `mirai:"optional,unit=m,label=Where it walks in the world; give to or target"`,
    target:base.Entity_Id `mirai:"optional,label=An entity of the scene it walks to instead: where it is when the walk starts"`,
    ticks:int `mirai:"optional,min=1,max=3600,label=Fixed ticks it walks at most before Timeout"`,
    reach:f32 `mirai:"optional,min=0,unit=m,label=How near the end counts as there; 0: as its Nav_Agent"`,
    slot:int `mirai:"optional,min=-1,max=3,label=The local seat by its slot; -1: the one with the focus"`,
    seat:[16]u8 `mirai:"optional,text,label=A seat by its handle in place of slot"`,
}

Walk_State :: enum u8 {
    Arrived, // at the end or as near as the meshes go (partial)
    Failed,  // navigation found no way: engine.diagnostics says why
    Stuck,   // moving it did not get anywhere for WALK_STUCK_SECONDS
    Timeout, // the ticks ran out first
    Stopped, // the game stopped it
}

Walk_Result :: struct {
    state:Walk_State `mirai:"label=How the walk ended"`,
    ran:int `mirai:"label=Fixed ticks it walked"`,
    tick:u64 `mirai:"label=The tick of the game it ended at"`,
    body:[16]u8 `mirai:"text,label=The handle of the body that walked"`,
    position:[3]f32 `mirai:"unit=m,label=Where the body ended in the world"`,
    distance:f32 `mirai:"unit=m,label=From there to the end"`,
    partial:bool `mirai:"label=The way ends as near the end as the meshes go"`,
}

// How far a walk got, to tell a stuck one.
Walk_Watch :: struct {
    anchor:[3]f32,
    since:f64,
    started:bool,
}

// How a walk ended after a tick in which its agent was in state at position;
// done false while it goes on.
walk_watch :: proc(w:^Walk_Watch,state:nav.Nav_State,position:[3]f32,seconds:f64) -> (ended:Walk_State,done:bool) {
    switch state {
    case .Arrived: return .Arrived,true
    case .Failed:  return .Failed,true
    case .Idle:    return .Stopped,true
    case .Moving:
        if w.started && linalg.length(position-w.anchor)<WALK_STUCK_DISTANCE {
            if seconds-w.since>=WALK_STUCK_SECONDS {return .Stuck,true}
            return
        }
        w.anchor,w.since,w.started=position,seconds,true
    case .Waiting,.Crossing:
        // A search does not move it, and a crossing moves it by itself.
        w.anchor,w.since,w.started=position,seconds,true
    }
    return
}

@(private)
walk :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Walk_Params)
    r,own:=editor.api_play_run(s,call)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    if !own {editor.api_play_refused(call);return}
    if r.owner==0 && editor.simulating(s) {api.call_fail(call,api.INVALID_PARAMS,"A simulation has no players: play.start without simulate");return}
    w:=editor.run_ref(s,r)
    seat,found:=editor.play_seat(s,call,w,p.slot,base.text_get(p.seat[:]),"This run is a client, which sends the server the actions of its seat and not the Move_Input that walking writes: walk the seat of that player in the run of the server (player 0) by its handle")
    if !found {return}
    requests,n:=core.world_storage_of(w,nav.Nav_Requests),core.world_storage_of(w,nav.Navigation)
    agents,paths:=core.world_table_of(w,nav.Nav_Agent),core.world_table_of(w,nav.Nav_Path)
    drivables,characters:=core.world_table_of(w,input.Drivable),core.world_table_of(w,phys.Character)
    worlds:=core.world_table_of(w,core.World_Transform)
    if requests==nil || n==nil || agents==nil || paths==nil || characters==nil || worlds==nil {
        api.call_fail(call,api.INVALID_PARAMS,"This game has no navigation: activate the plugin navigation in project.mirai")
        return
    }
    body:=drivables!=nil?input.body_of(core.read(drivables),seat):core.NONE
    if body==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"Seat %016x drives no body: play.step until it has one, or play.push a Drive to Seat_Requests",u64(seat));return}
    if !core.has(characters,body) {api.call_failf(call,api.INVALID_PARAMS,"Body %016x has no Character: only a Character walks",u64(body));return}
    values:[1]string
    api.object_values(call.allocator,call.raw,{"to"},values[:])
    goal:=p.to
    switch {
    case p.target!=0 && values[0]!="":
        api.call_fail(call,api.INVALID_PARAMS,"give to or target, not both");return
    case p.target!=0:
        e:=core.entity_of(core.world_entities(w),p.target)
        pose,placed:=core.get(core.read(worlds),e)
        if !placed {api.call_failf(call,api.INVALID_PARAMS,"target %016x is not an entity of the game with a place: play.inspect lists them",u64(p.target));return}
        goal=pose.position
    case values[0]=="":
        api.call_fail(call,api.INVALID_PARAMS,"give to (a point of the world) or target (an entity)");return
    }
    if !n.ready || n.count==0 {api.call_fail(call,api.INVALID_PARAMS,"The navigation meshes are not made yet: play.step until nav.status says ready");return}

    // A seated agent for the walk; what the body was before comes back after.
    added:=!core.has(agents,body)
    before:=nav.NAV_AGENT_DEFAULT
    if !added {before=core.get(agents,body)^}
    agent:=before
    agent.seated=true
    if p.reach>0 {agent.reach=p.reach}
    if added {core.add(agents,body,agent)} else {core.get(agents,body)^=agent}
    core.world_settle(w)
    nav.nav_move_to(requests,body,goal)

    watch:Walk_Watch
    state:=Walk_State.Timeout
    ran:=0
    path:nav.Nav_Path
    for ran<p.ticks {
        if !editor.play_tick(s,r) {api.call_failf(call,api.SERVER_ERROR,"The game ended after %d ticks of the walk",ran+1);return}
        ran+=1
        w=editor.run_ref(s,r)
        path,_=core.get(core.read(core.world_table_of(w,nav.Nav_Path)),body)
        pose,_:=core.get(core.read(core.world_table_of(w,core.World_Transform)),body)
        seconds:f64
        if t:=core.world_storage_of(w,core.Time);t!=nil {seconds=t.seconds}
        if ended,done:=walk_watch(&watch,path.state,pose.position,seconds);done {state=ended;break}
    }

    agents,paths,requests=core.world_table_of(w,nav.Nav_Agent),core.world_table_of(w,nav.Nav_Path),core.world_storage_of(w,nav.Nav_Requests)
    if added && path.state!=.Crossing {
        core.remove(agents,body)
        core.remove(paths,body)
        core.world_settle(w)
    } else {
        if !added {core.get(agents,body)^=before}
        nav.nav_stop(requests,body)
    }
    result:=api.call_result(call,Walk_Result)
    result.state,result.ran,result.partial=state,ran,path.partial
    if t:=core.world_storage_of(w,core.Time);t!=nil {result.tick=t.tick}
    copy(result.body[:],fmt.tprintf("%016x",u64(body)))
    pose,_:=core.get(core.read(core.world_table_of(w,core.World_Transform)),body)
    result.position=pose.position
    result.distance=linalg.length(goal-pose.position)
}
