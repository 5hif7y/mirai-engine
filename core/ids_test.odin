package core

import "core:testing"
import "mirai:std/base"

@(private="file")
Id_World :: struct {
    es:Entities,
    ids:Table(Id),
    names:Table(Name),
}

@(private="file")
id_world_init :: proc(w:^Id_World,allocator:=context.allocator) {
    entities_init(&w.es,allocator)
    table_init(&w.ids,"Id");table_init(&w.names,"Name")
    w.ids.base,w.names.base=true,true
}

@(private="file")
id_world_destroy :: proc(w:^Id_World) {
    table_destroy(&w.ids);table_destroy(&w.names)
    entities_destroy(&w.es)
}

// What the generated settle does.
@(private="file")
id_world_settle :: proc(w:^Id_World) {
    table_settle(&w.ids,&w.es)
    table_settle(&w.names,&w.es)
    entities_settle(&w.es)
}

// What the generated copy and swap do.
@(private="file")
id_world_copy :: proc(dst,src:^Id_World) -> bool {
    synced:=ids_synced(&src.es,read(&src.ids))
    if !entities_copy(&dst.es,&src.es) || !table_copy(&dst.ids,&src.ids) || !table_copy(&dst.names,&src.names) {return false}
    ids_moved(&dst.es,read(&dst.ids),synced)
    return true
}

@(private="file")
id_world_swap :: proc(a,b:^Id_World) {
    a_synced,b_synced:=ids_synced(&a.es,read(&a.ids)),ids_synced(&b.es,read(&b.ids))
    a.es,b.es=b.es,a.es
    table_swap(&a.ids,&b.ids);table_swap(&a.names,&b.names)
    ids_moved(&a.es,read(&a.ids),b_synced)
    ids_moved(&b.es,read(&b.ids),a_synced)
}

@(private="file")
id_world_add :: proc(w:^Id_World,id:base.Entity_Id) -> Entity {
    e:=create(&w.es)
    add(&w.ids,e,Id{id})
    return e
}

@(test)
an_entity_is_found_by_its_id_from_the_settle_that_adds_it :: proc(t:^testing.T) {
    w:Id_World
    id_world_init(&w);defer id_world_destroy(&w)
    a,b:=id_world_add(&w,7),id_world_add(&w,9)
    plain:=create(&w.es)
    add(&w.names,plain,name_make("No id"))
    testing.expect_value(t,entity_of(&w.es,7),NONE)
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,7),a)
    testing.expect_value(t,entity_of(&w.es,9),b)
    testing.expect_value(t,entity_of(&w.es,0),NONE)
    testing.expect_value(t,entity_of(&w.es,8),NONE)
    testing.expect_value(t,id_of(read(&w.ids),a),base.Entity_Id(7))
    testing.expect_value(t,id_of(read(&w.ids),plain),base.Entity_Id(0))
    testing.expect_value(t,id_of(Read(Id){},a),base.Entity_Id(0))
    version:=w.ids.version
    _=id_of(read(&w.ids),b)
    testing.expect_value(t,w.ids.version,version)
    testing.expect(t,ids_synced(&w.es,read(&w.ids)))
    // A settle with nothing new leaves it as it was.
    seen:=w.es.ids.seen
    id_world_settle(&w)
    testing.expect_value(t,w.es.ids.seen,seen)
}

@(test)
the_index_follows_writes_removals_destruction_and_undo :: proc(t:^testing.T) {
    w:Id_World
    id_world_init(&w);defer id_world_destroy(&w)
    a,b,c:=id_world_add(&w,7),id_world_add(&w,9),id_world_add(&w,13)
    id_world_settle(&w)

    get(&w.ids,a).value=11
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,7),NONE)
    testing.expect_value(t,entity_of(&w.es,11),a)

    add(&w.ids,b,Id{15})
    remove(&w.ids,c)
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,9),NONE)
    testing.expect_value(t,entity_of(&w.es,15),b)
    testing.expect_value(t,entity_of(&w.es,13),NONE)

    destroy(&w.es,a)
    testing.expect_value(t,entity_of(&w.es,11),NONE)
    id_world_settle(&w)
    testing.expect_value(t,w.es.ids.count,1)

    // The index of a destroyed entity comes back for another one.
    d:=id_world_add(&w,11)
    testing.expect_value(t,entity_index(d),entity_index(a))
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,11),d)

    // An undo takes a row between functions.
    testing.expect(t,raw_drop(raw(&w.ids),type_info_of(Id),d))
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,11),NONE)
    testing.expect_value(t,entity_of(&w.es,15),b)
}

@(test)
an_id_two_entities_share_goes_to_the_other_when_its_holder_leaves :: proc(t:^testing.T) {
    w:Id_World
    id_world_init(&w);defer id_world_destroy(&w)
    first,second:=id_world_add(&w,5),id_world_add(&w,5)
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,5),first)
    testing.expect_value(t,w.es.ids.shared,1)
    destroy(&w.es,first)
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,5),second)
    testing.expect_value(t,w.es.ids.shared,0)
    // The one that does not hold it leaves without taking the Id along.
    third:=id_world_add(&w,5)
    id_world_settle(&w)
    remove(&w.ids,third)
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,5),second)
    remove(&w.ids,second)
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,5),NONE)
    testing.expect_value(t,w.es.ids.count,0)
}

@(test)
many_ids_stay_found_while_the_index_grows_and_loses_them_in_any_order :: proc(t:^testing.T) {
    w:Id_World
    id_world_init(&w);defer id_world_destroy(&w)
    COUNT :: 2000
    entities:=make([]Entity,COUNT,context.temp_allocator)
    ids:=make([]base.Entity_Id,COUNT,context.temp_allocator)
    state:=u64(42)
    for i in 0..<COUNT {
        // Half random, half consecutive: these crowd the same slots.
        ids[i]=i%2==0?base.entity_id_next(&state):base.Entity_Id(i+1)
        entities[i]=id_world_add(&w,ids[i])
        if i%300==299 {id_world_settle(&w)}
    }
    id_world_settle(&w)
    for i in 0..<COUNT {testing.expect_value(t,entity_of(&w.es,ids[i]),entities[i])}
    rng:=base.rng_make(7)
    gone:=make([]bool,COUNT,context.temp_allocator)
    for _ in 0..<COUNT/2 {
        i:=int(base.rng_u32(&rng)%COUNT)
        if gone[i] {continue}
        gone[i]=true
        destroy(&w.es,entities[i])
    }
    id_world_settle(&w)
    left:=0
    for i in 0..<COUNT {
        testing.expect_value(t,entity_of(&w.es,ids[i]),gone[i]?NONE:entities[i])
        if !gone[i] {left+=1}
    }
    testing.expect_value(t,w.es.ids.count,left)
}

@(test)
the_index_travels_with_copied_and_swapped_worlds :: proc(t:^testing.T) {
    a,b:Id_World
    id_world_init(&a);defer id_world_destroy(&a)
    id_world_init(&b);defer id_world_destroy(&b)
    first:=id_world_add(&a,21)
    id_world_settle(&a)
    other:=id_world_add(&b,31)
    id_world_settle(&b)

    play:Id_World
    id_world_init(&play);defer id_world_destroy(&play)
    testing.expect(t,id_world_copy(&play,&a))
    testing.expect(t,ids_synced(&play.es,read(&play.ids)))
    testing.expect_value(t,entity_of(&play.es,21),first)
    late:=id_world_add(&play,22)
    id_world_settle(&play)
    testing.expect_value(t,entity_of(&play.es,22),late)
    testing.expect_value(t,entity_of(&a.es,22),NONE)

    id_world_swap(&a,&b)
    testing.expect(t,ids_synced(&a.es,read(&a.ids)) && ids_synced(&b.es,read(&b.ids)))
    testing.expect_value(t,entity_of(&a.es,31),other)
    testing.expect_value(t,entity_of(&b.es,21),first)
    testing.expect_value(t,entity_of(&a.es,21),NONE)
    remove(&a.ids,other)
    id_world_settle(&a)
    testing.expect_value(t,entity_of(&a.es,31),NONE)

    // A copy that does not move the index reads the table whole at the next settle.
    plain:Id_World
    id_world_init(&plain);defer id_world_destroy(&plain)
    testing.expect(t,entities_copy(&plain.es,&b.es) && table_copy(&plain.ids,&b.ids) && table_copy(&plain.names,&b.names))
    testing.expect(t,!ids_synced(&plain.es,read(&plain.ids)))
    id_world_settle(&plain)
    testing.expect(t,ids_synced(&plain.es,read(&plain.ids)))
    testing.expect_value(t,entity_of(&plain.es,21),first)
}

@(test)
a_cleared_world_has_no_ids :: proc(t:^testing.T) {
    w:Id_World
    id_world_init(&w);defer id_world_destroy(&w)
    old:=id_world_add(&w,3)
    id_world_settle(&w)
    entities_clear(&w.es);table_clear(&w.ids);table_clear(&w.names)
    testing.expect_value(t,entity_of(&w.es,3),NONE)
    again:=id_world_add(&w,3)
    id_world_settle(&w)
    testing.expect(t,again!=old)
    testing.expect_value(t,entity_of(&w.es,3),again)
    testing.expect_value(t,w.es.ids.count,1)
}

@(test)
a_new_id_skips_those_a_live_entity_has_and_repeats_for_a_state :: proc(t:^testing.T) {
    w:Id_World
    id_world_init(&w);defer id_world_destroy(&w)
    state:=u64(99)
    copy_of:=state
    first:=id_new(&w.es,&copy_of)
    testing.expect_value(t,base.entity_id_next(&state),first)
    taken:=id_world_add(&w,first)
    id_world_settle(&w)
    again:=u64(99)
    second:=id_new(&w.es,&again)
    testing.expect(t,second!=first && second!=0)
    testing.expect_value(t,again,state+0x9e3779b97f4a7c15)
    // A holder that is no longer alive does not keep it.
    destroy(&w.es,taken)
    fresh:=u64(99)
    testing.expect_value(t,id_new(&w.es,&fresh),first)
}

@(test)
an_index_without_memory_reads_its_table_whole_once_there_is :: proc(t:^testing.T) {
    allocation:=Copy_Allocation{owner=context.allocator,remaining=1<<30}
    w:Id_World
    id_world_init(&w,{copy_allocator,&allocation});defer id_world_destroy(&w)
    e:=id_world_add(&w,17)
    allocation.remaining=0
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,17),NONE)
    testing.expect(t,w.es.ids.whole && !ids_synced(&w.es,read(&w.ids)))
    allocation.remaining=1<<30
    id_world_settle(&w)
    testing.expect_value(t,entity_of(&w.es,17),e)
    testing.expect(t,ids_synced(&w.es,read(&w.ids)))
}
