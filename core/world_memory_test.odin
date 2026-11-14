package core

import "core:testing"

// What a World's tables and storages hold grows with their rows and items,
// by the capacity they reserved, without stepping into flat values.
@(test)
the_memory_of_a_world_follows_what_its_tables_and_storages_hold :: proc(t:^testing.T) {
    info,described:=test_info(t,Rev_World)
    if !described {return}
    defer test_info_destroy(&info)
    w:Rev_World
    if !testing.expect(t,world_init(&info,.World,&w,context.allocator)) {return}
    defer world_destroy(&info,.World,&w)
    empty,_:=world_memory(&info,&w)
    for _ in 0..<100 {
        e:=create(&w.entities)
        add(&w.disabled,e,Disabled{})
    }
    settle(&info,&w,nil)
    rows,elements:=world_memory(&info,&w)
    testing.expectf(t,rows>=empty+100*size_of(Entity),"100 rows and their entities add to it: %d -> %d",empty,rows)
    testing.expect_value(t,elements,0)
    for i in 0..<1000 {append(&w.list.items,i32(i))}
    items,_:=world_memory(&info,&w)
    testing.expect_value(t,items-rows,cap(w.list.items)*size_of(i32))
}
