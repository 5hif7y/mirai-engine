package mirai_net

import "core:testing"
import "mirai:std/base"

// The objects one connection receives, in order, when a tick fits one of them.
@(private)
priority_order :: proc(scale:f32) -> (order:[60]u32) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=8,max_updates=1});defer scene_destroy(s)
    transforms:[3]Test_Transform
    priorities:=[3]f32{3,2,1.5}
    for &transform,i in transforms {
        object_create(s.server,{type=s.tp.prop,sources={0=&transform},poll=true,priority=priorities[i]*scale,owner=i==2?s.on_server[0]:0})
    }
    Seen :: struct {order:[60]u32,count:int}
    seen:Seen
    visit :: proc(client:int,command:^Command,user:rawptr) {
        seen:=(^Seen)(user)
        if (command.kind==.Object_Created || command.kind==.Object_Updated) && seen.count<len(seen.order) {
            seen.order[seen.count]=base.handle_index(base.Handle(command.object))+1
            seen.count+=1
        }
    }
    tick:=u32(0)
    for _ in 0..<80 {
        for &transform in transforms {transform.position.x+=1}
        scene_tick(s,&tick,visit,&seen)
    }
    return seen.order
}

@(test)
priority_orders_the_same_way_at_any_scale :: proc(t:^testing.T) {
    small:=priority_order(1)
    // 2^126: the largest priority, twice for its owner, is close to the largest f32.
    huge:=priority_order(transmute(f32)u32((127+126)<<23))
    sent:[4]int
    for object,i in small {
        sent[object]+=1
        if !testing.expectf(t,huge[i]==object,"update %v went to object %v with huge priorities and to %v with small ones",i,huge[i],object) {return}
    }
    testing.expect(t,sent[1]>0 && sent[2]>0 && sent[3]>0)
    testing.expect(t,sent[1]>sent[2])
}

@(test)
custom_relevance_lets_in_only_the_connections_the_game_names :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,2,{max_objects=8,filter_interval=4});defer scene_destroy(s)
    transform:=Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)}
    secret,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Custom})
    child,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},parent=secret})
    has :: proc(s:^Scene,client:int,object:Object) -> bool {return object_valid(s.clients[client],object)}
    run :: proc(s:^Scene,tick:^u32) {for _ in 0..<12 {scene_tick(s,tick)}}
    tick:=u32(0)
    run(s,&tick)
    testing.expect(t,!has(s,0,secret) && !has(s,1,secret) && !has(s,0,child),"nobody is let in at first")
    testing.expect_value(t,object_set_relevance(s.server,secret,s.on_server[0],true),Error.None)
    run(s,&tick)
    testing.expect(t,has(s,0,secret) && has(s,0,child) && !has(s,1,secret) && !has(s,1,child))
    object_set_relevance(s.server,secret,s.on_server[0],false)
    object_set_relevance(s.server,secret,s.on_server[1],true)
    run(s,&tick)
    testing.expect(t,!has(s,0,secret) && !has(s,0,child) && has(s,1,secret) && has(s,1,child))

    // Another filter does not look at what the game named, which waits for Custom to come back.
    object_set_filter(s.server,secret,.Always)
    run(s,&tick)
    testing.expect(t,has(s,0,secret) && has(s,1,secret))
    object_set_filter(s.server,secret,.Custom)
    run(s,&tick)
    testing.expect(t,!has(s,0,secret) && has(s,1,secret))

    // A connection that arrives again, in the same slot, starts with none.
    host_disconnect(s.clients[1])
    for _ in 0..<10 {
        tick+=1
        host_publish(s.server,tick)
        test_step(&s.w)
        host_poll(s.server);host_poll(s.clients[0]);host_poll(s.clients[1])
    }
    previous:=s.on_server[1]
    s.on_server[1],s.on_client[1]=test_connect(&s.w,s.server,s.clients[1])
    testing.expect(t,s.on_server[1]!=0 && s.on_server[1]!=previous && base.handle_index(base.Handle(s.on_server[1]))==base.handle_index(base.Handle(previous)))
    run(s,&tick)
    testing.expect(t,!has(s,1,secret),"what the game named for a connection that left is not given to the next one")
    testing.expect_value(t,object_set_relevance(s.server,secret,previous,true),Error.None)
    run(s,&tick)
    testing.expect(t,!has(s,1,secret),"a connection that left is no one")

    // A new object in the slot of one that ended starts with none.
    object_set_relevance(s.server,secret,s.on_server[0],true)
    run(s,&tick)
    testing.expect(t,has(s,0,secret))
    object_destroy(s.server,child)
    object_destroy(s.server,secret)
    run(s,&tick)
    again:Object
    for _ in 0..<16 {
        again,_=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Custom})
        run(s,&tick)
        if base.handle_index(base.Handle(again))==base.handle_index(base.Handle(secret)) {break}
        object_destroy(s.server,again)
    }
    testing.expect_value(t,base.handle_index(base.Handle(again)),base.handle_index(base.Handle(secret)))
    testing.expect(t,!has(s,0,again) && !has(s,1,again))

    testing.expect_value(t,object_set_relevance(s.server,secret,s.on_server[0],true),Error.Invalid)
    testing.expect_value(t,object_set_relevance(s.server,again,0,true),Error.Invalid)
    testing.expect_value(t,object_set_relevance(s.clients[0],again,s.on_client[0],true),Error.Invalid)
}

@(test)
polled_objects_are_read_on_their_turns_spread_over_the_interval :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=16});defer scene_destroy(s)
    transforms:[7]Test_Transform
    objects:[7]Object
    for &object,i in objects[:6] {
        error:Error
        object,error=object_create(s.server,{type=s.tp.prop,sources={0=&transforms[i]},poll=true,poll_interval=3})
        testing.expect_value(t,error,Error.None)
    }
    marked,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transforms[6]},poll=true,poll_interval=1000})
    Seen :: struct {updates:[16]int,position:f32}
    seen:Seen
    visit :: proc(client:int,command:^Command,user:rawptr) {
        if command.kind!=.Object_Updated {return}
        seen:=(^Seen)(user)
        seen.updates[base.handle_index(base.Handle(command.object))]+=1
    }
    tick:=u32(0)
    for _ in 0..<10 {scene_tick(s,&tick,visit,&seen)}
    seen={}
    for _ in 0..<30 {
        // Each tick one third of them is due: the reads are spread instead of all landing on one tick.
        due:=0
        for object in objects[:6] {due+=int(object_poll_due(s.server,object,tick+1))}
        testing.expect_value(t,due,2)
        for &transform in transforms[:6] {transform.position.x+=1}
        scene_tick(s,&tick,visit,&seen)
    }
    for object in objects[:6] {
        testing.expect_value(t,seen.updates[base.handle_index(base.Handle(object))],10)
        testing.expect_value(t,object_poll_interval(s.server,object),3)
    }
    // A mark does not wait for the turn.
    transforms[6].position.x=7
    object_mark_dirty(s.server,marked)
    scene_tick(s,&tick,visit,&seen)
    scene_tick(s,&tick,visit,&seen)
    testing.expect_value(t,seen.updates[base.handle_index(base.Handle(marked))],1)
    // Back to every tick.
    testing.expect_value(t,object_set_poll_interval(s.server,objects[0],0),Error.None)
    testing.expect_value(t,object_poll_interval(s.server,objects[0]),1)
    seen={}
    for _ in 0..<6 {
        transforms[0].position.x+=1
        scene_tick(s,&tick,visit,&seen)
    }
    testing.expect_value(t,seen.updates[base.handle_index(base.Handle(objects[0]))],6)
    testing.expect_value(t,object_set_poll_interval(s.server,objects[0],-1),Error.Invalid)
    _,error:=object_create(s.server,{type=s.tp.prop,poll_interval=-2})
    testing.expect_value(t,error,Error.Invalid)
}

// A held connection sees nothing, whatever the filter, until it is let go;
// held again, what it saw leaves it.
@(test)
a_held_connection_sees_no_object_until_it_is_let_go :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,0,{max_objects=8,filter_interval=2});defer scene_destroy(s)
    s.server.desc.hold=true
    scene_join(s);scene_join(s)
    transform:=Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)}
    object,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Always})
    has :: proc(s:^Scene,client:int,object:Object) -> bool {return object_valid(s.clients[client],object)}
    run :: proc(s:^Scene,tick:^u32) {for _ in 0..<12 {scene_tick(s,tick)}}
    tick:=u32(0)
    run(s,&tick)
    testing.expect(t,!has(s,0,object) && !has(s,1,object),"a connection that arrives is held")
    testing.expect_value(t,connection_hold(s.server,s.on_server[0],false),Error.None)
    run(s,&tick)
    testing.expect(t,has(s,0,object) && !has(s,1,object))
    connection_hold(s.server,s.on_server[0],true)
    run(s,&tick)
    testing.expect(t,!has(s,0,object),"held again, what it saw leaves it")
    testing.expect_value(t,connection_hold(s.clients[0],s.on_client[0],false),Error.Invalid)
}

// An object of a group reaches a connection only while that connection has
// the group, whatever its filter, and so do its children; a connection that
// loses the group, or all of them, loses what it saw of it.
@(test)
a_connection_sees_the_objects_of_a_group_only_while_it_has_it :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,2,{max_objects=8,filter_interval=2,groups=4});defer scene_destroy(s)
    transform:=Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)}
    grouped,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Always,groups={3,0,0,0}})
    child,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},parent=grouped})
    free_one,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Always})
    has :: proc(s:^Scene,client:int,object:Object) -> bool {return object_valid(s.clients[client],object)}
    run :: proc(s:^Scene,tick:^u32) {for _ in 0..<12 {scene_tick(s,tick)}}
    tick:=u32(0)
    run(s,&tick)
    testing.expect(t,!has(s,0,grouped) && !has(s,0,child) && !has(s,1,grouped),"a connection that arrives has no group")
    testing.expect(t,has(s,0,free_one) && has(s,1,free_one))
    testing.expect_value(t,connection_set_group(s.server,s.on_server[0],3,true),Error.None)
    run(s,&tick)
    testing.expect(t,has(s,0,grouped) && has(s,0,child) && !has(s,1,grouped) && !has(s,1,child))
    connection_set_group(s.server,s.on_server[0],3,false)
    run(s,&tick)
    testing.expect(t,!has(s,0,grouped) && !has(s,0,child),"what it lost the group of leaves it")
    connection_set_group(s.server,s.on_server[1],3,true)
    connection_set_group(s.server,s.on_server[1],2,true)
    run(s,&tick)
    testing.expect(t,has(s,1,grouped) && has(s,1,child))
    testing.expect_value(t,connection_clear_groups(s.server,s.on_server[1]),Error.None)
    run(s,&tick)
    testing.expect(t,!has(s,1,grouped) && has(s,1,free_one))
    // Out of its group, it is seen as its filter says.
    testing.expect_value(t,object_set_groups(s.server,grouped,{}),Error.None)
    run(s,&tick)
    testing.expect(t,has(s,0,grouped) && has(s,1,grouped) && has(s,1,child))
    testing.expect_value(t,object_set_groups(s.server,grouped,{0,5,0,0}),Error.Invalid)
    testing.expect_value(t,connection_set_group(s.server,s.on_server[0],0,true),Error.Invalid)
    testing.expect_value(t,connection_set_group(s.server,s.on_server[0],5,true),Error.Invalid)
    testing.expect_value(t,connection_set_group(s.clients[0],s.on_client[0],1,true),Error.Invalid)
    _,error:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},groups={5,0,0,0}})
    testing.expect_value(t,error,Error.Invalid)
}

// An object of several groups (what is in sections that overlap) reaches a
// connection that has any of them, once: a single creation and a single
// update for each change, however many of its groups the connection has; it
// leaves only when the connection has none of them.
@(test)
an_object_of_several_groups_reaches_a_connection_that_has_any_of_them_once :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,3,{max_objects=8,filter_interval=2,groups=4});defer scene_destroy(s)
    transform:=Test_Transform{rotation=quaternion(w=1,x=0,y=0,z=0)}
    object,_:=object_create(s.server,{type=s.tp.prop,sources={0=&transform},filter=.Always,groups={2,3,0,0}})
    has :: proc(s:^Scene,client:int,object:Object) -> bool {return object_valid(s.clients[client],object)}
    run :: proc(s:^Scene,tick:^u32) {for _ in 0..<12 {scene_tick(s,tick)}}
    tick:=u32(0)
    connection_set_group(s.server,s.on_server[0],2,true)
    connection_set_group(s.server,s.on_server[1],2,true)
    connection_set_group(s.server,s.on_server[1],3,true)
    connection_set_group(s.server,s.on_server[2],1,true)
    run(s,&tick)
    testing.expect(t,has(s,0,object) && has(s,1,object) && !has(s,2,object),"it reaches who has any of its groups, and nobody else")
    stats:=&s.server.back.repl.type_stats[s.tp.prop]
    testing.expect_value(t,stats.creates,2)
    transform.position={1,0,0}
    object_mark_dirty(s.server,object)
    run(s,&tick)
    testing.expect_value(t,stats.updates,2)
    connection_set_group(s.server,s.on_server[1],2,false)
    run(s,&tick)
    testing.expect(t,has(s,1,object),"with one of its groups left, it stays")
    testing.expect_value(t,stats.destroys,0)
    connection_set_group(s.server,s.on_server[1],3,false)
    run(s,&tick)
    testing.expect(t,!has(s,1,object) && has(s,0,object),"with none, it leaves")
    testing.expect_value(t,object_set_groups(s.server,object,{0,0,3,1}),Error.None)
    run(s,&tick)
    testing.expect(t,!has(s,0,object) && has(s,2,object),"its groups change what reaches whom")
}

// A held connection hears only the events registered Held: what a session
// says while the world is not theirs yet; the rest, once it is let go.
@(test)
a_held_connection_hears_only_the_events_registered_held :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,0,{max_objects=8});defer scene_destroy(s)
    s.server.desc.hold=true
    scene_join(s);scene_join(s)
    Heard :: struct {hits,notices:[2]int,s:^Scene}
    heard:Heard
    heard.s=s
    visit :: proc(client:int,command:^Command,user:rawptr) {
        heard:=(^Heard)(user)
        if command.kind!=.Event {return}
        if command.event==heard.s.tp.hit {heard.hits[client]+=1}
        if command.event==heard.s.tp.notice {heard.notices[client]+=1}
    }
    hit:Test_Hit
    tick:=u32(0)
    testing.expect_value(t,connection_hold(s.server,s.on_server[0],false),Error.None)
    for _ in 0..<4 {scene_tick(s,&tick,visit,&heard)}
    event_send(s.server,s.tp.hit,0,&hit)
    event_send(s.server,s.tp.notice,0,&hit)
    event_send(s.server,s.tp.hit,0,&hit,s.on_server[1])
    for _ in 0..<8 {scene_tick(s,&tick,visit,&heard)}
    testing.expect_value(t,heard.hits,[2]int{1,0})
    testing.expect_value(t,heard.notices,[2]int{1,1})
    connection_hold(s.server,s.on_server[1],false)
    for _ in 0..<4 {scene_tick(s,&tick,visit,&heard)}
    event_send(s.server,s.tp.hit,0,&hit)
    for _ in 0..<8 {scene_tick(s,&tick,visit,&heard)}
    testing.expect_value(t,heard.hits,[2]int{2,1})
}
