package ai

import "core:math/linalg"
import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

@(test)
limit_length_only_shortens :: proc(t:^testing.T) {
    testing.expect(t,near_vec(limit_length(math.Vec2{3,4},2.5),math.Vec2{1.5,2}))
    testing.expect(t,near_vec(limit_length(math.Vec3{1,0,0},2),math.Vec3{1,0,0}))
    testing.expect(t,limit_length(math.Vec2{},1)==math.Vec2{})
}

@(test)
seek_and_flee_push_along_the_line_to_the_target :: proc(t:^testing.T) {
    force:=seek(math.Vec2{0,0},math.Vec2{0,0},math.Vec2{10,0},5,2)
    testing.expect(t,near_vec(force,math.Vec2{2,0}))
    testing.expect(t,near_vec(seek(math.Vec2{0,0},math.Vec2{5,0},math.Vec2{10,0},5,2),math.Vec2{0,0}))
    sideways:=seek(math.Vec2{0,0},math.Vec2{0,5},math.Vec2{10,0},5,100)
    testing.expect(t,near_vec(sideways,math.Vec2{5,-5}))
    testing.expect(t,near_vec(flee(math.Vec2{0,0},math.Vec2{0,0},math.Vec2{10,0},5,2),math.Vec2{-2,0}))
    testing.expect(t,near_vec(seek(math.Vec3{1,1,1},math.Vec3{},math.Vec3{1,1,5},3,10),math.Vec3{0,0,3}))
    testing.expect(t,seek(math.Vec2{1,1},math.Vec2{},math.Vec2{1,1},3,10)==math.Vec2{}) // already there
}

@(test)
arrive_slows_down_inside_its_radius_and_stops_at_the_target :: proc(t:^testing.T) {
    far:=arrive(math.Vec2{0,0},math.Vec2{},math.Vec2{10,0},4,100,5)
    testing.expect(t,near_vec(far,math.Vec2{4,0}))
    near_target:=arrive(math.Vec2{0,0},math.Vec2{},math.Vec2{2.5,0},4,100,5)
    testing.expect(t,near_vec(near_target,math.Vec2{2,0}))
    on_target:=arrive(math.Vec2{1,1},math.Vec2{2,0},math.Vec2{1,1},4,1,5)
    testing.expect(t,near_vec(on_target,math.Vec2{-1,0}))
    sharp:=arrive(math.Vec2{0,0},math.Vec2{},math.Vec2{1,0},4,100,0)
    testing.expect(t,near_vec(sharp,math.Vec2{4,0}))
}

@(test)
arrive_brings_an_agent_to_rest_at_the_target :: proc(t:^testing.T) {
    position,velocity:=math.Vec2{0,0},math.Vec2{0,0}
    target:=math.Vec2{20,10}
    for _ in 0..<1500 {
        force:=arrive(position,velocity,target,6,30,8)
        position,velocity=steering_integrate(position,velocity,force,6,1.0/60)
    }
    testing.expectf(t,linalg.length(position-target)<0.05 && linalg.length(velocity)<0.05,"%v %v",position-target,velocity)
    _,speed:=steering_integrate(math.Vec3{},math.Vec3{},math.Vec3{100,0,0},3,1)
    testing.expect(t,near_vec(speed,math.Vec3{3,0,0}))
}

@(test)
pursue_aims_ahead_of_a_moving_target_and_evade_away_from_it :: proc(t:^testing.T) {
    direct:=seek(math.Vec2{0,0},math.Vec2{},math.Vec2{10,0},5,100)
    ahead:=pursue(math.Vec2{0,0},math.Vec2{},math.Vec2{10,0},math.Vec2{0,5},5,100,10)
    testing.expect(t,ahead.y>0.5 && ahead.x>0 && near(linalg.length(ahead),5))
    testing.expect(t,direct.y==0)
    capped:=pursue(math.Vec2{0,0},math.Vec2{},math.Vec2{1000,0},math.Vec2{0,100},5,100,0.1)
    testing.expect(t,capped.y>0 && capped.y/capped.x<0.1)
    away:=evade(math.Vec2{0,0},math.Vec2{},math.Vec2{10,0},math.Vec2{0,5},5,100,10)
    testing.expect(t,away.x<0 && away.y<0)
    testing.expect(t,pursue(math.Vec2{0,0},math.Vec2{},math.Vec2{4,0},math.Vec2{1,0},0,100,10)==math.Vec2{})
}

@(test)
wander_keeps_its_point_on_the_circle_and_is_repeatable :: proc(t:^testing.T) {
    run :: proc(seed:u64) -> (heading_sum:math.Vec2,radius:f32) {
        rng:=base.rng_make(seed)
        state:math.Vec2
        for _ in 0..<50 {
            force:=wander(&state,math.Vec2{1,0},2,1,0.4,3,&rng)
            heading_sum+=force
            radius=linalg.length(state)
            assert(linalg.length(force)<=3+1e-4)
        }
        return
    }
    a,radius:=run(3)
    b,_:=run(3)
    c,_:=run(4)
    testing.expect(t,a==b && a!=c && near(radius,1))
    testing.expect(t,a.x>0)
    rng:=base.rng_make(9)
    state:math.Vec3
    force:=wander(&state,math.Vec3{0,0,-1},2,1,0.5,3,&rng)
    testing.expect(t,near(linalg.length(state),1) && force.z<0 && linalg.length(force)<=3+1e-4)
}

@(test)
separation_pushes_away_from_close_neighbors_only :: proc(t:^testing.T) {
    neighbors:=[]Boid(math.Vec2){{position={1,0}},{position={0,5}},{position={0,0}}}
    force:=separation(math.Vec2{0,0},neighbors,2,100)
    testing.expect(t,near_vec(force,math.Vec2{-1,0}))
    closer:=separation(math.Vec2{0,0},[]Boid(math.Vec2){{position={0.5,0}}},2,100)
    testing.expect(t,near_vec(closer,math.Vec2{-2,0}))
    testing.expect(t,near(linalg.length(separation(math.Vec2{0,0},[]Boid(math.Vec2){{position={0.1,0}}},2,3)),3))
    testing.expect(t,separation(math.Vec2{0,0},[]Boid(math.Vec2){},2,3)==math.Vec2{})
}

@(test)
alignment_and_cohesion_follow_the_neighbors_within_their_radius :: proc(t:^testing.T) {
    neighbors:=[]Boid(math.Vec2){{position={1,0},velocity={0,2}},{position={0,1},velocity={0,4}},{position={50,50},velocity={9,9}}}
    align:=alignment(math.Vec2{0,0},math.Vec2{3,0},neighbors,5,3,100)
    testing.expect(t,near_vec(align,math.Vec2{-3,3}))
    cohere:=cohesion(math.Vec2{0,0},math.Vec2{},neighbors,5,2,100)
    testing.expect(t,near_vec(cohere,math.Vec2{1.41421356,1.41421356}))
    testing.expect(t,alignment(math.Vec2{100,0},math.Vec2{},neighbors[:2],5,3,100)==math.Vec2{})
    testing.expect(t,cohesion(math.Vec2{100,0},math.Vec2{},neighbors[:2],5,3,100)==math.Vec2{})
}

@(test)
avoid_obstacles_steers_around_the_nearest_obstacle_on_the_path :: proc(t:^testing.T) {
    obstacles:=[]Obstacle(math.Vec2){{center={5,0.5},radius=1},{center={9,0},radius=1},{center={-5,0},radius=1}}
    force:=avoid_obstacles(math.Vec2{0,0},math.Vec2{2,0},obstacles,10,0.5,4)
    testing.expect(t,near_vec(force,math.Vec2{0,-4}))
    testing.expect(t,avoid_obstacles(math.Vec2{0,0},math.Vec2{},obstacles,10,0.5,4)==math.Vec2{})
    testing.expect(t,avoid_obstacles(math.Vec2{0,0},math.Vec2{-2,0},obstacles[:2],10,0.5,4)==math.Vec2{})
    testing.expect(t,avoid_obstacles(math.Vec2{0,0},math.Vec2{2,0},obstacles[:2],3,0.5,4)==math.Vec2{}) // too far to matter
    dead_on:=avoid_obstacles(math.Vec2{0,0},math.Vec2{2,0},[]Obstacle(math.Vec2){{center={5,0},radius=1}},10,0.5,4)
    testing.expect(t,near(linalg.length(dead_on),4) && near(dead_on.x,0))
    in_3d:=avoid_obstacles(math.Vec3{0,0,0},math.Vec3{0,0,-1},[]Obstacle(math.Vec3){{center={0,0,-5},radius=1}},10,0.5,2)
    testing.expect(t,near(linalg.length(in_3d),2) && near(in_3d.z,0))
    miss:=avoid_obstacles(math.Vec3{0,0,0},math.Vec3{0,0,-1},[]Obstacle(math.Vec3){{center={4,0,-5},radius=1}},10,0.5,2)
    testing.expect(t,miss==math.Vec3{})
}
