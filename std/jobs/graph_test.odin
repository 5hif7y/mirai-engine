package jobs

import "base:intrinsics"
import "core:math/rand"
import "core:testing"
import "core:time"

@(private="file")
Trace :: struct {clock:i32,violations:i32}

@(private="file")
Step :: struct {
    trace:^Trace,
    dependencies:[8]^Step,
    dependency_count:int,
    finished_at:i32,
    value:u64,
    seed:u64,
    worker:int, // that ran it
}

@(private="file")
step_run :: proc(data:rawptr,worker:int) {
    step:=cast(^Step)data
    value:=step.seed
    for dependency in step.dependencies[:step.dependency_count] {
        if intrinsics.atomic_load(&dependency.finished_at)==0 {intrinsics.atomic_add(&step.trace.violations,1)}
        value=value*0x100000001b3+dependency.value
    }
    step.value=value
    step.worker=worker
    intrinsics.atomic_store(&step.finished_at,intrinsics.atomic_add(&step.trace.clock,1)+1)
}

@(private="file")
step_depend :: proc(g:^Graph,steps:[]Step,node,dependency:int) -> bool {
    step:=&steps[node]
    step.dependencies[step.dependency_count]=&steps[dependency];step.dependency_count+=1
    return graph_depend(g,node,dependency)
}

@(test)
graph_runs_every_node_after_its_dependencies :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,60*time.Second)
    js:Job_System
    testing.expect(t,system_init(&js,{threads=3}))
    defer system_destroy(&js)
    g:Graph
    testing.expect(t,graph_init(&g,{node_capacity=8,edge_capacity=8}))
    defer graph_destroy(&g)
    trace:Trace
    steps:[5]Step
    for &step,i in steps {
        step={trace=&trace,seed=u64(i+1)}
        node,ok:=graph_add(&g,step_run,&step)
        testing.expect(t,ok && node==i)
    }
    // 0 -> 1 -> 3, 0 -> 2 -> 3, 4 alone
    testing.expect(t,step_depend(&g,steps[:],1,0))
    testing.expect(t,step_depend(&g,steps[:],2,0))
    testing.expect(t,step_depend(&g,steps[:],3,1))
    testing.expect(t,step_depend(&g,steps[:],3,2))
    for _ in 0..<200 {
        for &step in steps {step.finished_at=0}
        trace.clock=0
        testing.expect(t,graph_run(&js,OWNER,&g))
        testing.expect_value(t,trace.clock,i32(5))
        testing.expect(t,steps[0].finished_at<steps[1].finished_at && steps[0].finished_at<steps[2].finished_at)
        testing.expect(t,steps[3].finished_at>steps[1].finished_at && steps[3].finished_at>steps[2].finished_at)
    }
    testing.expect_value(t,trace.violations,i32(0))
}

@(test)
graph_with_a_cycle_does_not_run :: proc(t:^testing.T) {
    js:Job_System
    testing.expect(t,system_init(&js,{}))
    defer system_destroy(&js)
    g:Graph
    testing.expect(t,graph_init(&g,{node_capacity=4}))
    defer graph_destroy(&g)
    trace:Trace
    steps:[3]Step
    for &step in steps {step={trace=&trace};graph_add(&g,step_run,&step)}
    testing.expect(t,graph_depend(&g,1,0))
    testing.expect(t,graph_depend(&g,2,1))
    testing.expect(t,graph_acyclic(&g))
    testing.expect(t,graph_depend(&g,0,2))
    testing.expect(t,!graph_acyclic(&g))
    testing.expect(t,!graph_run(&js,OWNER,&g))
    testing.expect_value(t,trace.clock,i32(0))
    testing.expect(t,!graph_depend(&g,0,7))
    testing.expect(t,!graph_depend(&g,-1,0))
}

@(test)
graph_reports_exhausted_capacity :: proc(t:^testing.T) {
    g:Graph
    testing.expect(t,graph_init(&g,{node_capacity=2,edge_capacity=1}))
    defer graph_destroy(&g)
    trace:Trace
    steps:[3]Step
    for &step in steps {step={trace=&trace}}
    _,first:=graph_add(&g,step_run,&steps[0])
    _,second:=graph_add(&g,step_run,&steps[1])
    node,third:=graph_add(&g,step_run,&steps[2])
    testing.expect(t,first && second && !third)
    testing.expect_value(t,node,-1)
    testing.expect(t,graph_depend(&g,1,0))
    testing.expect(t,!graph_depend(&g,1,0))
    testing.expect_value(t,g.capacity_failures,2)
    graph_clear(&g)
    _,again:=graph_add(&g,step_run,&steps[2])
    testing.expect(t,again)
    testing.expect(t,graph_depend(&g,0,0)==true)
    testing.expect(t,!graph_acyclic(&g))
}

@(test)
random_graphs_give_the_same_values_with_and_without_threads :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    NODES :: 200
    single,threaded:Job_System
    testing.expect(t,system_init(&single,{}))
    testing.expect(t,system_init(&threaded,{threads=3,queue_capacity=16}))
    defer {system_destroy(&single);system_destroy(&threaded)}
    g:Graph
    testing.expect(t,graph_init(&g,{node_capacity=NODES,edge_capacity=NODES*8}))
    defer graph_destroy(&g)
    steps:=make([]Step,NODES)
    defer delete(steps)
    expected:=make([]u64,NODES)
    defer delete(expected)
    trace:Trace
    for round in 0..<10 {
        graph_clear(&g)
        for &step in steps {
            step={trace=&trace,seed=rand.uint64()}
            graph_add(&g,step_run,&step)
        }
        for node in 1..<NODES {
            for _ in 0..<rand.int_max(5) {
                if steps[node].dependency_count<len(steps[node].dependencies) {
                    testing.expect(t,step_depend(&g,steps,node,rand.int_max(node)))
                }
            }
        }
        testing.expect(t,graph_run(&single,OWNER,&g))
        for step,i in steps {expected[i]=step.value}
        for _ in 0..<20 {
            for &step in steps {step.finished_at=0;step.value=0}
            trace.clock=0
            testing.expect(t,graph_run(&threaded,OWNER,&g))
            testing.expect_value(t,trace.clock,i32(NODES))
            different:=0
            for step,i in steps {if step.value!=expected[i] {different+=1}}
            testing.expectf(t,different==0,"round %d: %d nodes differ",round,different)
        }
    }
    testing.expect_value(t,trace.violations,i32(0))
}

// A pinned node runs on the worker that runs the graph, after its
// dependencies and before what depends on it, whichever worker readied it.
@(test)
pinned_nodes_run_on_the_worker_that_runs_the_graph :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,120*time.Second)
    NODES :: 120
    single,threaded:Job_System
    testing.expect(t,system_init(&single,{}))
    testing.expect(t,system_init(&threaded,{threads=3,queue_capacity=16}))
    defer {system_destroy(&single);system_destroy(&threaded)}
    g:Graph
    testing.expect(t,graph_init(&g,{node_capacity=NODES,edge_capacity=NODES*8}))
    defer graph_destroy(&g)
    steps:=make([]Step,NODES)
    defer delete(steps)
    expected:=make([]u64,NODES)
    defer delete(expected)
    pinned:=make([]bool,NODES)
    defer delete(pinned)
    trace:Trace
    for round in 0..<10 {
        graph_clear(&g)
        for &step,i in steps {
            step={trace=&trace,seed=rand.uint64()}
            graph_add(&g,step_run,&step)
            pinned[i]=rand.int_max(3)==0
            if pinned[i] {testing.expect(t,graph_pin(&g,i))}
        }
        for node in 1..<NODES {
            for _ in 0..<rand.int_max(4) {
                if steps[node].dependency_count<len(steps[node].dependencies) {
                    testing.expect(t,step_depend(&g,steps,node,rand.int_max(node)))
                }
            }
        }
        testing.expect(t,graph_run(&single,OWNER,&g))
        for step,i in steps {expected[i]=step.value}
        for _ in 0..<20 {
            for &step in steps {step.finished_at=0;step.value=0;step.worker=-1}
            trace.clock=0
            testing.expect(t,graph_run(&threaded,OWNER,&g))
            testing.expect_value(t,trace.clock,i32(NODES))
            different,moved:=0,0
            for step,i in steps {
                if step.value!=expected[i] {different+=1}
                if pinned[i] && step.worker!=OWNER {moved+=1}
            }
            testing.expectf(t,different==0,"round %d: %d nodes differ",round,different)
            testing.expectf(t,moved==0,"round %d: %d pinned nodes ran on another worker",round,moved)
        }
    }
    testing.expect_value(t,trace.violations,i32(0))
    testing.expect(t,!graph_pin(&g,NODES))
}
