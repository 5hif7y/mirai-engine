package mirai_net

import "base:runtime"
import "core:math"
import "core:mem"
import mm "mirai:std/math"

// Prediction and reconciliation over plain bytes. The driver knows nothing of
// what it simulates: it keeps the input and the resulting state of the last
// ticks in two rings and calls back to save, restore and advance the
// simulation. When the authoritative state of a past tick differs from what
// was predicted, it restores that state and simulates again up to the present
// with the inputs it kept.

Rollback_Desc :: struct {
    state_size,input_size:int,
    history:int,        // ticks kept, default 64
    max_resimulate:int, // ticks one correction may replay before giving up prediction, default history
    user:rawptr,
    save:proc(user:rawptr,state:[]u8),                 // copy the simulation into state
    restore:proc(user:rawptr,state:[]u8),              // replace the simulation with state
    simulate:proc(user:rawptr,tick:u32,input:[]u8),    // advance one tick
    equal:proc(user:rawptr,predicted,authoritative:[]u8) -> bool, // nil compares the bytes
    allocator:runtime.Allocator,
}

Reconcile_Result :: enum u8 {
    Confirmed, // the prediction was right
    Corrected, // restored and simulated again up to the present
    Snapped,   // too far to replay, or ahead of anything simulated: the authoritative state was taken as is
    Stale,     // not newer than a tick already reconciled: ignored
}

Rollback_Stats :: struct {
    ticks,confirmed,corrected,snapped,stale:u64,
    resimulated:u64,          // ticks simulated again, in total
    largest_resimulation:int,
}

Rollback :: struct {
    desc:Rollback_Desc,
    states,inputs:[]u8,
    ticks:[]u32,      // per slot, the tick it holds plus one
    newest:u32,
    reconciled:u32,
    any,any_reconciled:bool,
    stats:Rollback_Stats,
}

rollback_init :: proc(r:^Rollback,desc:Rollback_Desc) -> Error {
    r^={desc=desc}
    d:=&r.desc
    if d.state_size<=0 || d.input_size<0 || d.save==nil || d.restore==nil || d.simulate==nil {return .Invalid}
    if d.history<=0 {d.history=64}
    if d.max_resimulate<=0 || d.max_resimulate>d.history-1 {d.max_resimulate=d.history-1}
    if d.allocator.procedure==nil {d.allocator=context.allocator}
    error:mem.Allocator_Error
    if r.states,error=make([]u8,d.history*d.state_size,d.allocator);error!=nil {return .Out_Of_Memory}
    if r.inputs,error=make([]u8,d.history*max(d.input_size,1),d.allocator);error!=nil {rollback_destroy(r);return .Out_Of_Memory}
    if r.ticks,error=make([]u32,d.history,d.allocator);error!=nil {rollback_destroy(r);return .Out_Of_Memory}
    return .None
}
rollback_destroy :: proc(r:^Rollback) {
    delete(r.states,r.desc.allocator);delete(r.inputs,r.desc.allocator);delete(r.ticks,r.desc.allocator)
    r^={}
}
// Forgets the history, as after a teleport of the clock.
rollback_reset :: proc(r:^Rollback) {
    mem.zero_slice(r.ticks)
    r.any,r.any_reconciled=false,false
}

@(private)
rollback_slot :: #force_inline proc(r:^Rollback,tick:u32) -> int {return int(tick%u32(r.desc.history))}
// State after a tick and the input that produced it, while they are in the history.
rollback_state :: proc(r:^Rollback,tick:u32) -> ([]u8,bool) {
    slot:=rollback_slot(r,tick)
    if r.ticks[slot]!=tick+1 {return nil,false}
    return r.states[slot*r.desc.state_size:][:r.desc.state_size],true
}
rollback_input :: proc(r:^Rollback,tick:u32) -> ([]u8,bool) {
    slot:=rollback_slot(r,tick)
    if r.ticks[slot]!=tick+1 {return nil,false}
    return r.inputs[slot*r.desc.input_size:][:r.desc.input_size],true
}

// Simulates a tick with its input and remembers both. Ticks must go forward.
rollback_step :: proc(r:^Rollback,tick:u32,input:[]u8) {
    d:=&r.desc
    slot:=rollback_slot(r,tick)
    kept:=r.inputs[slot*d.input_size:][:d.input_size]
    copy(kept,input)
    d.simulate(d.user,tick,kept)
    d.save(d.user,r.states[slot*d.state_size:][:d.state_size])
    r.ticks[slot]=tick+1
    r.newest,r.any=tick,true
    r.stats.ticks+=1
}

// The server's state after tick arrived. authoritative has the layout save writes.
rollback_reconcile :: proc(r:^Rollback,tick:u32,authoritative:[]u8) -> Reconcile_Result {
    d:=&r.desc
    if len(authoritative)!=d.state_size {return .Stale}
    if r.any_reconciled && i32(tick-r.reconciled)<=0 {r.stats.stale+=1;return .Stale}
    slot:=rollback_slot(r,tick)
    state:=r.states[slot*d.state_size:][:d.state_size]
    behind:=r.any?int(i32(r.newest-tick)):-1
    if behind<0 || behind>d.max_resimulate || (behind>=0 && r.ticks[slot]!=tick+1) {
        // Nothing to replay from: the present becomes the authoritative state.
        d.restore(d.user,authoritative)
        target:=behind<0?tick:r.newest
        mem.zero_slice(r.ticks)
        at:=rollback_slot(r,target)
        copy(r.states[at*d.state_size:][:d.state_size],authoritative)
        mem.zero_slice(r.inputs[at*d.input_size:][:d.input_size])
        r.ticks[at]=target+1
        r.newest,r.any,r.reconciled,r.any_reconciled=target,true,tick,true
        r.stats.snapped+=1
        return .Snapped
    }
    same:=d.equal!=nil?d.equal(d.user,state,authoritative):mem.compare(state,authoritative)==0
    if same {
        r.reconciled,r.any_reconciled=tick,true
        r.stats.confirmed+=1
        return .Confirmed
    }
    copy(state,authoritative)
    rollback_correct(r,tick)
    return .Corrected
}

// The state kept for a tick is wrong for a reason the caller knows: restore gets it, to put right what it found
// wrong, and the ticks after it run again up to the present. False when the tick is not in the history or farther
// than max_resimulate.
rollback_correct :: proc(r:^Rollback,tick:u32) -> bool {
    d:=&r.desc
    slot:=rollback_slot(r,tick)
    behind:=r.any?int(i32(r.newest-tick)):-1
    if behind<0 || behind>d.max_resimulate || r.ticks[slot]!=tick+1 {return false}
    r.reconciled,r.any_reconciled=tick,true
    d.restore(d.user,r.states[slot*d.state_size:][:d.state_size])
    for step in 1..=u32(behind) {
        at:=rollback_slot(r,tick+step)
        d.simulate(d.user,tick+step,r.inputs[at*d.input_size:][:d.input_size])
        d.save(d.user,r.states[at*d.state_size:][:d.state_size])
    }
    r.stats.corrected+=1
    r.stats.resimulated+=u64(behind)
    r.stats.largest_resimulation=max(r.stats.largest_resimulation,behind)
    return true
}

// Hides corrections from the eye: when the simulated pose jumps, the offset
// to where it was shown is kept and fades out, while the simulation itself
// stays exactly where the correction put it.
Smoothing :: struct {
    offset:[3]f32,
    rotation:quaternion128,
    half_life:f32,     // seconds for an error to halve, default 0.08
    snap_distance:f32, // meters beyond which the error is not smoothed, default 4
}

smoothing_init :: proc "contextless" (s:^Smoothing,half_life:f32=0.08,snap_distance:f32=4) {
    s^={rotation=quaternion(w=1,x=0,y=0,z=0),half_life=half_life,snap_distance=snap_distance}
}
// The simulated pose went from before to after without the object having moved: a correction.
smoothing_correct :: proc "contextless" (s:^Smoothing,before_position,after_position:[3]f32,before_rotation,after_rotation:quaternion128) {
    s.offset+=before_position-after_position
    s.rotation=s.rotation*before_rotation*conj(after_rotation)
    if s.offset.x*s.offset.x+s.offset.y*s.offset.y+s.offset.z*s.offset.z>s.snap_distance*s.snap_distance {
        s.offset,s.rotation={},quaternion(w=1,x=0,y=0,z=0)
    }
}
smoothing_update :: proc "contextless" (s:^Smoothing,dt:f32) {
    keep:=s.half_life>0?math.pow(0.5,dt/s.half_life):0
    s.offset*=keep
    s.rotation=mm.quat_nlerp(1,s.rotation,keep)
}
// Where to draw an object whose simulated pose is position and rotation.
smoothing_apply :: proc "contextless" (s:^Smoothing,position:[3]f32,rotation:quaternion128) -> ([3]f32,quaternion128) {
    return position+s.offset,s.rotation*rotation
}

// Snapshots of remote objects by server tick, to draw them between two known
// states a little behind the newest one instead of jumping when one arrives.
Interpolation_Desc :: struct {
    state_size:int,
    capacity:int, // objects
    depth:int,    // snapshots kept per object, default 8
    allocator:runtime.Allocator,
}
Interpolation_Status :: enum u8 {
    Empty,
    Between, // a and b surround the tick: blend with alpha
    Before,  // the tick is older than everything kept: a and b are the oldest
    After,   // newer than everything kept: a and b are the newest, and alpha is how many ticks past it the tick is
}
Interpolation :: struct {
    desc:Interpolation_Desc,
    data:[]u8,
    ticks:[]u32,
    spacing:[]f32, // per slot: ticks between its snapshots
    head,count:[]u8,
    used:[]bool,
    free:[]u32,
    free_count:int,
}

interpolation_init :: proc(i:^Interpolation,desc:Interpolation_Desc) -> Error {
    i^={desc=desc}
    d:=&i.desc
    if d.state_size<=0 || d.capacity<=0 {return .Invalid}
    d.depth=d.depth<=0?8:min(d.depth,255)
    if d.allocator.procedure==nil {d.allocator=context.allocator}
    error:mem.Allocator_Error
    if i.data,error=make([]u8,d.capacity*d.depth*d.state_size,d.allocator);error!=nil {return .Out_Of_Memory}
    if i.ticks,error=make([]u32,d.capacity*d.depth,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.spacing,error=make([]f32,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.head,error=make([]u8,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.count,error=make([]u8,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.used,error=make([]bool,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    if i.free,error=make([]u32,d.capacity,d.allocator);error!=nil {interpolation_destroy(i);return .Out_Of_Memory}
    for &slot,index in i.free {slot=u32(d.capacity-1-index)}
    i.free_count=d.capacity
    return .None
}
interpolation_destroy :: proc(i:^Interpolation) {
    a:=i.desc.allocator
    delete(i.data,a);delete(i.ticks,a);delete(i.spacing,a);delete(i.head,a);delete(i.count,a);delete(i.used,a);delete(i.free,a)
    i^={}
}
// Takes a slot for one object. ok is false when every slot is taken.
interpolation_add :: proc(i:^Interpolation) -> (slot:int,ok:bool) {
    if i.free_count==0 {return -1,false}
    i.free_count-=1
    slot=int(i.free[i.free_count])
    i.used[slot],i.head[slot],i.count[slot],i.spacing[slot]=true,0,0,0
    return slot,true
}
interpolation_remove :: proc(i:^Interpolation,slot:int) {
    if slot<0 || slot>=len(i.used) || !i.used[slot] {return}
    i.used[slot]=false
    i.free[i.free_count]=u32(slot)
    i.free_count+=1
}
// Forgets the snapshots of a slot, as after a teleport.
interpolation_clear :: proc(i:^Interpolation,slot:int) {
    if slot>=0 && slot<len(i.used) {i.head[slot],i.count[slot],i.spacing[slot]=0,0,0}
}
// Adds the state of a tick. Snapshots that are not newer than the last one are ignored.
interpolation_push :: proc(i:^Interpolation,slot:int,tick:u32,state:[]u8) -> bool {
    d:=&i.desc
    if slot<0 || slot>=len(i.used) || !i.used[slot] || len(state)!=d.state_size {return false}
    count,head:=int(i.count[slot]),int(i.head[slot])
    if count>0 {
        gap:=i32(tick-i.ticks[slot*d.depth+(head+count-1)%d.depth])
        if gap<=0 {return false}
        // A longer gap counts at once, a shorter one slowly: the states of an object may come less often for a while.
        spacing:=&i.spacing[slot]
        spacing^=f32(gap)>spacing^?f32(gap):spacing^+(f32(gap)-spacing^)*0.125
    }
    at:=(head+count)%d.depth
    if count==d.depth {i.head[slot]=u8((head+1)%d.depth)} else {i.count[slot]+=1}
    i.ticks[slot*d.depth+at]=tick
    copy(i.data[(slot*d.depth+at)*d.state_size:][:d.state_size],state)
    return true
}
// The two snapshots around a tick with fraction and how far between them it lies.
interpolation_sample :: proc(i:^Interpolation,slot:int,tick:f64) -> (a,b:[]u8,alpha:f32,status:Interpolation_Status) {
    d:=&i.desc
    if slot<0 || slot>=len(i.used) || !i.used[slot] || i.count[slot]==0 {return}
    count,head:=int(i.count[slot]),int(i.head[slot])
    entry :: proc(i:^Interpolation,slot,at:int) -> ([]u8,u32) {
        d:=&i.desc
        return i.data[(slot*d.depth+at)*d.state_size:][:d.state_size],i.ticks[slot*d.depth+at]
    }
    newest,newest_tick:=entry(i,slot,(head+count-1)%d.depth)
    oldest,oldest_tick:=entry(i,slot,head)
    behind:=f64(newest_tick)-tick
    if behind<=0 {return newest,newest,f32(-behind),.After}
    if behind>=f64(newest_tick-oldest_tick) {return oldest,oldest,0,.Before}
    for k:=count-1;k>0;k-=1 {
        later,later_tick:=entry(i,slot,(head+k)%d.depth)
        earlier,earlier_tick:=entry(i,slot,(head+k-1)%d.depth)
        span:=f64(later_tick-earlier_tick)
        back:=f64(newest_tick-later_tick)
        if behind<=back+span {return earlier,later,f32(1-(behind-back)/span),.Between}
    }
    return oldest,oldest,0,.Before
}

// The newest snapshot of a slot and its tick; ok is false while it has none.
interpolation_newest :: proc(i:^Interpolation,slot:int) -> (state:[]u8,tick:u32,ok:bool) {
    d:=&i.desc
    if slot<0 || slot>=len(i.used) || !i.used[slot] || i.count[slot]==0 {return}
    at:=slot*d.depth+(int(i.head[slot])+int(i.count[slot])-1)%d.depth
    return i.data[at*d.state_size:][:d.state_size],i.ticks[at],true
}
// Ticks between the snapshots of a slot: at once the longest gap, and slowly a shorter one. 0 before the second.
interpolation_spacing :: proc(i:^Interpolation,slot:int) -> f32 {
    if slot<0 || slot>=len(i.used) || !i.used[slot] {return 0}
    return i.spacing[slot]
}
