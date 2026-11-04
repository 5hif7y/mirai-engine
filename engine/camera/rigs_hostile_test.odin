package camera

import "core:testing"
import math "mirai:std/math"

// Every public procedure takes whatever it is given and returns: sizes,
// capacities and numbers that are zero, negative, NaN or infinite.

@(private="file") HOSTILE_ROUNDS :: #config(CAMERA_HOSTILE_ROUNDS,400)

@(private="file")
Hostile :: struct {state:u64}

@(private="file")
hostile_next :: proc(h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    z:=h.state
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file")
hostile_int :: proc(h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}

@(private="file")
hostile_f32 :: proc(h:^Hostile) -> f32 {
    switch hostile_int(h,12) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    }
    return f32(hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_vec3 :: proc(h:^Hostile) -> math.Vec3 {return {hostile_f32(h),hostile_f32(h),hostile_f32(h)}}

// A capacity or size: usually small, sometimes empty, negative or too large to allocate.
@(private="file")
hostile_size :: proc(h:^Hostile) -> int {
    switch hostile_int(h,12) {
    case 0: return 0
    case 1: return -1
    case 2: return 1
    case 3: return min(int)
    case 4: return 1<<50
    case 5: return 1<<52
    case 6: return 3
    case 7: return 2
    }
    return hostile_int(h,200)+1
}

@(test)
hostile_numbers_through_the_cameras :: proc(t:^testing.T) {
    h:=Hostile{3}
    query:Arm_Query=proc(user:rawptr,from,to:math.Vec3,radius:f32) -> (fraction:f32,hit:bool) {
        fractions:=[3]f32{f32(0h7fc00000),-5,5}
        return fractions[int(radius)&1+int(from.x)&1],true
    }
    for _ in 0..<HOSTILE_ROUNDS {
        follow:Follow
        follow_snap(&follow,hostile_vec3(&h))
        _=follow_update(&follow,hostile_vec3(&h),hostile_f32(&h),hostile_f32(&h))
        orbit:=orbit_make(hostile_vec3(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h))
        orbit.min_pitch,orbit.max_pitch=hostile_f32(&h),hostile_f32(&h)
        orbit.min_distance,orbit.max_distance=hostile_f32(&h),hostile_f32(&h)
        orbit_rotate(&orbit,hostile_f32(&h),hostile_f32(&h));orbit_zoom(&orbit,hostile_f32(&h))
        _=orbit_direction(orbit);_=orbit_position(orbit);_=orbit_rotation(orbit);_=orbit_transform(orbit)
        arm:=spring_arm_make(hostile_f32(&h),hostile_f32(&h))
        arm.margin,arm.min_length,arm.return_time=hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)
        arm.grace,arm.pull_time,arm.hold=hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)
        _=spring_arm_update(&arm,hostile_vec3(&h),hostile_vec3(&h),hostile_int(&h,2)==0?nil:query,nil,hostile_f32(&h))
        shake:=shake_make(u32(hostile_next(&h)))
        shake_add(&shake,hostile_f32(&h))
        shake.decay,shake.frequency=hostile_f32(&h),hostile_f32(&h)
        shake.max_offset,shake.max_angle=hostile_vec3(&h),hostile_vec3(&h)
        _,_=shake_update(&shake,hostile_f32(&h))
        _=shake_intensity(shake)
        _=look_at_smooth(math.quat_axis_angle(hostile_vec3(&h),hostile_f32(&h)),hostile_vec3(&h),hostile_vec3(&h),hostile_vec3(&h),hostile_f32(&h),hostile_f32(&h))
    }
}

@(test)
hostile_power_through_the_shake :: proc(t:^testing.T) {
    h:=Hostile{4}
    for _ in 0..<HOSTILE_ROUNDS {
        shake:=shake_make()
        shake.trauma=hostile_f32(&h)
        shake.power=hostile_f32(&h)
        _=shake_intensity(shake)
        _,_=shake_update(&shake,0.01)
    }
}
