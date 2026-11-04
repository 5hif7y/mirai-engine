package jobs

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:thread"

// Tasks with dependencies: a node runs after every node it depends on. The
// graph is built once and run any number of times; a run allocates nothing.
// One thread at a time builds or runs a given graph. A pinned node runs on
// the worker that calls graph_run, never on another.

Graph_Desc :: struct {
    node_capacity:int, // 0: 256
    edge_capacity:int, // 0: four per node
    allocator:runtime.Allocator,
}

Graph :: struct {
    nodes:[]Graph_Node,
    edges:[]Graph_Edge,
    order:[]i32,
    pinned:[]i32,     // the pinned nodes ready in this run, in the order they became ready; -1 until written
    pinned_count:i32, // slots of pinned taken by whoever readied them
    pinned_taken:int, // the ones the runner took
    node_count,edge_count:int,
    capacity_failures:int,
    system:^Job_System,
    counter:Counter,
    checked,acyclic:bool,
    allocator:runtime.Allocator,
}

@(private)
Graph_Node :: struct {
    procedure:Job_Proc,
    data:rawptr,
    graph:^Graph,
    first_edge:i32,
    dependencies:i32,
    pending:i32,
    pinned:bool,
}

@(private)
Graph_Edge :: struct {to,next:i32}

// The graph must stay at the address it was initialized at.
graph_init :: proc(g:^Graph,desc:Graph_Desc) -> bool {
    g^={}
    g.allocator=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    nodes:=desc.node_capacity>0?desc.node_capacity:256
    edges:=desc.edge_capacity>0?desc.edge_capacity:nodes*4
    error:runtime.Allocator_Error
    if g.nodes,error=make([]Graph_Node,nodes,g.allocator);error!=nil {graph_destroy(g);return false}
    if g.edges,error=make([]Graph_Edge,edges,g.allocator);error!=nil {graph_destroy(g);return false}
    if g.order,error=make([]i32,nodes,g.allocator);error!=nil {graph_destroy(g);return false}
    if g.pinned,error=make([]i32,nodes,g.allocator);error!=nil {graph_destroy(g);return false}
    return true
}

graph_destroy :: proc(g:^Graph) {
    delete(g.nodes,g.allocator);delete(g.edges,g.allocator);delete(g.order,g.allocator);delete(g.pinned,g.allocator)
    g^={}
}

graph_clear :: proc(g:^Graph) {
    g.node_count=0;g.edge_count=0;g.checked=false
}

graph_add :: proc(g:^Graph,procedure:Job_Proc,data:rawptr) -> (node:int,ok:bool) {
    if g.node_count>=len(g.nodes) {g.capacity_failures+=1;return -1,false}
    node=g.node_count;g.node_count+=1
    g.nodes[node]={procedure=procedure,data=data,graph=g,first_edge=-1}
    g.checked=false
    return node,true
}

// node runs after dependency.
graph_depend :: proc(g:^Graph,node,dependency:int) -> bool {
    if node<0 || node>=g.node_count || dependency<0 || dependency>=g.node_count {return false}
    if g.edge_count>=len(g.edges) {g.capacity_failures+=1;return false}
    edge:=i32(g.edge_count);g.edge_count+=1
    g.edges[edge]={i32(node),g.nodes[dependency].first_edge}
    g.nodes[dependency].first_edge=edge
    g.nodes[node].dependencies+=1
    g.checked=false
    return true
}

// node runs on the worker that calls graph_run: what has to stay on that
// thread, as what queues jobs as the owner of the system.
graph_pin :: proc(g:^Graph,node:int) -> bool {
    if node<0 || node>=g.node_count {return false}
    g.nodes[node].pinned=true
    return true
}

// Runs every node and returns when all have finished. Returns false, without
// running anything, when the dependencies form a cycle. While it waits the
// caller runs the pinned nodes and queued jobs.
graph_run :: proc(js:^Job_System,worker:int,g:^Graph) -> bool {
    if !graph_acyclic(g) {return false}
    if g.node_count==0 {return true}
    nodes:=g.nodes[:g.node_count]
    for &node in nodes {node.pending=node.dependencies}
    for &slot in g.pinned[:g.node_count] {slot=-1}
    g.pinned_count,g.pinned_taken=0,0
    g.system=js
    g.counter.pending=i32(len(nodes))
    w:=&js.workers[worker]
    for &node,i in nodes {
        if node.dependencies==0 && node.pinned {graph_pinned_push(g,i32(i))}
    }
    roots:=0
    #reverse for &node in nodes {
        if node.dependencies==0 && !node.pinned {job_push(js,w,{graph_node_run,&node,&g.counter});roots+=1}
    }
    wake(js,roots)
    graph_wait(js,w,g)
    return true
}

graph_acyclic :: proc(g:^Graph) -> bool {
    if g.checked {return g.acyclic}
    nodes:=g.nodes[:g.node_count]
    ready,visited:=0,0
    for &node,i in nodes {
        node.pending=node.dependencies
        if node.pending==0 {g.order[ready]=i32(i);ready+=1}
    }
    for visited<ready {
        node:=&nodes[g.order[visited]];visited+=1
        for edge:=node.first_edge;edge>=0;edge=g.edges[edge].next {
            next:=g.edges[edge].to
            nodes[next].pending-=1
            if nodes[next].pending==0 {g.order[ready]=next;ready+=1}
        }
    }
    g.checked=true;g.acyclic=visited==len(nodes)
    return g.acyclic
}

@(private)
graph_node_run :: proc(data:rawptr,worker:int) {
    node:=cast(^Graph_Node)data
    g:=node.graph
    node.procedure(node.data,worker)
    js:=g.system
    w:=&js.workers[worker]
    ready,pinned:=0,false
    for edge:=node.first_edge;edge>=0;edge=g.edges[edge].next {
        to:=g.edges[edge].to
        next:=&g.nodes[to]
        if intrinsics.atomic_sub(&next.pending,1)!=1 {continue}
        if next.pinned {
            graph_pinned_push(g,to)
            pinned=true
        } else {
            job_push(js,w,{graph_node_run,next,&g.counter})
            ready+=1
        }
    }
    // The runner may sleep: only a broadcast is sure to reach it.
    if pinned {wake(js,max(ready,2))} else if ready>0 {wake(js,ready)}
}

@(private)
graph_pinned_push :: proc "contextless" (g:^Graph,node:i32) {
    slot:=intrinsics.atomic_add(&g.pinned_count,1)
    intrinsics.atomic_store(&g.pinned[slot],node)
}

// The next pinned node ready, for the runner alone. A slot taken whose node
// is not written yet is not ready.
@(private)
graph_pinned_take :: proc "contextless" (g:^Graph) -> (node:^Graph_Node,found:bool) {
    if g.pinned_taken>=int(intrinsics.atomic_load(&g.pinned_count)) {return}
    at:=intrinsics.atomic_load(&g.pinned[g.pinned_taken])
    if at<0 {return}
    g.pinned_taken+=1
    return &g.nodes[at],true
}

@(private)
graph_pinned_ready :: #force_inline proc "contextless" (g:^Graph) -> bool {
    return g.pinned_taken<int(intrinsics.atomic_load(&g.pinned_count))
}

// wait on the counter of g, which also runs its pinned nodes and sleeps only
// while none is ready.
@(private)
graph_wait :: proc(js:^Job_System,w:^Worker,g:^Graph) {
    spins:=0
    for intrinsics.atomic_load(&g.counter.pending)>0 {
        if node,found:=graph_pinned_take(g);found {job_execute(js,w,{graph_node_run,node,&g.counter});spins=0;continue}
        if job,found:=work_find(js,w);found {job_execute(js,w,job);spins=0;continue}
        assert(len(js.workers)>1 || graph_pinned_ready(g),"jobs.graph_run: nodes are pending and none is queued")
        spins+=1
        if spins<=SPIN_LIMIT {intrinsics.cpu_relax();continue}
        if spins<=SPIN_LIMIT+YIELD_LIMIT {thread.yield();continue}
        epoch:=intrinsics.atomic_load(&js.wake_epoch)
        intrinsics.atomic_add(&js.sleepers,1)
        intrinsics.atomic_add(&js.waiters,1)
        if intrinsics.atomic_load(&g.counter.pending)>0 && !work_available(js) && !graph_pinned_ready(g) {
            stat_add(&w.sleeps)
            sync.futex_wait(&js.wake_epoch,u32(epoch))
        }
        intrinsics.atomic_sub(&js.waiters,1)
        intrinsics.atomic_sub(&js.sleepers,1)
        spins=0
    }
}
