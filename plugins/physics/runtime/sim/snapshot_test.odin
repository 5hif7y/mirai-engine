package mirai_physics

import "core:testing"

@(test)
worlds_with_zero_optional_capacities_hash_and_restore :: proc(t:^testing.T) {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=4,4,4,0
    desc.character_capacity=0
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=0,0,0,0
    a,b:World
    testing.expect(t,world_init(&a,desc) && world_init(&b,desc))
    defer world_destroy(&a)
    defer world_destroy(&b)
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    test_body(&a,Sphere{0.2},{0,2,0})
    world_step(&a,1.0/60)
    buffer:=make([]byte,world_snapshot_capacity(&a))
    defer delete(buffer)
    written,ok:=world_snapshot(&a,buffer)
    testing.expect(t,ok && world_restore(&b,buffer[:written]))
    testing.expect_value(t,world_hash(&a),world_hash(&b))
}

// A scene with stacks, loose bodies and a kinematic mover: enough contact churn to expose any ordering that
// depends on something other than the state.
@(private)
test_scene :: proc(w:^World) {
    test_ground(w)
    for row in 0..<5 {
        for column in 0..<5-row {
            test_body(w,Box{{0.5,0.5,0.5}},{f32(column)*1.05+f32(row)*0.525-2.5,0.5+f32(row),0})
        }
    }
    for i in 0..<6 {
        test_body(w,Box{{0.3,0.2,0.4}},{f32(i)*0.4-1,6+f32(i)*0.7,0.3})
        test_body(w,Box{{0.25,0.25,0.25}},{f32(i)*0.9-2,8+f32(i)*0.5,-0.4})
    }
    pusher:=test_body(w,Box{{0.5,0.5,2}},{-8,0.6,0},.Kinematic)
    body_set_velocity(w,pusher,{2,0,0},{0,0.5,0})
    shot:=test_body(w,Box{{0.4,0.4,0.4}},{9,3,0.2})
    body_set_velocity(w,shot,{-20,2,0},{3,1,0})
}

// What a game does between ticks: bodies appear, disappear and get pushed.
@(private)
test_scene_edit :: proc(w:^World,step:int) {
    if step%7==3 {
        test_body(w,Box{{0.2,0.2,0.2}},{f32(step%5)-2,7,f32(step%3)-1})
    }
    if step%11==5 {
        handle:=body_handle(w,i32(3+step%20))
        if body_valid(w,handle) && body_type(w,handle)==.Dynamic {body_destroy(w,handle)}
    }
    if step%13==1 {
        handle:=body_handle(w,i32(1+step%9))
        body_apply_impulse_at(w,handle,{0,300,50},body_center(w,handle)+{0.1,0,0.2})
    }
}

@(test)
two_worlds_stepped_alike_keep_identical_hashes :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_world(&a) && test_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    test_scene(&a)
    test_scene(&b)
    testing.expect_value(t,world_hash(&a),world_hash(&b))
    for step in 0..<240 {
        test_scene_edit(&a,step)
        test_scene_edit(&b,step)
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"the worlds diverged at step %v",step)
            return
        }
    }
    // The hash does see the state: one more step on one side changes it.
    world_step(&a,1.0/60)
    testing.expect(t,world_hash(&a)!=world_hash(&b))
}

@(test)
restore_and_resimulation_repeat_the_trajectory_exactly :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_scene(&w)
    for step in 0..<50 {
        test_scene_edit(&w,step)
        world_step(&w,1.0/60)
    }
    buffer:=make([]byte,world_snapshot_capacity(&w))
    defer delete(buffer)
    size:=world_snapshot_size(&w)
    testing.expect(t,size<=len(buffer))
    written,ok:=world_snapshot(&w,buffer)
    testing.expect(t,ok)
    testing.expect_value(t,written,size)
    start:=world_hash(&w)
    hashes:[90]u64
    for step in 0..<90 {
        test_scene_edit(&w,50+step)
        world_step(&w,1.0/60)
        hashes[step]=world_hash(&w)
    }
    testing.expect(t,hashes[89]!=start)
    for round in 0..<2 {
        testing.expect(t,world_restore(&w,buffer[:written]))
        testing.expect_value(t,world_hash(&w),start)
        testing.expect_value(t,world_tick(&w),50)
        for step in 0..<90 {
            test_scene_edit(&w,50+step)
            world_step(&w,1.0/60)
            if world_hash(&w)!=hashes[step] {
                testing.expectf(t,false,"round %v diverged %v steps after the restore",round,step)
                return
            }
        }
    }
}

@(test)
a_snapshot_restores_into_another_world_of_the_same_capacities :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_world(&a) && test_world(&b))
    defer world_destroy(&a)
    defer world_destroy(&b)
    test_scene(&a)
    test_steps(&a,40)
    buffer:=make([]byte,world_snapshot_size(&a))
    defer delete(buffer)
    _,ok:=world_snapshot(&a,buffer)
    testing.expect(t,ok)
    testing.expect(t,world_restore(&b,buffer))
    for _ in 0..<60 {
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        testing.expect_value(t,world_hash(&b),world_hash(&a))
    }
    testing.expect_value(t,world_stats(&b).bodies,world_stats(&a).bodies)
}

@(test)
restore_rejects_buffers_that_are_not_a_snapshot_of_this_world :: proc(t:^testing.T) {
    w,small:World
    testing.expect(t,test_world(&w) && test_world(&small,bodies=8))
    defer world_destroy(&w)
    defer world_destroy(&small)
    test_scene(&w)
    test_steps(&w,10)
    buffer:=make([]byte,world_snapshot_size(&w))
    defer delete(buffer)
    _,short:=world_snapshot(&w,buffer[:len(buffer)-1])
    testing.expect(t,!short)
    _,ok:=world_snapshot(&w,buffer)
    testing.expect(t,ok)
    before:=world_hash(&w)
    testing.expect(t,!world_restore(&w,buffer[:len(buffer)/2]))
    testing.expect(t,!world_restore(&w,buffer[:8]))
    testing.expect(t,!world_restore(&small,buffer))
    testing.expect_value(t,world_stats(&small).bodies,0)
    buffer[0]~=0xff
    testing.expect(t,!world_restore(&w,buffer))
    testing.expect_value(t,world_hash(&w),before)
}

@(private)
test_parallel_reversed :: proc(count,grain:int,data:rawptr,body:proc(data:rawptr,first,last,worker:int)) {
    chunk:=max(grain/2,1)
    chunks:=(count+chunk-1)/chunk
    for i:=chunks-1;i>=0;i-=1 {
        body(data,i*chunk,min((i+1)*chunk,count),i%3)
    }
}

@(test)
the_split_of_the_work_does_not_change_the_result :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_world(&a))
    desc:=a.desc
    desc.worker_count=3
    desc.parallel_for=test_parallel_reversed
    testing.expect(t,world_init(&b,desc))
    defer world_destroy(&a)
    defer world_destroy(&b)
    test_scene(&a)
    test_scene(&b)
    for step in 0..<180 {
        test_scene_edit(&a,step)
        test_scene_edit(&b,step)
        world_step(&a,1.0/60)
        world_step(&b,1.0/60)
        if world_hash(&a)!=world_hash(&b) {
            testing.expectf(t,false,"the split changed the result at step %v",step)
            return
        }
    }
}
