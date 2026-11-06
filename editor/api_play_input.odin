package editor

import "core:fmt"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:std/base"

// Input actions held for a seat of the game of the caller, by their names and
// never by keys: the seat takes each as one more binding of the action from
// the next tick on, for whole ticks (input.Hold_Requests), so the same calls
// with play.step give the same game whatever the bindings are. Like the
// devices, they are of a seat of the run's own machine: in the run of a
// client they go to the server with the other actions of its seat.

Api_Play_Input_Action :: struct {
    name:[64]u8 `mirai:"text,label=The action by its name as input.get lists it"`,
    value:f32 `mirai:"optional,label=Axis: where it is held; not 0"`,
    vector:[2]f32 `mirai:"optional,label=Axis2: where it is held with x right and y up (forward for a move); not both 0"`,
    ticks:int `mirai:"optional,min=0,max=3600,label=Fixed ticks it is held from the next one on; 0: until it is released"`,
    release:bool `mirai:"optional,label=Lets go of it on the next tick"`,
}

Api_Play_Input_Params :: struct {
    actions:[input.HOLD_CAPACITY]Api_Play_Input_Action `mirai:"optional,label=Held or released: a Button down and an Axis at value and an Axis2 at vector"`,
    release_all:bool `mirai:"optional,label=Lets go of everything the seat holds before the actions"`,
    slot:int `mirai:"optional,min=-1,max=3,label=The local seat by its slot; -1: the one with the focus"`,
    seat:[16]u8 `mirai:"optional,text,label=A local seat by its handle in place of slot"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Input_Result :: struct {
    seat:[16]u8 `mirai:"text,label=The handle of the seat"`,
    tick:u64 `mirai:"label=The tick they act from: the next one the game runs"`,
    queued:int `mirai:"label=Holds and releases asked"`,
}

@(private)
api_play_input_register :: proc(s:^Session,st:^Api_State) {
    defaults:=Api_Play_Input_Params{slot=-1}
    api_register(s,st,{name="play.input",summary="Holds input actions of a seat of the game of the caller by name, as its player would, from the next tick on for some ticks or until released: a Button down and an Axis or Axis2 at a value whatever keys are bound. play.step then runs the ticks.",params=Api_Play_Input_Params,result=Api_Play_Input_Result,defaults=&defaults,run=api_play_input})
}

// The seat of a run a call names by its handle, or the local seat of slot
// (-1: the focused one); false after failing the call. on_client is why a
// method does not take the run of a client; "" when it does.
play_seat :: proc(s:^Session,call:^api.Call,w:core.World_Ref,slot:int,handle:string,on_client:="") -> (seat:core.Entity,ok:bool) {
    seats,state:=core.world_table_of(w,input.Seat),core.world_storage_of(w,input.Seats)
    if seats==nil || state==nil {
        api.call_fail(call,api.INVALID_PARAMS,"This game has no seats: its world does not take engine/input")
        return
    }
    if network:=core.world_storage_of(w,core.Network);on_client!="" && network!=nil && network.role==.Client {
        api.call_fail(call,api.INVALID_PARAMS,on_client)
        return
    }
    if handle!="" {
        e,problem:=api_play_entity(w,handle,0,"seat")
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
        if !core.has(seats,e) {api.call_failf(call,api.INVALID_PARAMS,"seat %s is not a Seat: play.inspect with the component Seat lists the seats",handle);return}
        return e,true
    }
    if state.local_count==0 {
        api.call_fail(call,api.INVALID_PARAMS,"The game has no local seat (a server without players): name a seat by its handle, or play.start with players")
        return
    }
    at:=slot<0?state.focus:slot
    if at>=state.local_count {
        api.call_failf(call,api.INVALID_PARAMS,"slot %d is not a local seat: the game has %d, slots 0 to %d; play.start with players gives it more",slot,state.local_count,state.local_count-1)
        return
    }
    seat=input.local_seat(core.read(seats),at)
    if seat==core.NONE {
        api.call_failf(call,api.INVALID_PARAMS,"The local seat of slot %d is made on the first tick: play.step one tick first",at)
        return
    }
    return seat,true
}

// One fixed tick of the game of the owner of r, as play.step without devices
// runs it: the Play of the user pauses first, and every run of a game on the
// network advances. False when the run ended.
play_tick :: proc(s:^Session,r:^Run) -> bool {
    owner:=r.owner
    if owner==0 && !play_paused(s) {play_pause(s,true,stepped=true)}
    step:=Api_Step_Input{ticks=1}
    api_step_tick(s,owner,0,&step,true)
    return api_frames(s,1,0)>0 && run_find(s,owner)!=nil
}

// What an entry of actions asks of a map, checked; "" or what is wrong.
@(private)
api_play_hold_of :: proc(s:^Session,m:^input.Input_Map,entry:^Api_Play_Input_Action,at:int) -> (action:input.Action,value:[2]f32,problem:string) {
    name:=base.text_get(entry.name[:])
    found,declared:=core.name_value(s.info,input.Action,name)
    if !declared || found<0 || found>=input.ACTION_CAPACITY {
        return 0,{},fmt.tprintf("actions.%d: %q is not an input action: the code declares %s; input.get lists them with their kinds",at,name,input_action_names(s))
    }
    action=input.Action(found)
    if m.declared&input.action_bit(action)==0 {
        return 0,{},fmt.tprintf("actions.%d: %q has no kind in the input map of the game: give it a default in code or a kind with input.set",at,name)
    }
    kind:=m.kinds[action]
    if entry.release {return action,{},""}
    if !rpc_finite(entry.value) || !rpc_finite(entry.vector.x) || !rpc_finite(entry.vector.y) {
        return 0,{},fmt.tprintf("actions.%d: %q takes finite numbers",at,name)
    }
    switch kind {
    case .Button:
        if entry.value!=0 || entry.vector!={} {return 0,{},fmt.tprintf("actions.%d: %q is a Button, held down without value or vector; leave them out",at,name)}
        value={1,0}
    case .Axis:
        if entry.vector!={} || entry.value==0 {return 0,{},fmt.tprintf("actions.%d: %q is an Axis: give value, not 0 (1 is all the way positive), without vector; release lets go",at,name)}
        value={entry.value,0}
    case .Axis2:
        if entry.value!=0 || entry.vector=={} {return 0,{},fmt.tprintf("actions.%d: %q is an Axis2: give vector [x, y], not both 0 (y 1 is all the way forward for a move), without value; release lets go",at,name)}
        value=entry.vector
    }
    return action,value,""
}

@(private)
api_play_input :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Input_Params)
    r,own:=api_play_own_run(s,call,p.player)
    if !own {return}
    if r.owner==0 && simulating(s) {api.call_fail(call,api.INVALID_PARAMS,"A simulation takes no player input");return}
    w:=run_ref(s,r)
    seat,found:=play_seat(s,call,w,p.slot,base.text_get(p.seat[:]))
    if !found {return}
    if value,_:=core.get(core.read(core.world_table_of(w,input.Seat)),seat);!input.seat_local(value) {
        api.call_failf(call,api.INVALID_PARAMS,"seat %s is of a player at another end, which takes the actions its client sends: give play.input the player of that client's run and its local seat",base.text_get(p.seat[:]))
        return
    }
    requests,m:=core.world_storage_of(w,input.Hold_Requests),core.world_storage_of(w,input.Input_Map)
    if requests==nil || m==nil {api.call_fail(call,api.INVALID_PARAMS,"This game has no input actions: its world does not take engine/input");return}
    values:[1]string
    api.object_values(call.allocator,call.raw,{"actions"},values[:])
    count:=api_list_count(values[0])
    if count==0 && !p.release_all {api.call_fail(call,api.INVALID_PARAMS,`give actions, as [{"name": "jump", "ticks": 1}], or release_all`);return}
    holds:[input.HOLD_CAPACITY]input.Hold_Request
    for &entry,i in p.actions[:count] {
        action,value,problem:=api_play_hold_of(s,m,&entry,i)
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
        holds[i]={seat=seat,action=action,value=value,ticks=u32(entry.ticks)}
    }
    queued:=0
    if p.release_all {
        source,_:=core.get(core.read(core.world_table_of(w,input.Seat)),seat)
        for hold in source.holds[:source.hold_count] {input.let_go(requests,seat,hold.action);queued+=1}
        for i in 0..<len(requests.queue.items) {
            asked:=requests.queue.items[i]
            if asked.seat==seat && asked.value!={} {input.let_go(requests,seat,asked.action);queued+=1}
        }
    }
    for h in holds[:count] {core.push(&requests.queue,h)}
    queued+=count
    result:=api.call_result(call,Api_Play_Input_Result)
    api_handle_put(result.seat[:],seat)
    if t:=core.world_storage_of(w,core.Time);t!=nil {result.tick=t.tick}
    result.queued=queued
}
