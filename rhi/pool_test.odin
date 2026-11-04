package rhi

import "core:fmt"
import "core:testing"
import "mirai:std/base"

@(test)
pool_handle_is_slot_and_generation_and_zero_is_invalid :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,4,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    first:=pool_add(&pool,10)
    testing.expect(t,first!=0,"the first handle of a pool is not the zero handle")
    testing.expect_value(t,base.handle_index(first),u32(0))
    testing.expect_value(t,base.handle_generation(first),u32(1))
    testing.expect(t,pool_get(&pool,0)==nil)
    testing.expect_value(t,pool_get(&pool,first)^,10)
    testing.expect_value(t,pool_handle(&pool,0),first)
    testing.expect_value(t,pool.count,1)
}

@(test)
pool_stale_handle_returns_nil_after_its_slot_is_reused :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,1,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    old:=pool_add(&pool,1)
    value,removed:=pool_remove(&pool,old)
    testing.expect(t,removed && value==1)
    testing.expect(t,pool_get(&pool,old)==nil,"a destroyed handle is invalid")
    _,again:=pool_remove(&pool,old)
    testing.expect(t,!again,"a handle is removed once")
    new:=pool_add(&pool,2)
    testing.expect_value(t,base.handle_index(new),base.handle_index(old))
    testing.expect(t,new!=old)
    testing.expect(t,pool_get(&pool,old)==nil,"the old handle does not alias the new occupant of its slot")
    testing.expect_value(t,pool_get(&pool,new)^,2)
}

@(test)
pool_full_returns_the_zero_handle_until_a_slot_is_freed :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,3,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    handles:[3]base.Handle
    for &handle,i in handles {handle=pool_add(&pool,i);testing.expect(t,handle!=0)}
    testing.expect(t,!pool_has_room(&pool))
    testing.expect_value(t,pool_add(&pool,99),base.Handle(0))
    testing.expect_value(t,pool.count,3)
    pool_remove(&pool,handles[1])
    testing.expect(t,pool_has_room(&pool))
    reused:=pool_add(&pool,7)
    testing.expect_value(t,base.handle_index(reused),u32(1))
    testing.expect_value(t,pool_get(&pool,reused)^,7)
    for i in ([]int{0,2}) {testing.expect_value(t,pool_get(&pool,handles[i])^,i)}
}

@(test)
pool_reuses_freed_slots_in_the_order_they_were_freed :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,4,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    handles:[4]base.Handle
    for &handle,i in handles {handle=pool_add(&pool,i)}
    for i in ([]int{2,0,3}) {pool_remove(&pool,handles[i])}
    for expected in ([]u32{2,0,3}) {testing.expect_value(t,base.handle_index(pool_add(&pool,0)),expected)}
    // The ring of free slots wraps around its end.
    for round in 0..<10 {
        handle:=pool_handle(&pool,round%4)
        pool_remove(&pool,handle)
        testing.expect_value(t,base.handle_index(pool_add(&pool,round)),u32(round%4))
    }
    testing.expect_value(t,pool.count,4)
}

@(test)
pool_of_no_capacity_holds_nothing :: proc(t:^testing.T) {
    pool:Pool(int)
    testing.expect(t,pool_init(&pool,0,context.allocator))
    defer pool_destroy(&pool,context.allocator)
    testing.expect(t,!pool_has_room(&pool))
    testing.expect_value(t,pool_add(&pool,1),base.Handle(0))
}
