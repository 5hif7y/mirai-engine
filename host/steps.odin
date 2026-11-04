package host

import "base:runtime"
import "mirai:core"
import "mirai:std/jobs"

// The functions of a loop and phase run as a graph of jobs on the workers of
// the application: what the edges of the World_Info do not order runs at
// once, and the main ones on the thread of the loop. With one worker, a world
// that does not give its edges, a graph that cannot be built or that is a
// chain, or a phase that runs again from inside itself (a correction of the
// network replays fixed ticks), they run in order. -define:MIRAI_STEPS_SEQUENTIAL=true always runs
// them in order.
STEPS_SEQUENTIAL :: #config(MIRAI_STEPS_SEQUENTIAL,false)

// The graph of a loop and phase, built from the order and the edges of one
// World_Info: another library builds it again the first time it runs.
@(private)
Step_Graph :: struct {
    graph:jobs.Graph,
    nodes:[]Step_Node,
    order:[]i32,
    edges:[]core.Step_Edge,
    steps:[]core.Step_Info,
    failed:bool, // they run in order: it could not be built from these, or they wait each for the one before
    running:bool,
    world,shared,editor:rawptr,
    app:^App,
    caller:runtime.Context,
}

@(private)
Step_Node :: struct {
    graph:^Step_Graph,
    call:core.Step_Proc,
}

// Runs the phase as a graph; false when it has to run in order.
@(private)
steps_run :: proc(app:^App,loop:core.Loop,phase:core.Phase,world,editor:rawptr) -> bool {
    when STEPS_SEQUENTIAL {return false}
    info:=app.info
    if info==nil || !info.parallel || len(info.order[loop][phase])<2 || jobs.worker_count(&app.jobs)<2 {return false}
    sg:=&app.step_graphs[loop][phase]
    if sg.running {return false}
    if !step_graph_current(sg,info,loop,phase) {step_graph_build(app,sg,loop,phase)}
    if sg.failed {return false}
    sg.world,sg.shared,sg.editor,sg.app,sg.caller=world,app.shared,editor,app,context
    sg.running=true
    ran:=jobs.graph_run(&app.jobs,jobs.OWNER,&sg.graph)
    sg.running=false
    return ran
}

@(private)
step_graph_current :: proc(sg:^Step_Graph,info:^core.World_Info,loop:core.Loop,phase:core.Phase) -> bool {
    order,edges:=info.order[loop][phase],info.edges[loop][phase]
    return sg.order!=nil && raw_data(sg.order)==raw_data(order) && len(sg.order)==len(order) &&
        raw_data(sg.edges)==raw_data(edges) && len(sg.edges)==len(edges) &&
        raw_data(sg.steps)==raw_data(info.steps) && len(sg.steps)==len(info.steps)
}

@(private)
step_graph_build :: proc(app:^App,sg:^Step_Graph,loop:core.Loop,phase:core.Phase) {
    step_graph_free(app,sg)
    info:=app.info
    order,edges:=info.order[loop][phase],info.edges[loop][phase]
    sg.order,sg.edges,sg.steps,sg.failed=order,edges,info.steps,true
    if !jobs.graph_init(&sg.graph,{node_capacity=len(order),edge_capacity=max(len(edges),1),allocator=app.allocator}) {return}
    nodes,error:=make([]Step_Node,len(order),app.allocator)
    if error!=nil {return}
    sg.nodes=nodes
    for index,i in order {
        if index<0 || int(index)>=len(info.steps) {return}
        step:=&info.steps[index]
        sg.nodes[i]={sg,step.call}
        if _,added:=jobs.graph_add(&sg.graph,step_node_run,&sg.nodes[i]);!added {return}
        if step.main {jobs.graph_pin(&sg.graph,i)}
    }
    chain:=len(edges)==len(order)-1
    for edge in edges {
        if edge.first>=edge.then || !jobs.graph_depend(&sg.graph,int(edge.then),int(edge.first)) {return}
        chain&&=edge.then==edge.first+1
    }
    // Each one waits for the one before: nothing runs at once, and the jobs would only cost.
    sg.failed=chain || !jobs.graph_acyclic(&sg.graph)
}

@(private)
step_graph_free :: proc(app:^App,sg:^Step_Graph) {
    jobs.graph_destroy(&sg.graph)
    delete(sg.nodes,app.allocator)
    sg^={}
}

@(private)
steps_free :: proc(app:^App) {
    for &graphs in app.step_graphs {
        for &sg in graphs {step_graph_free(app,&sg)}
    }
}

// A function of the graph, with the context of whoever runs the phase and
// the temporary memory of the thread that runs it.
@(private)
step_node_run :: proc(data:rawptr,worker:int) {
    node:=cast(^Step_Node)data
    sg:=node.graph
    temp:=context.temp_allocator
    context=sg.caller
    context.temp_allocator=temp
    node.call(sg.world,sg.shared,sg.editor,sg.app,worker)
}
