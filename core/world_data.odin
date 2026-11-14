package core

import "base:runtime"
import "core:mem"
import "core:slice"

// Makes, frees, copies, swaps and clears the structs a World_Info describes:
// a World, the Shared of its application and the Editor, each a struct of
// tables and storages at the offsets its lists give.

@(private="file")
table_of :: #force_inline proc "contextless" (data:rawptr,t:^Table_Info) -> ^Raw_Table {return cast(^Raw_Table)(uintptr(data)+t.offset)}

@(private="file")
storage_of :: #force_inline proc "contextless" (data:rawptr,s:^Storage_Info) -> rawptr {return rawptr(uintptr(data)+s.offset)}

@(private="file")
entities_of :: #force_inline proc "contextless" (info:^World_Info,world:rawptr) -> ^Entities {return cast(^Entities)(uintptr(world)+info.entities)}

@(private="file")
ids_of :: #force_inline proc "contextless" (info:^World_Info,world:rawptr,id:int) -> ^Table(Id) {
    return cast(^Table(Id))table_of(world,&info.tables[id])
}

@(private="file")
revisions_of :: #force_inline proc "contextless" (info:^World_Info,world:rawptr) -> []u64 {
    return world_revisions({world,info,.World})
}

@(private="file")
storage_free :: proc(s:^Storage_Info,value:rawptr) {
    if s.procs.free!=nil {s.procs.free(value)} else {value_free(value,s.info)}
}

// kept: into the copy a history keeps.
@(private="file")
storage_copy :: proc(s:^Storage_Info,dst,src:rawptr,kept:bool) -> bool {
    copy:=kept && s.procs.copy_kept!=nil?s.procs.copy_kept:s.procs.copy
    switch {
    case copy!=nil: return copy(dst,src)
    case s.flat:    mem.copy(dst,src,s.info.size)
    case:           return value_copy(dst,src,s.info)
    }
    return true
}

// Starts the struct of a place: its tables empty and its storages at their
// defaults. False without memory, with a struct that world_destroy frees.
world_init :: proc(info:^World_Info,place:Place,data:rawptr,allocator:runtime.Allocator) -> bool {
    context.allocator=allocator
    es:^Entities
    if place==.World {
        es=entities_of(info,data)
        if !entities_init(es,allocator) || !entities_tables(es,len(info.tables)) {return false}
    }
    for &t,at in info.tables {
        if t.place!=place {continue}
        table:=table_of(data,&t)
        raw_init(table,t.name,allocator)
        // Its place in info.tables is where settle finds what it has pending.
        if es!=nil {raw_follow(table,es,at)}
        table.base,table.single,table.locks=t.base,t.single,t.locks
    }
    for &s in info.storages {
        if s.place==place && !s.by_world && s.default!=nil {s.default(storage_of(data,&s))}
    }
    // What a storage starts as is its first value: who reads it by change takes it.
    if place==.World {revisions_moved(revisions_of(info,data))}
    return true
}

world_destroy :: proc(info:^World_Info,place:Place,data:rawptr) {
    for &t in info.tables {
        if t.place==place {raw_destroy(table_of(data,&t),t.info.size)}
    }
    for &s in info.storages {
        if s.place!=place {continue}
        if !s.by_world {
            storage_free(&s,storage_of(data,&s))
            continue
        }
        held:=cast(^By_World(u8))storage_of(data,&s)
        for entry in held.entries {
            if entry.value==nil {continue}
            storage_free(&s,entry.value)
            by_world_release(held,entry.value)
        }
        delete(held.entries)
    }
    if place==.World {entities_destroy(entities_of(info,data))}
}

// Makes the World dst a copy of src; what says copy=false stays. False
// without memory: dst is left partial, to destroy or to copy over.
world_copy :: proc(info:^World_Info,dst,src:rawptr) -> bool {return copy_marked(info,dst,src,nil)}

// The copy a history keeps: for a dst that is a copy of src, it copies again
// only the tables that changed (raw_copy_changed) and the storages whose
// revision moved since the marks, which it updates: copy_marks_count of them,
// one per table by its index in tables, then one per storage; with fewer it
// copies whole. dst is only copied back with world_copy: the storages that
// say copy_kept hold there only what that needs.
world_copy_changed :: proc(info:^World_Info,dst,src:rawptr,marks:[]Copy_Mark) -> bool {
    return copy_marked(info,dst,src,len(marks)<copy_marks_count(info)?nil:marks)
}

// The index of the entities by Id comes with them and goes on following the
// table of Id that comes with it.
@(private="file")
copy_marked :: proc(info:^World_Info,dst,src:rawptr,marks:[]Copy_Mark) -> bool {
    if dst==src {return true}
    changed:=marks!=nil
    to,from:=entities_of(info,dst),entities_of(info,src)
    context.allocator=to.generation.allocator
    found:=settles(info)
    synced:=found.id>=0 && ids_synced(from,ids_of(info,src,found.id))
    if !entities_copy(to,from) {return false}
    for &t,at in info.tables {
        if t.place!=.World {continue}
        if changed {
            if !raw_copy_changed(table_of(dst,&t),table_of(src,&t),t.info,t.flat,&marks[at]) {return false}
        } else if !raw_copy(table_of(dst,&t),table_of(src,&t),t.info,t.flat) {return false}
    }
    to_revisions,from_revisions:=revisions_of(info,dst),revisions_of(info,src)
    first:=len(info.tables)
    for &s,k in info.storages {
        if s.place!=.World || s.local {continue}
        a,b:=storage_of(dst,&s),storage_of(src,&s)
        if changed && !storage_changed(&marks[first+k],from_revisions[k]) {
            when CHECK_WRITES {if s.procs.copy==nil && s.procs.copy_kept==nil {storage_check(a,b,s.info,s.name)}}
            continue
        }
        if !storage_copy(&s,a,b,changed) {return false}
        if changed {storage_copied(&marks[first+k],&to_revisions[k],from_revisions[k])}
    }
    if !changed {revisions_copied(to_revisions,from_revisions)}
    if found.id>=0 {ids_moved(to,ids_of(info,dst,found.id),synced)}
    return true
}

// Whether a World still has a table, or a storage, as the copy a mark is of
// took it: nothing of it is to bring back from that copy.
@(private="file")
table_kept :: #force_inline proc "contextless" (t:^Raw_Table,mark:Copy_Mark) -> bool {
    return mark.valid && mark.version==t.version && mark.layout==t.layout && len(t.pending)==0
}

@(private="file")
storage_kept :: #force_inline proc "contextless" (revisions:[]u64,k:int,mark:Copy_Mark) -> bool {
    return mark.valid && mark.version==revisions[k]
}

// Makes the World dst what src holds, for a src that world_copy_changed
// keeps as a copy of dst with marks: the tables dst still has as that copy
// took them, with nothing pending, and the storages whose revision did not
// move since, stay as they are, and their readers see no change. A table of
// flat values that still holds the rows of the copy, on and off, takes back
// in place the rows that differ (raw_restore): its readers see those rows
// alone; a storage of plain data takes back its bytes. The other tables and
// storages are copied into stage, a third World, and then traded with dst
// without allocating, and their readers read them whole. All or nothing:
// false without memory, with dst as it was. With fewer marks than
// copy_marks_count all of it is copied and traded. mixed: stage is left with
// parts of several Worlds, to stage another copy in or to clear, never to
// run; false after all of it was traded.
world_restore :: proc(info:^World_Info,dst,src,stage:rawptr,marks:[]Copy_Mark) -> (ok,mixed:bool) {
    if dst==src {return true,false}
    if len(marks)<copy_marks_count(info) {
        if !world_copy(info,stage,src) {return false,true}
        world_swap(info,dst,stage)
        return true,false
    }
    to,from,held:=entities_of(info,dst),entities_of(info,src),entities_of(info,stage)
    context.allocator=held.generation.allocator
    found:=settles(info)
    synced:=found.id>=0 && ids_synced(from,ids_of(info,src,found.id))
    if !entities_copy(held,from) {return false,true}
    revisions,staged:=revisions_of(info,dst),revisions_of(info,stage)
    first:=len(info.tables)
    for &t,at in info.tables {
        live:=table_of(dst,&t)
        if t.place!=.World || table_kept(live,marks[at]) || t.flat && restore_since(live,table_of(src,&t),marks[at])>=0 {continue}
        if !raw_copy(table_of(stage,&t),table_of(src,&t),t.info,t.flat) {return false,true}
    }
    for &s,k in info.storages {
        if s.place!=.World || s.local || storage_kept(revisions,k,marks[first+k]) || s.flat && s.procs=={} {continue}
        if !storage_copy(&s,storage_of(stage,&s),storage_of(src,&s),false) {return false,true}
    }
    slice.ptr_swap_non_overlapping(to,held,size_of(Entities))
    for &t,at in info.tables {
        if t.place!=.World {continue}
        live,from:=table_of(dst,&t),table_of(src,&t)
        if table_kept(live,marks[at]) {
            table_waits(live,false)
        } else if since:=restore_since(live,from,marks[at]);t.flat && since>=0 {
            raw_restore(live,from,t.info.size,since)
        } else {raw_swap(live,table_of(stage,&t))}
    }
    for &s,k in info.storages {
        if s.place!=.World || s.local || storage_kept(revisions,k,marks[first+k]) {continue}
        x,y:=storage_of(dst,&s),storage_of(stage,&s)
        if s.flat && s.procs=={} {mem.copy(x,storage_of(src,&s),s.info.size)} else if s.procs.swap!=nil {s.procs.swap(x,y)} else {slice.ptr_swap_non_overlapping(x,y,s.info.size)}
        revisions[k]=max(revisions[k],staged[k])+1
        staged[k]=revisions[k]
    }
    if found.id>=0 {
        ids_moved(to,ids_of(info,dst,found.id),synced)
        ids_moved(held,ids_of(info,stage,found.id),false)
    }
    if info.events_rewind!=nil {info.events_rewind(dst)}
    return true,true
}

// Trades what two Worlds hold without allocating: what publishes a World
// prepared apart. What says copy=false stays in each.
world_swap :: proc(info:^World_Info,a,b:rawptr) {
    if a==b {return}
    ea,eb:=entities_of(info,a),entities_of(info,b)
    found:=settles(info)
    a_synced:=found.id>=0 && ids_synced(ea,ids_of(info,a,found.id))
    b_synced:=found.id>=0 && ids_synced(eb,ids_of(info,b,found.id))
    slice.ptr_swap_non_overlapping(ea,eb,size_of(Entities))
    for &t in info.tables {
        if t.place==.World {raw_swap(table_of(a,&t),table_of(b,&t))}
    }
    for &s in info.storages {
        if s.place!=.World || s.local {continue}
        x,y:=storage_of(a,&s),storage_of(b,&s)
        if s.procs.swap!=nil {s.procs.swap(x,y)} else {slice.ptr_swap_non_overlapping(x,y,s.info.size)}
    }
    revisions_swapped(revisions_of(info,a),revisions_of(info,b))
    if found.id>=0 {
        ids_moved(ea,ids_of(info,a,found.id),b_synced)
        ids_moved(eb,ids_of(info,b,found.id),a_synced)
    }
    if info.events_rewind!=nil {info.events_rewind(a);info.events_rewind(b)}
}

// Where two Worlds of one info differ, as the first storage that says diff=
// and finds a difference tells it, written into buf: its name and that text;
// empty when none does. What a divergence already found asks, never a tick.
world_diff :: proc(info:^World_Info,a,b:rawptr,buf:[]byte) -> (storage,text:string) {
    for &s in info.storages {
        if s.place!=.World || s.procs.diff==nil {continue}
        if text=s.procs.diff(storage_of(a,&s),storage_of(b,&s),buf);text!="" {return s.name,text}
    }
    return
}

// Takes every entity and row of a World, and its storages derived from them
// go back to their start: the settings, the storages that say keep and those
// that are not copied stay. False without memory: the World as it was.
world_clear :: proc(info:^World_Info,world:rawptr) -> bool {
    if !entities_clear(entities_of(info,world)) {return false}
    for &t in info.tables {
        if t.place==.World {raw_clear(table_of(world,&t))}
    }
    for &s in info.storages {
        if s.place!=.World || s.keep || s.setting!=.None || s.local {continue}
        value:=storage_of(world,&s)
        if s.procs.reset!=nil {
            s.procs.reset(value)
            continue
        }
        storage_free(&s,value)
        mem.zero(value,s.info.size)
        if s.default!=nil {s.default(value)}
    }
    revisions_moved(revisions_of(info,world))
    return true
}

// Gives a World with an id its value of every by_world storage of the
// Shared, at its default. False without memory.
world_attach :: proc(info:^World_Info,world,shared:rawptr,allocator:runtime.Allocator) -> bool {
    found:=settles(info)
    if found.world_id<0 {return true}
    id:=(cast(^World_Id)storage_of(world,&info.storages[found.world_id]))^
    if id.generation==0 {return true}
    context.allocator=allocator
    for &s in info.storages {
        if !s.by_world {continue}
        value:=by_world_room(cast(^By_World(u8))storage_of(shared,&s),id,s.info.size,s.info.align,allocator)
        if value==nil {return false}
        mem.zero(value,s.info.size)
        if s.default!=nil {s.default(value)}
    }
    return true
}

// Frees the values of the by_world storages of a World, after its release phase.
world_detach :: proc(info:^World_Info,world,shared:rawptr) {
    found:=settles(info)
    if found.world_id<0 {return}
    id:=(cast(^World_Id)storage_of(world,&info.storages[found.world_id]))^
    for &s in info.storages {
        if !s.by_world {continue}
        held:=cast(^By_World(u8))storage_of(shared,&s)
        if value:=by_world_detach(held,id);value!=nil {
            storage_free(&s,value)
            by_world_release(held,value)
        }
    }
}

// The bytes the tables and storages of a World hold behind their pointers:
// the capacity of the arrays, maps and slices of each table and storage of
// the place World, and of its entities. It reads capacities, not the
// allocator, so what game code allocates outside its storages is not in it.
// elements: the values it had to step into because they hold memory of
// their own (rows of a table whose component is not flat, items of an array
// of such values), which is what makes it cost more than one read per
// container.
world_memory :: proc(info:^World_Info,data:rawptr) -> (bytes,elements:int) {
    if info==nil || data==nil {return}
    add :: proc(bytes,elements:^int,b,e:int) {bytes^+=b;elements^+=e}
    b,e:=value_bytes(entities_of(info,data),type_info_of(Entities))
    add(&bytes,&elements,b,e)
    for &t in info.tables {
        if t.place!=.World {continue}
        b,e=table_bytes(table_of(data,&t),t.info,t.flat)
        add(&bytes,&elements,b,e)
    }
    for &s in info.storages {
        if s.place!=.World || s.by_world || s.flat {continue}
        b,e=value_bytes(storage_of(data,&s),s.info)
        add(&bytes,&elements,b,e)
    }
    return
}

@(private="file")
table_bytes :: proc(t:^Raw_Table,info:^runtime.Type_Info,flat:bool) -> (bytes,elements:int) {
    size:=info.size
    bytes=(t.values.cap+t.added.cap+t.edited.cap)*size
    bytes+=cap(t.entities)*size_of(Entity)+cap(t.stamps)*size_of(u64)+cap(t.page_stamps)*size_of(u64)
    bytes+=cap(t.off)*size_of(bool)+cap(t.turns)*size_of(u64)+cap(t.pending)*size_of(Pending)
    bytes+=cap(t.edits)*size_of(Edit)+cap(t.gone.items)*size_of(Entity)+cap(t.owners)*size_of(Row_Owner)
    bytes+=len(t.locks)*size_of(Lock)+cap(t.rows)*size_of([]i32)
    for page in t.rows {bytes+=len(page)*size_of(i32)}
    when CHECK_WRITES {bytes+=cap(t.settled.values)}
    if flat {return}
    for i in 0..<t.values.len {
        b,e:=value_bytes(rawptr(uintptr(t.values.data)+uintptr(i*size)),info)
        bytes+=b;elements+=e+1
    }
    return
}

// What a value holds behind its pointers, as value_free would free it, and
// maps by their capacity. Its type is walked once: an array asks whether its
// element holds anything once, not for each element.
@(private="file")
value_bytes :: proc(data:rawptr,info:^runtime.Type_Info) -> (bytes,elements:int) {
    base:=runtime.type_info_base(info)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {
            b,e:=value_bytes(rawptr(uintptr(data)+v.offsets[i]),v.types[i])
            bytes+=b;elements+=e
        }
    case runtime.Type_Info_Array:
        if value_flat(v.elem) {return}
        for i in 0..<v.count {
            b,e:=value_bytes(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e
        }
    case runtime.Type_Info_Enumerated_Array:
        if value_flat(v.elem) {return}
        for i in 0..<v.count {
            b,e:=value_bytes(rawptr(uintptr(data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e
        }
    case runtime.Type_Info_Dynamic_Array:
        a:=cast(^runtime.Raw_Dynamic_Array)data
        bytes=a.cap*v.elem_size
        if a.len==0 || value_flat(v.elem) {return}
        for i in 0..<a.len {
            b,e:=value_bytes(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e+1
        }
    case runtime.Type_Info_Slice:
        a:=cast(^runtime.Raw_Slice)data
        bytes=a.len*v.elem_size
        if a.len==0 || value_flat(v.elem) {return}
        for i in 0..<a.len {
            b,e:=value_bytes(rawptr(uintptr(a.data)+uintptr(i*v.elem_size)),v.elem)
            bytes+=b;elements+=e+1
        }
    case runtime.Type_Info_Map:
        m:=cast(^runtime.Raw_Map)data
        if m.data!=0 && v.map_info!=nil {bytes=int(runtime.map_total_allocation_size(uintptr(runtime.map_cap(m^)),v.map_info))}
    }
    return
}
