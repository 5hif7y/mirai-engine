package mirai_net

import "core:math"
import "core:mem"
import "core:testing"

// A point pushed around by its input: the same procedure runs on the server, in prediction and in resimulation.
@(private="file")
Toy :: struct {position,velocity:[2]f32}
@(private="file")
toy_simulate :: proc(toy:^Toy,input:Test_Input) {
    toy.velocity+=(input.move*6-toy.velocity)*0.2
    if input.buttons&1!=0 {toy.velocity.y+=3}
    toy.position+=toy.velocity*f32(TEST_STEP)
}

@(private="file")
Toy_Sim :: struct {toy:Toy,simulated:int}
@(private="file")
toy_rollback :: proc(sim:^Toy_Sim,history,max_resimulate:int) -> Rollback_Desc {
    return {
        state_size=size_of(Toy),input_size=size_of(Test_Input),history=history,max_resimulate=max_resimulate,user=sim,
        save=proc(user:rawptr,state:[]u8) {mem.copy(raw_data(state),&(^Toy_Sim)(user).toy,size_of(Toy))},
        restore=proc(user:rawptr,state:[]u8) {mem.copy(&(^Toy_Sim)(user).toy,raw_data(state),size_of(Toy))},
        simulate=proc(user:rawptr,tick:u32,input:[]u8) {
            sim:=(^Toy_Sim)(user)
            toy_simulate(&sim.toy,(^Test_Input)(raw_data(input))^)
            sim.simulated+=1
        },
    }
}
@(private="file")
toy_input :: proc(tick:u32) -> Test_Input {
    return {move={math.sin(f32(tick)*0.05),math.cos(f32(tick)*0.031)},buttons=tick%97==0?1:0}
}

@(test)
rollback_confirms_corrects_resimulates_and_snaps :: proc(t:^testing.T) {
    sim:Toy_Sim
    r:Rollback
    testing.expect_value(t,rollback_init(&r,{state_size=8}),Error.Invalid)
    testing.expect_value(t,rollback_init(&r,toy_rollback(&sim,32,12)),Error.None)
    defer rollback_destroy(&r)
    reference:Toy
    history:[64]Toy
    for tick in u32(1)..=20 {
        input:=toy_input(tick)
        rollback_step(&r,tick,mem.ptr_to_bytes(&input))
        toy_simulate(&reference,input)
        history[tick]=reference
    }
    testing.expect_value(t,sim.toy,reference)
    kept,found:=rollback_state(&r,15)
    testing.expect(t,found && (^Toy)(raw_data(kept))^==history[15])
    kept_input,_:=rollback_input(&r,15)
    testing.expect_value(t,(^Test_Input)(raw_data(kept_input))^,toy_input(15))
    _,missing:=rollback_state(&r,21)
    testing.expect(t,!missing)

    // The server agrees.
    testing.expect_value(t,rollback_reconcile(&r,10,mem.ptr_to_bytes(&history[10])),Reconcile_Result.Confirmed)
    testing.expect_value(t,rollback_reconcile(&r,10,mem.ptr_to_bytes(&history[10])),Reconcile_Result.Stale)
    testing.expect_value(t,rollback_reconcile(&r,9,mem.ptr_to_bytes(&history[9])),Reconcile_Result.Stale)
    testing.expect_value(t,sim.simulated,20)

    // The server disagrees about tick 12: restore it and replay 13 to 20 with the inputs kept.
    authoritative:=history[12]
    authoritative.position+={2,-1}
    expected:=authoritative
    for tick in u32(13)..=20 {toy_simulate(&expected,toy_input(tick))}
    testing.expect_value(t,rollback_reconcile(&r,12,mem.ptr_to_bytes(&authoritative)),Reconcile_Result.Corrected)
    testing.expect_value(t,sim.toy,expected)
    testing.expect_value(t,sim.simulated,28)
    corrected,_:=rollback_state(&r,12)
    testing.expect_value(t,(^Toy)(raw_data(corrected))^,authoritative)
    // The history was rewritten, so the next state of the same timeline is confirmed.
    again:=authoritative
    toy_simulate(&again,toy_input(13))
    testing.expect_value(t,rollback_reconcile(&r,13,mem.ptr_to_bytes(&again)),Reconcile_Result.Confirmed)

    // More ticks behind than the budget allows: the present becomes the authoritative state, nothing is replayed.
    for tick in u32(21)..=40 {
        input:=toy_input(tick)
        rollback_step(&r,tick,mem.ptr_to_bytes(&input))
    }
    simulated:=sim.simulated
    far:=Toy{position={100,100}}
    testing.expect_value(t,rollback_reconcile(&r,20,mem.ptr_to_bytes(&far)),Reconcile_Result.Snapped)
    testing.expect(t,sim.toy==far && sim.simulated==simulated)
    present,_:=rollback_state(&r,40)
    testing.expect_value(t,(^Toy)(raw_data(present))^,far)
    _,forgotten:=rollback_state(&r,39)
    testing.expect(t,!forgotten)
    // A state from a tick not simulated yet is taken as it is, and simulation goes on from there.
    ahead:=Toy{position={7,7}}
    testing.expect_value(t,rollback_reconcile(&r,45,mem.ptr_to_bytes(&ahead)),Reconcile_Result.Snapped)
    testing.expect_value(t,r.newest,u32(45))
    input:=toy_input(46)
    rollback_step(&r,46,mem.ptr_to_bytes(&input))
    toy_simulate(&ahead,input)
    testing.expect_value(t,sim.toy,ahead)
    testing.expect_value(t,rollback_reconcile(&r,46,mem.ptr_to_bytes(&ahead)),Reconcile_Result.Confirmed)
    testing.expect_value(t,r.stats.corrected,u64(1))
    testing.expect_value(t,r.stats.resimulated,u64(8))
    testing.expect_value(t,r.stats.snapped,u64(2))
    testing.expect_value(t,r.stats.largest_resimulation,8)
    wrong:[3]u8
    testing.expect_value(t,rollback_reconcile(&r,47,wrong[:]),Reconcile_Result.Stale)

    // A tolerance instead of exact bytes.
    loose:Rollback
    desc:=toy_rollback(&sim,16,0)
    desc.equal=proc(user:rawptr,predicted,authoritative:[]u8) -> bool {
        a,b:=(^Toy)(raw_data(predicted)),(^Toy)(raw_data(authoritative))
        return abs(a.position.x-b.position.x)<0.01 && abs(a.position.y-b.position.y)<0.01
    }
    rollback_init(&loose,desc)
    defer rollback_destroy(&loose)
    rollback_step(&loose,1,mem.ptr_to_bytes(&input))
    near:=sim.toy
    near.position.x+=0.004
    testing.expect_value(t,rollback_reconcile(&loose,1,mem.ptr_to_bytes(&near)),Reconcile_Result.Confirmed)
    rollback_step(&loose,2,mem.ptr_to_bytes(&input))
    near=sim.toy
    near.position.x+=0.5
    testing.expect_value(t,rollback_reconcile(&loose,2,mem.ptr_to_bytes(&near)),Reconcile_Result.Corrected)
    rollback_reset(&loose)
    _,after_reset:=rollback_state(&loose,2)
    testing.expect(t,!after_reset)
}

@(test)
smoothing_keeps_the_picture_still_through_a_correction_and_fades_it_out :: proc(t:^testing.T) {
    s:Smoothing
    smoothing_init(&s,0.1,4)
    turned:quaternion128=quaternion(w=math.cos(f32(0.4)),x=0,y=math.sin(f32(0.4)),z=0)
    straight:quaternion128=quaternion(w=1,x=0,y=0,z=0)
    smoothing_correct(&s,{1,0,0},{2,0,1},turned,straight)
    position,rotation:=smoothing_apply(&s,{2,0,1},straight)
    testing.expect(t,abs(position.x-1)<1e-5 && abs(position.z)<1e-5)
    testing.expect(t,abs(rotation.y-turned.y)<1e-5 && abs(rotation.w-turned.w)<1e-5)
    smoothing_update(&s,0.1)
    position,_=smoothing_apply(&s,{2,0,1},straight)
    testing.expect(t,abs(position.x-1.5)<1e-4 && abs(position.z-0.5)<1e-4)
    for _ in 0..<100 {smoothing_update(&s,0.05)}
    position,rotation=smoothing_apply(&s,{2,0,1},straight)
    testing.expect(t,abs(position.x-2)<1e-4 && abs(rotation.w-1)<1e-4 && abs(rotation.y)<1e-3)
    // Too far to slide: show it where it is.
    smoothing_correct(&s,{0,0,0},{10,0,0},straight,straight)
    testing.expect_value(t,s.offset,[3]f32{0,0,0})
}

@(test)
interpolation_returns_the_two_snapshots_around_a_tick :: proc(t:^testing.T) {
    tp:Test_Protocol;test_protocol_init(&tp);defer test_protocol_destroy(&tp)
    i:Interpolation
    testing.expect_value(t,interpolation_init(&i,{state_size=0,capacity=2}),Error.Invalid)
    testing.expect_value(t,interpolation_init(&i,{state_size=size_of(Test_Transform),capacity=2,depth=4}),Error.None)
    defer interpolation_destroy(&i)
    a,_:=interpolation_add(&i)
    b,_:=interpolation_add(&i)
    _,third:=interpolation_add(&i)
    testing.expect(t,!third && a!=b)
    snapshot :: proc(x:f32,angle:f32) -> Test_Transform {
        return {position={x,0,0},rotation=quaternion(w=math.cos(angle*0.5),x=0,y=math.sin(angle*0.5),z=0)}
    }
    _,_,_,empty:=interpolation_sample(&i,a,5)
    testing.expect_value(t,empty,Interpolation_Status.Empty)
    for tick,n in ([?]u32{10,12,16}) {
        state:=snapshot(f32(tick),f32(n))
        testing.expect(t,interpolation_push(&i,a,tick,mem.ptr_to_bytes(&state)))
    }
    stale:=snapshot(0,0)
    testing.expect(t,!interpolation_push(&i,a,12,mem.ptr_to_bytes(&stale)))
    testing.expect(t,!interpolation_push(&i,a,17,mem.ptr_to_bytes(&stale)[:8]))
    from,to,alpha,status:=interpolation_sample(&i,a,13)
    testing.expect_value(t,status,Interpolation_Status.Between)
    testing.expect(t,abs(alpha-0.25)<1e-6)
    out:Test_Transform
    fragment_interpolate(&tp.protocol,tp.prop,0,raw_data(from),raw_data(to),alpha,&out)
    testing.expect(t,abs(out.position.x-13)<1e-5)
    // Halfway in tick, a quarter of the way from one radian to two.
    testing.expect(t,abs(2*math.atan2(out.rotation.y,out.rotation.w)-1.25)<0.01)
    _,_,_,status=interpolation_sample(&i,a,11)
    testing.expect_value(t,status,Interpolation_Status.Between)
    from,_,_,status=interpolation_sample(&i,a,3)
    testing.expect(t,status==.Before && (^Test_Transform)(raw_data(from)).position.x==10)
    from,_,alpha,status=interpolation_sample(&i,a,16.5)
    testing.expect(t,status==.After && (^Test_Transform)(raw_data(from)).position.x==16 && alpha==0.5)
    // Gaps of two and four ticks: the longest counts at once.
    testing.expect_value(t,interpolation_spacing(&i,a),f32(4))
    newest,newest_tick,_:=interpolation_newest(&i,a)
    testing.expect(t,newest_tick==16 && (^Test_Transform)(raw_data(newest)).position.x==16)
    // Only the last four are kept.
    for tick in u32(17)..=20 {
        state:=snapshot(f32(tick),0)
        interpolation_push(&i,a,tick,mem.ptr_to_bytes(&state))
    }
    from,_,_,status=interpolation_sample(&i,a,12)
    testing.expect(t,status==.Before && (^Test_Transform)(raw_data(from)).position.x==17)
    // Gaps of one tick bring it down an eighth of the way each.
    testing.expect(t,interpolation_spacing(&i,a)<4 && interpolation_spacing(&i,a)>2)
    _,_,_,status=interpolation_sample(&i,b,12)
    testing.expect_value(t,status,Interpolation_Status.Empty)
    interpolation_clear(&i,a)
    _,_,_,status=interpolation_sample(&i,a,18)
    testing.expect_value(t,status,Interpolation_Status.Empty)
    interpolation_remove(&i,a)
    again,ok:=interpolation_add(&i)
    testing.expect(t,ok && again==a)
}

@(private="file")
Session :: struct {
    s:^Scene,
    server_tick:u32,
    server_toy:Toy,
    published:Test_Transform, // what the server replicates of its toy
    player:Object,
    sim:Toy_Sim,
    rollback:Rollback,
    smoothing:Smoothing,
    fresh,repeated,none:int,
    last_client_tick:u32,
    largest_jump:f32,
    kick_at:u32,
    ticks:Test_Ticks,
}
// One 60 Hz frame: the server simulates its tick with the input it has, the client the ticks its clock asks for.
@(private="file")
session_frame :: proc(t:^testing.T,x:^Session,moving:bool) {
    s:=x.s
    server,client:=s.server,s.clients[0]
    for &command in host_poll(server) {}
    x.server_tick+=1
    input:Test_Input
    switch input_take(server,s.on_server[0],x.server_tick,&input) {
    case .Fresh:    x.fresh+=1
    case .Repeated: x.repeated+=1
    case .None:     x.none+=1
    }
    toy_simulate(&x.server_toy,input)
    if x.server_tick==x.kick_at {x.server_toy.position+={3,0}}
    x.published.position={x.server_toy.position.x,0,x.server_toy.position.y}
    x.published.velocity={x.server_toy.velocity.x,0,x.server_toy.velocity.y}
    host_publish(server,x.server_tick)

    for &command in host_poll(client) {
        if command.kind!=.Object_Updated && command.kind!=.Object_Created {continue}
        x.player=command.object
        authoritative:Test_Transform
        object_read(client,&command,0,&authoritative,max(u64))
        state:=Toy{position={authoritative.position.x,authoritative.position.z},velocity={authoritative.velocity.x,authoritative.velocity.z}}
        before:=x.sim.toy.position
        if rollback_reconcile(&x.rollback,command.tick,mem.ptr_to_bytes(&state))==.Corrected {
            after:=x.sim.toy.position
            smoothing_correct(&x.smoothing,{before.x,0,before.y},{after.x,0,after.y},quaternion(w=1,x=0,y=0,z=0),quaternion(w=1,x=0,y=0,z=0))
        }
    }
    shown_before,_:=smoothing_apply(&x.smoothing,{x.sim.toy.position.x,0,x.sim.toy.position.y},quaternion(w=1,x=0,y=0,z=0))
    first,steps:=test_ticks(&x.ticks,client,s.w.now)
    for step in 0..<u32(steps) {
        tick:=first+step
        mine:=moving?toy_input(tick):Test_Input{}
        testing.expect_value(t,input_submit(client,tick,&mine),Error.None)
        // What is predicted is what the server will read: the quantized input.
        mine.move.x=math.round(mine.move.x*100)/100
        mine.move.y=math.round(mine.move.y*100)/100
        rollback_step(&x.rollback,tick,mem.ptr_to_bytes(&mine))
        host_publish(client,tick)
        x.last_client_tick=tick
    }
    smoothing_update(&x.smoothing,f32(TEST_STEP))
    shown_after,_:=smoothing_apply(&x.smoothing,{x.sim.toy.position.x,0,x.sim.toy.position.y},quaternion(w=1,x=0,y=0,z=0))
    if steps>0 {x.largest_jump=max(x.largest_jump,abs(shown_after.x-shown_before.x)/f32(steps),abs(shown_after.z-shown_before.z)/f32(steps))}
    test_step(&s.w)
}
@(private="file")
session_init :: proc(x:^Session,s:^Scene,conditions:Sim_Conditions) {
    x^={s=s}
    x.published.rotation=quaternion(w=1,x=0,y=0,z=0)
    object_create(s.server,{type=s.tp.prop,sources={0=&x.published},owner=s.on_server[0],poll=true})
    desc:=toy_rollback(&x.sim,64,40)
    desc.equal=proc(user:rawptr,predicted,authoritative:[]u8) -> bool {
        a,b:=(^Toy)(raw_data(predicted)),(^Toy)(raw_data(authoritative))
        return abs(a.position.x-b.position.x)<0.02 && abs(a.position.y-b.position.y)<0.02 && abs(a.velocity.x-b.velocity.x)<0.08 && abs(a.velocity.y-b.velocity.y)<0.08
    }
    rollback_init(&x.rollback,desc)
    smoothing_init(&x.smoothing)
    sim_endpoint_conditions(&s.w.sim,0,conditions)
    sim_endpoint_conditions(&s.w.sim,1,conditions)
}

@(test)
client_clock_runs_ahead_of_the_server_so_inputs_arrive_in_time :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=8},seed=9);defer scene_destroy(s)
    x:=new(Session);defer free(x)
    session_init(x,s,{latency=0.05,jitter=0.004})
    defer rollback_destroy(&x.rollback)
    for _ in 0..<240 {session_frame(t,x,true)}
    clock:=clock_state(s.clients[0])
    testing.expect(t,clock.synced)
    x.fresh,x.repeated,x.none=0,0,0
    for _ in 0..<600 {session_frame(t,x,true)}
    testing.expect(t,x.fresh>=594)
    clock=clock_state(s.clients[0])
    // Ahead of the tick the server is on by the trip of an input, about three ticks, plus the margin.
    lead:=f64(x.last_client_tick)-f64(x.server_tick)
    testing.expectf(t,lead>=4 && lead<=8,"lead %v rtt %v bias %v",lead,clock.rtt,clock.bias)
    testing.expect(t,abs(clock.dilation)<0.03)
    testing.expect(t,abs(clock.rtt-0.1)<0.03)
    testing.expect(t,abs(clock.server-f64(x.server_tick))<2)
    testing.expect_value(t,clock.jumps,u32(0))
    behind:=clock.server-clock.display
    testing.expect(t,behind>4 && behind<8)
    stats,_:=connection_stats(s.server,s.on_server[0])
    testing.expect(t,stats.inputs_received>800 && stats.inputs_missed==0)

    // The link gets slower: the clock follows by running faster for a while, without jumping.
    sim_endpoint_conditions(&s.w.sim,0,{latency=0.11,jitter=0.004})
    sim_endpoint_conditions(&s.w.sim,1,{latency=0.11,jitter=0.004})
    for _ in 0..<600 {session_frame(t,x,true)}
    x.fresh,x.repeated=0,0
    for _ in 0..<300 {session_frame(t,x,true)}
    testing.expect(t,x.fresh>=297)
    testing.expectf(t,f64(x.last_client_tick)-f64(x.server_tick)>=lead+3,"lead %v after %v",f64(x.last_client_tick)-f64(x.server_tick),lead)
    testing.expect_value(t,clock_state(s.clients[0]).jumps,u32(0))

    // Redundancy covers lost datagrams.
    sim_endpoint_conditions(&s.w.sim,1,{latency=0.11,jitter=0.004,loss=0.2})
    x.fresh,x.repeated=0,0
    for _ in 0..<600 {session_frame(t,x,true)}
    testing.expect(t,x.fresh>=560)
}

@(test)
prediction_reconciles_with_the_server_under_latency_and_loss :: proc(t:^testing.T) {
    s:=new(Scene);defer free(s)
    scene_init(s,1,{max_objects=8,input_redundancy=2},seed=31);defer scene_destroy(s)
    x:=new(Session);defer free(x)
    session_init(x,s,{latency=0.06,jitter=0.01,loss=0.1,duplicate=0.05,reorder=0.05,reorder_delay=0.02})
    defer rollback_destroy(&x.rollback)
    for _ in 0..<200 {session_frame(t,x,true)}
    x.kick_at=x.server_tick+100
    snapped:=x.rollback.stats.snapped
    x.largest_jump=0
    for _ in 0..<900 {session_frame(t,x,true)}
    stats:=x.rollback.stats
    // The server moved the toy on its own once, and lost inputs made it repeat old ones: both were corrected by replaying.
    testing.expect(t,x.repeated>0)
    testing.expect(t,stats.corrected>=2 && stats.resimulated>=stats.corrected*4)
    testing.expect(t,stats.confirmed>stats.corrected*5)
    // Catching up with the server at the start took a few states as they came; after that, none.
    testing.expect(t,snapped>=1 && snapped<=30)
    testing.expect_value(t,stats.snapped,snapped)
    testing.expect(t,stats.largest_resimulation<=40)
    // The picture never jumped the three meters the simulation did.
    testing.expect(t,x.largest_jump<0.8)
    // Hands off: both ends come to rest in the same place.
    for _ in 0..<240 {session_frame(t,x,false)}
    testing.expect(t,abs(x.sim.toy.position.x-x.server_toy.position.x)<0.02)
    testing.expect(t,abs(x.sim.toy.position.y-x.server_toy.position.y)<0.02)
    shown,_:=smoothing_apply(&x.smoothing,{x.sim.toy.position.x,0,x.sim.toy.position.y},quaternion(w=1,x=0,y=0,z=0))
    testing.expect(t,abs(shown.x-x.server_toy.position.x)<0.03)
    testing.expect(t,test_replica_matches(s.server,s.clients[0],x.player,true))
}

@(test)
rollback_correct_restores_a_tick_and_simulates_up_to_the_present :: proc(t:^testing.T) {
    sim:Toy_Sim
    r:Rollback
    testing.expect_value(t,rollback_init(&r,toy_rollback(&sim,32,12)),Error.None)
    defer rollback_destroy(&r)
    testing.expect(t,!rollback_correct(&r,1),"nothing was simulated yet")
    for tick in u32(1)..=20 {
        input:=toy_input(tick)
        rollback_step(&r,tick,mem.ptr_to_bytes(&input))
    }
    present:=sim.toy
    simulated:=sim.simulated
    // The caller changes nothing: the same ticks give the same present.
    testing.expect(t,rollback_correct(&r,14))
    testing.expect_value(t,sim.toy,present)
    testing.expect_value(t,sim.simulated-simulated,6)
    testing.expect_value(t,r.stats.corrected,u64(1))
    testing.expect_value(t,r.stats.resimulated,u64(6))
    // A tick already corrected can be corrected again, unlike with rollback_reconcile.
    testing.expect(t,rollback_correct(&r,12))
    testing.expect_value(t,r.stats.largest_resimulation,8)
    testing.expect(t,rollback_correct(&r,20))
    testing.expect_value(t,r.stats.resimulated,u64(14))
    // Farther than max_resimulate, ahead of the present or out of the history: refused, and nothing runs.
    simulated=sim.simulated
    testing.expect(t,!rollback_correct(&r,7))
    testing.expect(t,!rollback_correct(&r,21))
    testing.expect_value(t,sim.simulated,simulated)
    testing.expect_value(t,sim.toy,present)
}
