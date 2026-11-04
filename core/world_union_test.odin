package core

import "base:runtime"
import "core:mem"
import "core:testing"

@(private="file") Union_Link :: struct {target:Entity,weight:f32}
@(private="file") Union_Sky :: struct {light:f32}

@(private="file")
Union_World :: struct {
    entities:Entities,
    parents:Table(Parent),
    links:Table(Union_Link),
    skies:Table(Union_Sky),
}

@(private="file")
union_world_init :: proc(w:^Union_World) {
    entities_init(&w.entities)
    table_init(&w.parents,"Parent")
    table_init(&w.links,"Union_Link")
    table_init(&w.skies,"Union_Sky")
    w.parents.base=true
    w.skies.single=true
}

@(private="file")
union_world_destroy :: proc(w:^Union_World) {
    table_destroy(&w.parents);table_destroy(&w.links);table_destroy(&w.skies);entities_destroy(&w.entities)
}

@(private="file")
union_world_settle :: proc(w:^Union_World) {
    table_settle(&w.parents,&w.entities);table_settle(&w.links,&w.entities);table_settle(&w.skies,&w.entities);entities_settle(&w.entities)
}

@(private="file")
union_info :: proc(tables:^[3]Table_Info) -> (info:World_Info) {
    tables^={
        {name="Parent",type=Parent,info=type_info_of(Parent),offset=offset_of(Union_World,parents)},
        {name="Union_Link",type=Union_Link,info=type_info_of(Union_Link),offset=offset_of(Union_World,links)},
        {name="Union_Sky",type=Union_Sky,info=type_info_of(Union_Sky),offset=offset_of(Union_World,skies),single=true},
    }
    info.entities=offset_of(Union_World,entities)
    info.tables=tables[:]
    world_info_index(&info)
    return
}

@(private="file")
union_info_destroy :: proc(info:^World_Info) {
    world_schema_destroy(info.schema);delete(info.tables_by_type);delete(info.storages_by_type)
}

// A World made apart joins the live one: its entities are new ones, their
// Entity fields name the new ones, what was off stays off and its roots go
// under the parent asked for.
@(test)
a_world_joins_another_with_its_entities_named_anew :: proc(t:^testing.T) {
    tables:[3]Table_Info
    info:=union_info(&tables)
    defer union_info_destroy(&info)

    live,apart:Union_World
    union_world_init(&live);defer union_world_destroy(&live)
    union_world_init(&apart);defer union_world_destroy(&apart)
    anchor:=create(&live.entities)
    union_world_settle(&live)
    // apart: a root that names its child, and the child, off by itself.
    root,child:=create(&apart.entities),create(&apart.entities)
    add(&apart.links,root,Union_Link{child,2})
    add(&apart.parents,child,Parent{root,0})
    add(&apart.links,child,Union_Link{root,3})
    union_world_settle(&apart)
    disable(&apart.links,child)
    union_world_settle(&apart)

    made:[dynamic]Entity
    defer delete(made)
    testing.expect(t,world_union(world_ref(&live,&info),world_ref(&apart,&info),anchor,&made))
    union_world_settle(&live)
    new_root,new_child:=made[entity_index(root)],made[entity_index(child)]
    testing.expect(t,alive(&live.entities,new_root) && alive(&live.entities,new_child))
    link,_:=get(read(&live.links),new_root)
    testing.expect_value(t,link.target,new_child)
    testing.expect(t,!has(read(&live.links),new_child),"what was off stays off")
    off_row:=raw_row(raw(&live.links),new_child)
    testing.expect(t,off_row>=0 && live.links.values[off_row].target==new_root)
    up,_:=get(read(&live.parents),new_child)
    testing.expect_value(t,up.entity,new_root)
    top,_:=get(read(&live.parents),new_root)
    testing.expect_value(t,top.entity,anchor)
    testing.expect_value(t,live.entities.alive,3)
    testing.expect_value(t,count(&live.parents),2)
}

// Only the roots asked for join, with what hangs from them, as roots; what
// they name outside them names none.
@(test)
only_what_hangs_from_the_roots_asked_for_joins :: proc(t:^testing.T) {
    tables:[3]Table_Info
    info:=union_info(&tables)
    defer union_info_destroy(&info)
    live,next:Union_World
    union_world_init(&live);defer union_world_destroy(&live)
    union_world_init(&next);defer union_world_destroy(&next)
    level,seat,body:=create(&live.entities),create(&live.entities),create(&live.entities)
    add(&live.parents,seat,Parent{level,0})
    add(&live.parents,body,Parent{seat,0})
    add(&live.links,body,Union_Link{level,1})
    union_world_settle(&live)
    made:[dynamic]Entity
    defer delete(made)
    kept:=[1]Entity{seat}
    testing.expect(t,world_union(world_ref(&next,&info),world_ref(&live,&info),NONE,&made,kept[:]))
    union_world_settle(&next)
    testing.expect_value(t,next.entities.alive,2)
    new_seat,new_body:=made[entity_index(seat)],made[entity_index(body)]
    testing.expect(t,!has(read(&next.parents),new_seat),"it is a root")
    up,_:=get(read(&next.parents),new_body)
    testing.expect_value(t,up.entity,new_seat)
    link,_:=get(read(&next.links),new_body)
    testing.expect_value(t,link.target,NONE)
}

// A World of one entity joins under an anchor as one entity with one Parent,
// after the children the anchor has; with room for it, the join and the
// settle that follows allocate nothing.
@(test)
a_join_makes_an_entity_for_each_one_and_allocates_nothing_with_room :: proc(t:^testing.T) {
    tables:[3]Table_Info
    info:=union_info(&tables)
    defer union_info_destroy(&info)
    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
    live,apart:Union_World
    {
        context.allocator=mem.tracking_allocator(&tracker)
        union_world_init(&live)
    }
    defer union_world_destroy(&live)
    union_world_init(&apart);defer union_world_destroy(&apart)
    anchor,first,second:=create(&live.entities),create(&live.entities),create(&live.entities)
    add(&live.parents,first,Parent{anchor,0})
    add(&live.parents,second,Parent{anchor,4})
    union_world_settle(&live)
    lone:=create(&apart.entities)
    add(&apart.links,lone,Union_Link{lone,1})
    union_world_settle(&apart)

    made:[dynamic]Entity
    defer delete(made)
    reserve(&made,len(apart.entities.generation))
    testing.expect(t,world_union(world_ref(&live,&info),world_ref(&apart,&info),anchor,&made))
    union_world_settle(&live)
    testing.expect_value(t,live.entities.alive,4)
    testing.expect_value(t,count(&live.parents),3)
    joined:=made[entity_index(lone)]
    up,_:=get(read(&live.parents),joined)
    testing.expect_value(t,up,Parent{anchor,5})
    link,_:=get(read(&live.links),joined)
    testing.expect_value(t,link.target,joined)

    // Gone again, the room it took stays for the next join.
    destroy(&live.entities,joined)
    union_world_settle(&live)
    before:=tracker.total_allocation_count
    testing.expect(t,world_union(world_ref(&live,&info),world_ref(&apart,&info),anchor,&made))
    union_world_settle(&live)
    testing.expect_value(t,tracker.total_allocation_count,before)
    testing.expect_value(t,live.entities.alive,4)
}

// Without memory for what joins nothing joins: dst stays as it was.
@(test)
a_join_without_memory_leaves_the_world_as_it_was :: proc(t:^testing.T) {
    tables:[3]Table_Info
    info:=union_info(&tables)
    defer union_info_destroy(&info)
    live,apart:Union_World
    union_world_init(&live);defer union_world_destroy(&live)
    union_world_init(&apart);defer union_world_destroy(&apart)
    anchor:=create(&live.entities)
    union_world_settle(&live)
    a,b:=create(&apart.entities),create(&apart.entities)
    add(&apart.parents,b,Parent{a,0})
    add(&apart.links,b,Union_Link{a,1})
    union_world_settle(&apart)

    failing :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        return nil,mode==.Free || mode==.Free_All?.None:.Out_Of_Memory
    }
    kept:=live.links.pending.allocator
    live.links.pending.allocator={procedure=failing}
    made:[dynamic]Entity
    defer delete(made)
    testing.expect(t,!world_union(world_ref(&live,&info),world_ref(&apart,&info),anchor,&made))
    live.links.pending.allocator=kept
    testing.expect_value(t,len(made),0)
    testing.expect_value(t,live.entities.alive,1)
    testing.expect(t,len(live.parents.pending)==0 && len(live.links.pending)==0)
    union_world_settle(&live)
    testing.expect_value(t,count(&live.parents),0)
}

// What a single table of what joins has comes off, whatever dst has on: it
// does not take the place of the one on, does not come back when that one
// goes, and in a root without one (a cave) leaves none on. Turned on, it is.
@(test)
a_world_that_joins_with_its_own_single_brings_it_off :: proc(t:^testing.T) {
    tables:[3]Table_Info
    info:=union_info(&tables)
    defer union_info_destroy(&info)
    live,cave,apart:Union_World
    union_world_init(&live);defer union_world_destroy(&live)
    union_world_init(&cave);defer union_world_destroy(&cave)
    union_world_init(&apart);defer union_world_destroy(&apart)
    sky:=create(&live.entities)
    add(&live.skies,sky,Union_Sky{1})
    union_world_settle(&live)
    union_world_settle(&cave)
    other:=create(&apart.entities)
    add(&apart.skies,other,Union_Sky{2})
    union_world_settle(&apart)
    testing.expect(t,has(&apart.skies,other),"alone, a scene uses its own")

    made:[dynamic]Entity
    defer delete(made)
    testing.expect(t,world_union(world_ref(&live,&info),world_ref(&apart,&info),NONE,&made))
    union_world_settle(&live)
    joined:=made[entity_index(other)]
    testing.expect(t,count(&live.skies)==1 && has(&live.skies,sky))
    _,off,found:=raw_state(raw(&live.skies),joined)
    testing.expect(t,found && off)
    disable(&live.skies,sky)
    union_world_settle(&live)
    testing.expect_value(t,count(&live.skies),0)

    testing.expect(t,world_union(world_ref(&cave,&info),world_ref(&apart,&info),NONE,&made))
    union_world_settle(&cave)
    testing.expect_value(t,count(&cave.skies),0)
    enable(&cave.skies,made[entity_index(other)])
    union_world_settle(&cave)
    testing.expect(t,count(&cave.skies)==1 && has(&cave.skies,made[entity_index(other)]))
}
