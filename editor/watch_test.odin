package editor

import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import mm "mirai:std/math"

// A game loop that counts its ticks and adds a layer of UI to the frame, as a game with a HUD does.
watch_test_tick :: proc(data,shared,editor,app:rawptr) {
    (cast(^Play_Test_World)data).ticks+=1
    (cast(^host.App)app).extras.layer_count+=1
}

@(test)
an_agent_run_is_watched_without_input_or_edits_while_the_game_of_the_user_goes_on :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s,app,gui,selection,original:=&f.s,&f.app,&f.gui,&f.selection,f.original
    f.info.loops[.Game][.Fixed]=watch_test_tick
    layout:=gui.layout
    selection_set(selection,{original})
    testing.expect(t,!watch_start(s,7,false),"a task without a run has nothing to show")
    testing.expect(t,play_start(s,false,7) && play_start(s))
    agent,user:=run_find(s,7),run_find(s,0)
    a,u:=cast(^Play_Test_World)agent.world,cast(^Play_Test_World)user.world
    // From the Play of the user: the run of the agent is shown, the game of the user goes on unseen.
    testing.expect(t,watch_start(s,7,false))
    testing.expect(t,s.mode==.Watch && s.watch.from==.Play && shown_world(s).data==agent.world)
    platform.input_inject(f.p,platform.Key_Event{key=.W,down=true})
    platform.frame_begin(f.p)
    testing.expect(t,.W in platform.input_frame(f.p).keys_down)
    play_input_update(s)
    testing.expect(t,app.game_input_blocked)
    app.extras.layer_count=0
    game_frame(s)
    testing.expect(t,u.ticks>0 && .W not_in u.input.keys_down,"the game of the user goes on without the input of the window")
    testing.expect_value(t,a.ticks,0)
    testing.expect_value(t,app.extras.layer_count,0)
    // The agent steps its run: what it draws is the frame now.
    agent.step=true
    platform.frame_begin(f.p)
    game_frame(s)
    testing.expect_value(t,a.ticks,1)
    testing.expect_value(t,app.extras.layer_count,1)
    // What is watched is not edited.
    before:=core.get(&a.transforms,original)^
    testing.expect(t,!transform_set(s,original,mm.Transform{position={9,9,9},rotation=1,scale=1}))
    testing.expect(t,entity_create(s,{})==core.NONE)
    testing.expect(t,action_state(s,.Duplicate).disabled && action_state(s,.Pause).disabled)
    testing.expect_value(t,core.get(&a.transforms,original)^,before)
    testing.expect_value(t,a.entities.alive,1)
    // Stop returns to the game of the user.
    testing.expect(t,action_run(s,.Stop))
    requests_run(s)
    testing.expect(t,s.mode==.Play && shown_world(s).data==user.world && run_find(s,0)==user)
    // The game of the user ends while the agent is watched: the watch returns to Edit.
    testing.expect(t,watch_start(s,7,false))
    play_stop(s,true)
    testing.expect(t,s.mode==.Watch && run_find(s,0)==nil && shown_world(s).data==agent.world)
    watch_stop(s)
    testing.expect(t,s.mode==.Edit && shown_world(s).data==f.data)
    testing.expect_value(t,gui.layout,layout)
    testing.expect_value(t,selection_active(selection),original)
    // From Edit, the selection of the document comes back when the run ends.
    testing.expect(t,watch_start(s,7,false))
    testing.expect(t,s.watch.from==.Edit && len(selection.entities)==0)
    run_stop(s,7)
    watch_update(s)
    testing.expect(t,s.mode==.Edit && shown_world(s).data==f.data)
    testing.expect_value(t,selection_active(selection),original)
}

@(test)
the_play_of_the_host_travels_by_entity_and_entities_without_rows_go :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s,original:=&f.s,f.original
    st:=new(Collab_State);defer free(st)
    collab_tables_build(s,st)
    defer collab_tables_free(st)
    defer {collab_watch_drop(s,st);delete(st.watch.entities);delete(st.watch.rows)}
    testing.expect(t,play_start(s))
    run:=cast(^Play_Test_World)run_find(s,0).world
    w:=core.world_ref(run,s.info)
    // What the game creates has no Id: it travels by its entity, with its parent.
    spawned:=core.create(&run.entities)
    core.add(&run.transforms,spawned,core.Transform{{0,2,0},1,{1,1,1}})
    core.add(&run.parents,spawned,core.Parent{entity=original})
    core.world_settle(w)
    send :: proc(st:^Collab_State,w:core.World_Ref) -> [][]u8 {
        ops:Collab_Ops
        collab_ops_begin(&ops)
        collab_watch_diff(st,w,st.watch.seen,&ops)
        return collab_ops_pack(&ops,.Watch_Rows,0)
    }
    st.watch.asked=true
    collab_watch_begin(s,st)
    testing.expect(t,st.watch.world!=nil)
    first:Collab_Ops
    collab_ops_begin(&first)
    testing.expect(t,!collab_watch_diff(st,w,st.watch.seen,&first),"a run never sent starts whole")
    all:Collab_Ops
    collab_ops_begin(&all)
    collab_watch_all(st,w,&all)
    for message in collab_ops_pack(&all,.Watch_Rows,0) {collab_watch_apply(s,st,message)}
    guest:=cast(^Play_Test_World)st.watch.world
    testing.expect_value(t,guest.entities.alive,2)
    copy_of:=st.watch.entities[base.Entity_Id(u64(spawned))]
    root:=st.watch.entities[base.Entity_Id(u64(original))]
    testing.expect_value(t,core.get(&guest.parents,copy_of).entity,root)
    testing.expect_value(t,core.get(&guest.transforms,copy_of).position,[3]f32{0,2,0})
    testing.expect_value(t,core.get(&guest.ids,root).value,base.Entity_Id(1))
    // Then only what changed; an entity that loses its rows goes.
    core.get(&run.transforms,original).position.x=4
    core.destroy(&run.entities,spawned)
    core.world_settle(w)
    changed:=send(st,w)
    testing.expect_value(t,len(changed),1)
    for message in changed {collab_watch_apply(s,st,message)}
    testing.expect_value(t,guest.entities.alive,1)
    testing.expect_value(t,core.get(&guest.transforms,root).position.x,f32(4))
    testing.expect(t,base.Entity_Id(u64(spawned)) not_in st.watch.entities)
    testing.expect_value(t,len(send(st,w)),0)
    // A component turned off and on again travels as turns.
    child:=core.create(&run.entities)
    core.add(&run.transforms,child,core.TRANSFORM_IDENTITY)
    core.add(&run.parents,child,core.Parent{entity=original})
    core.world_settle(w)
    for message in send(st,w) {collab_watch_apply(s,st,message)}
    copy_child:=st.watch.entities[base.Entity_Id(u64(child))]
    core.disable(&run.parents,child)
    core.world_settle(w)
    for message in send(st,w) {collab_watch_apply(s,st,message)}
    _,off,found:=core.raw_state(core.raw(&guest.parents),copy_child)
    testing.expect(t,found && off)
    core.enable(&run.parents,child)
    core.world_settle(w)
    for message in send(st,w) {collab_watch_apply(s,st,message)}
    _,off,found=core.raw_state(core.raw(&guest.parents),copy_child)
    testing.expect(t,found && !off)
}
