package host

import "base:intrinsics"
import "core:math/rand"
import "core:testing"
import "core:time"
import "mirai:core"
import "mirai:std/jobs"

@(private="file") STEPS :: 12
@(private="file") SLOTS :: 6
@(private="file") ROWS :: 256

@(private="file") Slots :: bit_set[0..<SLOTS]

@(private="file")
Steps_World :: struct {
    data:[SLOTS][ROWS]u64,
    reads,writes:[STEPS]Slots,
    main:[STEPS]bool,
    worker:[STEPS]int, // that ran each step last
}

// Step i reads its slots and folds them into those it writes, slowly enough
// that steps of a run overlap.
@(private="file")
steps_test_step :: proc(world:rawptr,i,worker:int) {
    w:=cast(^Steps_World)world
    for row in 0..<ROWS {
        value:=u64(i+1)
        for slot in w.reads[i] {value=(value~w.data[slot][row])*0x100000001b3}
        for _ in 0..<64 {value~=value<<13;value~=value>>7;value~=value<<17}
        for slot in w.writes[i] {w.data[slot][row]=w.data[slot][row]*31+value+u64(row)}
    }
    w.worker[i]=worker
}

@(private="file") step_0 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,0,worker)}
@(private="file") step_1 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,1,worker)}
@(private="file") step_2 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,2,worker)}
@(private="file") step_3 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,3,worker)}
@(private="file") step_4 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,4,worker)}
@(private="file") step_5 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,5,worker)}
@(private="file") step_6 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,6,worker)}
@(private="file") step_7 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,7,worker)}
@(private="file") step_8 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,8,worker)}
@(private="file") step_9 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,9,worker)}
@(private="file") step_10 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,10,worker)}
@(private="file") step_11 :: proc(w,s,e,a:rawptr,worker:int) {steps_test_step(w,11,worker)}

@(private="file")
steps_test_fixed :: proc(world,shared,editor,app:rawptr) {
    for i in 0..<STEPS {steps_test_step(world,i,0)}
}

// The World of the fixed ticks of a run with threads job threads besides the
// caller: steps that touch a slot another one writes wait for it, in the
// order of the loop, as the generator orders them.
@(private="file")
steps_test_run :: proc(t:^testing.T,from:^Steps_World,threads,ticks:int) -> (out:Steps_World,ok:bool) {
    calls:=[STEPS]core.Step_Proc{step_0,step_1,step_2,step_3,step_4,step_5,step_6,step_7,step_8,step_9,step_10,step_11}
    steps:[STEPS]core.Step_Info
    order:[STEPS]i32
    edges:=make([dynamic]core.Step_Edge,context.temp_allocator)
    for i in 0..<STEPS {
        steps[i]={name="step",library="test",phases={.Fixed},loops={.Game},call=calls[i],main=from.main[i]}
        order[i]=i32(i)
        for j in i+1..<STEPS {
            if from.writes[i]&(from.reads[j]+from.writes[j])!={} || from.writes[j]&from.reads[i]!={} {append(&edges,core.Step_Edge{i32(i),i32(j)})}
        }
    }
    info:core.World_Info
    info.steps=steps[:]
    info.order[.Game][.Fixed]=order[:]
    info.edges[.Game][.Fixed]=edges[:]
    info.loops[.Game][.Fixed]=steps_test_fixed
    info.parallel=true
    app:=App{info=&info,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=threads})) {return}
    defer jobs.system_destroy(&app.jobs)
    defer steps_free(&app)
    out=from^
    for _ in 0..<ticks {run_phase(&app,.Game,.Fixed,{.Fixed},&out,nil)}
    if threads>0 {testing.expect(t,app.step_graphs[.Game][.Fixed].order!=nil)}
    return out,true
}

// The fixed phase gives the same World with one worker, which runs its steps
// in the order of the loop, and with several, which run at once the steps the
// edges do not order: what a rollback needs. A main step runs on the thread
// of the loop.
@(test)
a_fixed_phase_gives_the_same_world_with_one_worker_and_with_several :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    for round in 0..<8 {
        from:Steps_World
        for &slot in from.data {
            for &value in slot {value=rand.uint64()}
        }
        for i in 0..<STEPS {
            for slot in 0..<SLOTS {
                switch rand.int_max(6) {
                case 0: from.writes[i]+={slot}
                case 1,2: from.reads[i]+={slot}
                }
            }
            from.main[i]=rand.int_max(4)==0
        }
        alone,alone_ok:=steps_test_run(t,&from,0,20)
        if !alone_ok {return}
        for threads in ([2]int{1,3}) {
            for _ in 0..<4 {
                together,ok:=steps_test_run(t,&from,threads,20)
                if !ok {return}
                testing.expectf(t,together.data==alone.data,"round %d: %d threads give another World",round,threads)
                for main,i in from.main {
                    if main {testing.expectf(t,together.worker[i]==jobs.OWNER,"round %d: main step %d ran on worker %d",round,i,together.worker[i])}
                }
            }
        }
    }
}

// Steps that conflict in nothing run at once: each waits until the other
// started, which only a second worker lets happen.
@(test)
steps_without_edges_run_at_once :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    Meet :: struct {arrived:[2]bool,met:[2]bool}
    meet_step :: proc(world:rawptr,i:int) {
        m:=cast(^Meet)world
        intrinsics.atomic_store(&m.arrived[i],true)
        deadline:=time.tick_now()
        for !intrinsics.atomic_load(&m.arrived[1-i]) {
            if time.tick_since(deadline)>10*time.Second {return}
        }
        m.met[i]=true
    }
    first :: proc(w,s,e,a:rawptr,worker:int) {meet_step(w,0)}
    second :: proc(w,s,e,a:rawptr,worker:int) {meet_step(w,1)}
    sequential :: proc(world,shared,editor,app:rawptr) {}
    steps:=[2]core.Step_Info{{name="first",call=first},{name="second",call=second}}
    order:=[2]i32{0,1}
    info:core.World_Info
    info.steps=steps[:]
    info.order[.Game][.Frame]=order[:]
    info.loops[.Game][.Frame]=sequential
    info.parallel=true
    app:=App{info=&info,allocator=context.allocator}
    if !testing.expect(t,jobs.system_init(&app.jobs,{threads=1})) {return}
    defer jobs.system_destroy(&app.jobs)
    defer steps_free(&app)
    m:Meet
    run_phase(&app,.Game,.Frame,{.Frame},&m,nil)
    testing.expect_value(t,m.met,[2]bool{true,true})
}
