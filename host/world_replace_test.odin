package host

import "base:runtime"
import "core:mem"
import "core:testing"
import "mirai:core"

@(private) Replace_Local :: struct {mark:u32}
@(private) Replace_World :: struct {entities:core.Entities,values:core.Table(u32),state:[dynamic]u32,local:Replace_Local}

@(private)
replace_init :: proc(data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Replace_World)data
    if !core.entities_init(&w.entities,allocator) {return false}
    core.table_init(&w.values,"values",allocator)
    w.state=make([dynamic]u32,allocator)
    return true
}

@(private)
replace_destroy :: proc(data:rawptr) {
    w:=cast(^Replace_World)data
    core.table_destroy(&w.values)
    delete(w.state)
    core.entities_destroy(&w.entities)
}

@(private)
replace_copy :: proc(dst,src:rawptr) -> bool {
    d,s:=cast(^Replace_World)dst,cast(^Replace_World)src
    return core.entities_copy(&d.entities,&s.entities) && core.table_copy(&d.values,&s.values) && core.value_copy(&d.state,&s.state,type_info_of([dynamic]u32))
}

@(private)
replace_swap :: proc(a,b:rawptr) {
    a,b:=cast(^Replace_World)a,cast(^Replace_World)b
    a.entities,b.entities=b.entities,a.entities
    core.table_swap(&a.values,&b.values)
    a.state,b.state=b.state,a.state
}

@(test)
world_replacement_out_of_memory_keeps_the_destination_and_a_warm_one_does_not_allocate :: proc(t:^testing.T) {
    info:=core.World_Info{
        sizes={.World=size_of(Replace_World),.Shared=0,.Editor=0},aligns={.World=align_of(Replace_World),.Shared=1,.Editor=1},
        init={.World=replace_init,.Shared=nil,.Editor=nil},destroy={.World=replace_destroy,.Shared=nil,.Editor=nil},
        copy=replace_copy,swap=replace_swap,
    }
    source:Replace_World
    testing.expect(t,replace_init(&source,context.allocator))
    defer replace_destroy(&source)
    for value in 0..<40 {
        e:=core.create(&source.entities)
        core.add(&source.values,e,u32(value))
        append(&source.state,u32(value*3))
    }
    core.table_settle(&source.values,&source.entities)
    succeeded,failed:=false,false
    for budget in 0..<32 {
        tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator)
        allocation:=World_Create_Allocation{owner=mem.tracking_allocator(&tracking),remaining=-1}
        app:=App{info=&info,allocator={world_create_allocator,&allocation}}
        app.worlds=make([dynamic]World_Slot,app.allocator)
        live:=cast(^Replace_World)app_world_create(&app)
        if !testing.expect(t,live!=nil) {return}
        kept:=core.create(&live.entities)
        core.add(&live.values,kept,7);core.table_settle(&live.values,&live.entities)
        append(&live.state,9)
        live.local.mark=5
        values,state:=raw_data(live.values.values),raw_data(live.state)
        version:=core.version(&live.values)
        allocation.remaining=budget
        ok:=app_world_replace(&app,live,&source)
        allocation.remaining=-1
        if !ok {
            failed=true
            testing.expect(t,core.has(&live.values,kept) && core.count(&live.values)==1)
            testing.expect(t,raw_data(live.values.values)==values && raw_data(live.state)==state && len(live.state)==1)
            testing.expect_value(t,core.version(&live.values),version)
        } else {
            succeeded=true
            testing.expect_value(t,core.count(&live.values),40)
            testing.expect_value(t,len(live.state),40)
            testing.expect_value(t,live.state[39],u32(117))
            testing.expect(t,raw_data(live.state)!=raw_data(source.state))
            testing.expect(t,core.version(&live.values)>version)
            testing.expect_value(t,live.local.mark,u32(5))
            // The contents it traded are the room of the next ones: once both
            // sides fit the source, a replacement allocates nothing.
            testing.expect(t,app_world_replace(&app,live,&source))
            allocation.remaining=0
            saved:=context
            context.allocator=mem.nil_allocator()
            testing.expect(t,app_world_replace(&app,live,&source))
            context=saved
            testing.expect_value(t,core.count(&live.values),40)
        }
        app_world_free(&app,live)
        app_world_scratch_free(&app)
        delete(app.worlds)
        testing.expect_value(t,len(tracking.allocation_map),0)
        mem.tracking_allocator_destroy(&tracking)
        testing.expect_value(t,core.count(&source.values),40)
        if ok {break}
    }
    testing.expect(t,succeeded && failed)
}
