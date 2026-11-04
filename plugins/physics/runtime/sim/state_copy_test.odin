package mirai_physics

import "core:testing"

@(test)
a_state_copied_into_another_world_steps_as_its_restored_snapshot_does :: proc(t:^testing.T) {
    a,b,c:World
    testing.expect(t,test_world(&a) && test_world(&b) && test_world(&c))
    defer world_destroy(&a)
    defer world_destroy(&b)
    defer world_destroy(&c)
    test_scene(&a)
    for step in 0..<50 {
        test_scene_edit(&a,step)
        world_step(&a,1.0/60)
    }
    // b had more of everything than a has now: the slots a never used go back to never used.
    test_scene(&b)
    for step in 0..<70 {
        test_scene_edit(&b,step)
        world_step(&b,1.0/60)
    }
    buffer:=make([]byte,world_snapshot_size(&a))
    defer delete(buffer)
    written,ok:=world_snapshot(&a,buffer)
    testing.expect(t,ok && world_restore(&c,buffer[:written]))
    testing.expect(t,world_state_copy(&b,&a))
    testing.expect_value(t,world_hash(&b),world_hash(&a))
    for step in 0..<90 {
        test_scene_edit(&b,50+step)
        test_scene_edit(&c,50+step)
        world_step(&b,1.0/60)
        world_step(&c,1.0/60)
        if world_hash(&b)!=world_hash(&c) {
            testing.expectf(t,false,"the copy diverged from the restored snapshot %v steps after",step)
            return
        }
    }
}

@(test)
a_state_copy_into_a_world_of_other_capacities_or_without_its_geometry_changes_nothing :: proc(t:^testing.T) {
    w,small,bare:World
    testing.expect(t,test_world(&w) && test_world(&small,bodies=8) && test_world(&bare))
    defer world_destroy(&w)
    defer world_destroy(&small)
    defer world_destroy(&bare)
    test_scene(&w)
    vertices:=[4]Vec3{{0,0,0},{1,0,0},{0,1,0},{0,0,1}}
    counts:=[4]u8{3,3,3,3};faces:=[12]u8{0,2,1,0,1,3,0,3,2,1,2,3}
    hull,made:=hull_create(&w,{vertices[:],counts[:],faces[:]})
    testing.expect(t,made)
    test_body(&w,hull,{0,4,0})
    test_steps(&w,10)
    before,empty:=world_hash(&small),world_hash(&bare)
    testing.expect(t,!world_state_copy(&small,&w))
    testing.expect_value(t,world_hash(&small),before)
    testing.expect(t,!world_state_copy(&bare,&w))
    testing.expect_value(t,world_hash(&bare),empty)
}
