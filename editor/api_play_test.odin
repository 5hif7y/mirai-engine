package editor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") Probe_Health :: struct {points:f32,target:core.Entity}
@(private="file") Probe_State :: enum u8 {Waiting,Playing,Won}
@(private="file") Probe_Score :: struct {points:int,state:Probe_State}
@(private="file") Probe_Ping :: struct {entity:core.Entity,amount:int}
@(private="file") Probe_Pings :: struct {queue:core.Queue(Probe_Ping)}
@(private="file") PROBE_MOVE :: input.Action(0)
@(private="file") PROBE_JUMP :: input.Action(2)

// A game whose tick adds a point to its score, and what its pings push.
@(private="file")
Probe_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    health:core.Table(Probe_Health),
    seats:core.Table(input.Seat),
    players:input.Seats,
    bindings:input.Input_Map,
    holds:input.Hold_Requests,
    time:core.Time,
    frame:core.Frame_Time,
    input:core.Input,
    places:core.Places,
    jumps:core.Jumps,
    score:Probe_Score,
    pings:Probe_Pings,
}
@(private="file") Probe_Editor :: struct {api:Api}

@(private="file")
probe_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Probe_World)data
    w^={}
    core.entities_init(&w.entities,allocator)
    core.table_init(&w.ids,"Id",allocator);core.table_init(&w.names,"Name",allocator)
    core.table_init(&w.transforms,"Transform",allocator);core.table_init(&w.parents,"Parent",allocator)
    core.table_init(&w.health,"Probe_Health",allocator)
    core.table_init(&w.seats,"Seat",allocator)
    w.holds.queue.items=make([dynamic]input.Hold_Request,allocator)
    w.places.queue.items=make([dynamic]core.Place_Request,allocator)
    w.jumps.queue.items=make([dynamic]core.Jump,allocator)
    w.pings.queue.items=make([dynamic]Probe_Ping,allocator)
    return true
}

@(private="file")
probe_free :: proc(data:rawptr) {
    w:=cast(^Probe_World)data
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents);core.table_destroy(&w.health);core.table_destroy(&w.seats)
    delete(w.holds.queue.items)
    delete(w.places.queue.items);delete(w.jumps.queue.items);delete(w.pings.queue.items)
    core.entities_destroy(&w.entities)
}

@(private="file")
probe_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Probe_World)dst,cast(^Probe_World)src
    if !core.entities_copy(&d.entities,&s.entities) || !core.table_copy(&d.ids,&s.ids) || !core.table_copy(&d.names,&s.names) || !core.table_copy(&d.transforms,&s.transforms) || !core.table_copy(&d.parents,&s.parents) || !core.table_copy(&d.health,&s.health) || !core.table_copy(&d.seats,&s.seats) {return false}
    d.time,d.input,d.score=s.time,s.input,s.score
    d.players,d.bindings=s.players,s.bindings
    return true
}

@(private="file")
probe_settle :: proc(data,shared,editor:rawptr) {
    w:=cast(^Probe_World)data
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities)
    core.table_settle(&w.transforms,&w.entities);core.table_settle(&w.parents,&w.entities)
    core.table_settle(&w.health,&w.entities);core.table_settle(&w.seats,&w.entities)
    core.entities_settle(&w.entities)
}

// The seats take their holds and no device, as engine/input runs them.
@(private="file")
probe_tick :: proc(data,shared,editor,app:rawptr) {
    w:=cast(^Probe_World)data
    input.input_holds(&w.seats,&w.holds,w.time,nil)
    for row in 0..<core.count(&w.seats) {
        device:core.Input
        input.seat_feed(core.at(&w.seats,row),&device,&w.bindings,false)
    }
    w.score.points+=1
    for ping in core.take(&w.pings.queue) {w.score.points+=ping.amount}
    if w.score.points>=10 {w.score.state=.Won}
}

@(private="file")
Probe :: struct {
    p:^platform.Platform,
    tables:[6]core.Table_Info,
    storages:[11]core.Storage_Info,
    names:[2]core.Name_Info,
    info:core.World_Info,
    app:host.App,
    data:rawptr,
    hero,foe,seat:core.Entity,
    edits:Edits,
    selection:Selection,
    viewport:Viewport,
    gui:Editor_Ui,
    document:Document,
    editor:Probe_Editor,
    s:Session,
    out:serial.Writer,
}

@(private="file")
probe_open :: proc(t:^testing.T,f:^Probe) -> bool {
    error:platform.Error
    f.p,error=platform.create({headless=true,fixed_dt=0.1,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) || f.p==nil {return false}
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Probe_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Probe_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Probe_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Probe_World,parents)},
        {name="Probe_Health",type=Probe_Health,info=type_info_of(Probe_Health),offset=offset_of(Probe_World,health),game=true},
        {name="Seat",type=input.Seat,info=type_info_of(input.Seat),offset=offset_of(Probe_World,seats)},
    }
    f.storages={
        {type=Api,info=type_info_of(Api),place=.Editor},
        {name="Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Probe_World,time)},
        {name="Input",type=core.Input,info=type_info_of(core.Input),offset=offset_of(Probe_World,input)},
        {name="Frame_Time",type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Probe_World,frame)},
        {name="Places",type=core.Places,info=type_info_of(core.Places),offset=offset_of(Probe_World,places)},
        {name="Jumps",type=core.Jumps,info=type_info_of(core.Jumps),offset=offset_of(Probe_World,jumps)},
        {name="Probe_Score",type=Probe_Score,info=type_info_of(Probe_Score),offset=offset_of(Probe_World,score)},
        {name="Probe_Pings",type=Probe_Pings,info=type_info_of(Probe_Pings),offset=offset_of(Probe_World,pings)},
        {name="Seats",type=input.Seats,info=type_info_of(input.Seats),offset=offset_of(Probe_World,players)},
        {name="Input_Map",type=input.Input_Map,info=type_info_of(input.Input_Map),offset=offset_of(Probe_World,bindings)},
        {name="Hold_Requests",type=input.Hold_Requests,info=type_info_of(input.Hold_Requests),offset=offset_of(Probe_World,holds)},
    }
    f.names={{type=input.Action,value=i64(PROBE_MOVE),name="move"},{type=input.Action,value=i64(PROBE_JUMP),name="jump"}}
    f.info={tables=f.tables[:],storages=f.storages[:],names=f.names[:],copy=probe_copy,settle=probe_settle,entities=offset_of(Probe_World,entities)}
    f.info.sizes[.World],f.info.aligns[.World]=size_of(Probe_World),align_of(Probe_World)
    f.info.init[.World],f.info.destroy[.World]=probe_init,probe_free
    f.info.loops[.Game][.Fixed]=probe_tick
    f.app={info=&f.info,platform=f.p,allocator=context.allocator,tick_dt=1.0/60,max_ticks=8}
    f.data=host.app_world_create(&f.app)
    world:=cast(^Probe_World)f.data
    f.hero,f.foe=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.ids,f.hero,core.Id{1});core.add(&world.ids,f.foe,core.Id{2})
    core.add(&world.names,f.hero,core.name_make("Hero"));core.add(&world.names,f.foe,core.name_make("Foe"))
    core.add(&world.transforms,f.hero,core.Transform{{1,0,0},1,{1,1,1}})
    core.add(&world.transforms,f.foe,core.Transform{{5,0,0},1,{1,1,1}})
    core.add(&world.health,f.hero,Probe_Health{points=3})
    f.seat=core.create(&world.entities)
    core.add(&world.seats,f.seat,input.Seat{})
    world.players.local_count=1
    input.input_map_action(&world.bindings,PROBE_MOVE,.Axis2)
    input.input_map_action(&world.bindings,PROBE_JUMP,.Button)
    input.input_map_bind(&world.bindings,PROBE_JUMP,input.binding_key(.Space))
    probe_settle(f.data,nil,nil)
    f.viewport={orbit=ORBIT_DEFAULT}
    f.gui={layout={left_open=true,right_open=true,library_tab=.Content,bottom_open=true}}
    f.s={app=&f.app,info=&f.info,edit_world=f.data,editor_world=&f.editor,edits=&f.edits,selection=&f.selection,viewport=&f.viewport,gui=&f.gui,document=&f.document}
    edits_reset(&f.edits,edited_world(&f.s))
    f.document.saved=edits_state(&f.edits)
    if !testing.expect(t,api_open(&f.s,0,true)==.None) {return false}
    api_state(&f.s).poll_temp=context.temp_allocator
    serial.writer_init(&f.out)
    return testing.expect(t,play_start(&f.s))
}

@(private="file")
probe_close :: proc(f:^Probe) {
    serial.writer_destroy(&f.out)
    runs_stop(&f.s)
    api_close(&f.s)
    edits_free(&f.edits)
    delete(f.selection.entities)
    delete(f.s.edit_selection.entities)
    host.app_world_free(&f.app,f.data)
    delete(f.app.worlds)
    platform.destroy(f.p)
}

@(private="file")
probe_call :: proc(f:^Probe,name,params:string) -> (error:api.Error,text:string) {
    st:=api_state(&f.s)
    base.arena_reset(&st.server.scratch);serial.writer_reset(&f.out)
    error,_=api.method_execute(&st.server,api.method_find(&st.server,name),params,&f.out)
    return error,string(serial.writer_bytes(&f.out))
}

@(test)
the_game_that_plays_is_changed_and_read_by_its_storages_and_conditions :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    running:=cast(^Probe_World)run_find(&f.s,0).world
    hero:=fmt.tprintf("%016x",u64(f.hero))
    // Storages of the game, by name.
    error,text:=probe_call(f,"play.inspect",`{"storage":"Probe_*","limit":1}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"storages":{"Probe_Score":{"points": 0, "state": "Waiting"}`),text)
    error,_=probe_call(f,"play.inspect",`{"storage":"Score"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    // A component and a teleport, without the document.
    error,text=probe_call(f,"play.set",strings.concatenate({`{"entity":"`,hero,`","position":[4,5,6],"components":{"Probe_Health":{"target":"`,fmt.tprintf("%016x",u64(f.foe)),`"}}}`},context.temp_allocator))
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,`"teleported": true`),text)
    health,_:=core.get(core.read(&running.health),f.hero)
    testing.expect_value(t,health,Probe_Health{points=3,target=f.foe})
    testing.expect_value(t,entity_world(run_ref(&f.s,run_find(&f.s,0)),f.hero).position,[3]f32{4,5,6})
    testing.expect_value(t,len(running.jumps.queue.items),1)
    testing.expect_value(t,entity_local(edited_world(&f.s),f.hero).position,[3]f32{1,0,0})
    // A failure changes nothing.
    error,_=probe_call(f,"play.set",strings.concatenate({`{"entity":"`,hero,`","position":[9,9,9],"components":{"Probe_Health":{"points":"many"}}}`},context.temp_allocator))
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect_value(t,entity_world(run_ref(&f.s,run_find(&f.s,0)),f.hero).position,[3]f32{4,5,6})
    error,_=probe_call(f,"play.set",`{"entity":"00000000000000ff","position":[0,0,0]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    // Requests pushed to a queue, read by the next tick.
    error,text=probe_call(f,"play.push",strings.concatenate({`{"storage":"Probe_Pings","items":[{"entity":"`,hero,`","amount":4},{"amount":2}]}`},context.temp_allocator))
    testing.expect_value(t,error.code,0)
    testing.expect_value(t,len(running.pings.queue.items),2)
    error,_=probe_call(f,"play.push",`{"storage":"Probe_Score","items":[{}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    probe_tick(running,nil,nil,nil)
    testing.expect_value(t,running.score.points,7)
    // Conditions, as assertions.
    error,text=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"points","compare":"At_Least","number":7},{"name":"Hero","component":"Probe_Health","field":"points","compare":"Below","number":3},{"name":"Hero","field":"world_position.1","compare":"Equal","number":5},{"storage":"Probe_Score","field":"state","compare":"Equal","text":"Waiting"},{"name":"Nobody","compare":"Gone"}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.has_prefix(text,`{"passed":false`),text)
    testing.expect(t,strings.contains(text,`"results":[{"passed":true,"value":7},{"passed":false,"value":3},{"passed":true,"value":5},{"passed":true,"value":"Waiting"},{"passed":true,"value":null}]`),text)
    error,_=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"lives","compare":"Equal","number":1}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,"points, state") || strings.contains(error.message,"state, points"),error.message)
    error,_=probe_call(f,"play.check",`{"conditions":[{"storage":"Probe_Score","field":"state","compare":"Below","text":"Won"}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

@(test)
a_step_gives_the_run_the_pointer_the_gamepads_and_the_text_of_its_ui :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    r:=run_find(&f.s,0)
    params:=Api_Play_Step_Params{ticks=1,keys={.Enter},mouse_buttons={.Left},mouse_position={120,80},focus=-1}
    step:Api_Step_Input
    step.placed=true
    step.text="go"
    step.gamepads[1]={connected=true,down={.South}}
    step.gamepads[1].axes[.Left_X]=0.5
    play_pause(&f.s,true)
    api_step_tick(&f.s,0,&params,step,true)
    testing.expect(t,r.pointer_set && r.pointer==[2]f32{120,80})
    testing.expect(t,.Left in r.ui.pressed && r.ui.clicks==1 && r.ui.pointer==[2]f32{120,80})
    testing.expect_value(t,string(r.ui.text[:r.ui.text_count]),"go")
    platform.frame_begin(f.p)
    play_input_update(&f.s)
    game_frame(&f.s)
    running:=cast(^Probe_World)r.world
    testing.expect_value(t,running.input.mouse_position,[2]f32{120,80})
    testing.expect(t,running.input.gamepads[1].connected && .South in running.input.gamepads[1].pressed)
    testing.expect_value(t,running.input.gamepads[1].axes[.Left_X],f32(0.5))
    testing.expect(t,running.input.device.gamepad && running.input.device.slot==1 || .Enter in running.input.keys_pressed)
    testing.expect(t,r.ui.pressed=={} && r.ui.text_count==0 && .Left in r.ui.down,"the edges of the UI last one tick")
    // The next step holds what it held: no edges.
    api_step_tick(&f.s,0,&params,{gamepads=step.gamepads},false)
    testing.expect(t,r.ui.pressed=={} && r.pointer==[2]f32{120,80})
    testing.expect(t,.South not_in r.input.gamepads[1].pressed && .South in r.input.gamepads[1].down)
    // Run until a condition: met before running runs nothing.
    error,_:=probe_call(f,"play.step",`{"until":[{"storage":"Probe_Score","field":"points","compare":"At_Least","number":0}]}`)
    testing.expect_value(t,error.code,0)
    error,_=probe_call(f,"play.step",`{"until":[{"storage":"Probe_Score","field":"nothing"}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    error,_=probe_call(f,"play.step",`{"gamepads":[{"slot":1},{"slot":1}]}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    error,_=probe_call(f,"play.step",`{"text":"tab\t"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
}

// Actions held by name reach the seat from the next tick play.step runs, for
// their ticks or until released; what does not fit the action or the seat is
// refused with what to give instead, and changes nothing.
@(test)
play_input_holds_actions_of_a_seat_by_name_for_the_ticks_that_run :: proc(t:^testing.T) {
    f:=new(Probe);defer free(f)
    if !probe_open(t,f) {return}
    defer probe_close(f)
    running:=cast(^Probe_World)run_find(&f.s,0).world
    read:=core.read(&running.seats)
    // One tick as play.step runs it, without the frame of a window.
    step :: proc(f:^Probe) {
        params:=Api_Play_Step_Params{ticks=1,focus=-1}
        api_step_tick(&f.s,0,&params,{},true)
        platform.frame_begin(f.p)
        play_input_update(&f.s)
        game_frame(&f.s)
    }
    play_pause(&f.s,true)
    refused:=[?]struct{params,says:string}{
        {`{"actions":[{"name":"jmp"}]}`,"move, jump"},
        {`{"actions":[{"name":"jump","value":1}]}`,"Button"},
        {`{"actions":[{"name":"move","value":1}]}`,"Axis2"},
        {`{"actions":[{"name":"move","vector":[0,0]}]}`,"not both 0"},
        {`{"actions":[{"name":"jump"}],"slot":2}`,"slot 2"},
        {`{"actions":[{"name":"jump"}],"seat":"00000000000000ff"}`,"not alive"},
        {`{}`,"release_all"},
    }
    for c in refused {
        error,_:=probe_call(f,"play.input",c.params)
        testing.expectf(t,error.code==api.INVALID_PARAMS && strings.contains(error.message,c.says),"%s: %v",c.params,error)
    }
    testing.expect_value(t,len(running.holds.queue.items),0)
    error,text:=probe_call(f,"play.input",`{"actions":[{"name":"jump","ticks":1},{"name":"move","vector":[0,1]}]}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,strings.contains(text,fmt.tprintf(`"%016x"`,u64(f.seat))) && strings.contains(text,`"queued": 2`),text)
    testing.expect(t,!input.seat_down(read,f.seat,PROBE_JUMP),"nothing acts before the next tick")
    step(f)
    testing.expect(t,input.seat_pressed(read,f.seat,PROBE_JUMP))
    testing.expect_value(t,input.seat_vector(read,f.seat,PROBE_MOVE),[2]f32{0,1})
    step(f)
    testing.expect(t,input.seat_released(read,f.seat,PROBE_JUMP) && input.seat_down(read,f.seat,PROBE_MOVE),"jump for one tick, move until released")
    error,_=probe_call(f,"play.input",`{"release_all":true}`)
    testing.expect_value(t,error.code,0)
    step(f)
    testing.expect(t,input.seat_released(read,f.seat,PROBE_MOVE))
}
