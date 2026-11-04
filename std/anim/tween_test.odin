package mirai_anim

import "core:testing"
import math "mirai:std/math"

near :: proc(a,b:f32,eps:f32=1e-4) -> bool {return abs(a-b)<=eps}
near_vec :: proc(a,b:$V/[$N]f32,eps:f32=1e-4) -> bool {
    for i in 0..<N {if abs(a[i]-b[i])>eps {return false}}
    return true
}

@(test)
tween_moves_a_float_and_holds_its_end :: proc(t:^testing.T) {
    tw:=tween_make(f32(0),f32(10),2)
    testing.expect(t,near(tween_advance(&tw,1),5))
    testing.expect(t,!tw.done)
    testing.expect(t,near(tween_advance(&tw,1),10))
    testing.expect(t,tw.done)
    testing.expect(t,near(tween_advance(&tw,5),10))
    tween_reset(&tw)
    testing.expect(t,!tw.done && near(tween_value(tw),0))
}

@(test)
tween_applies_the_easing_curve :: proc(t:^testing.T) {
    tw:=tween_make(f32(0),f32(1),1,.Quad_In)
    testing.expect(t,near(tween_advance(&tw,0.5),0.25))
    testing.expect(t,near(tween_progress(tw),0.25))
}

@(test)
tween_waits_for_its_delay :: proc(t:^testing.T) {
    tw:=tween_make(f32(4),f32(8),1,.Linear,2)
    testing.expect(t,near(tween_advance(&tw,1.5),4))
    testing.expect(t,near(tween_advance(&tw,1),6))
    testing.expect(t,!tw.done)
    testing.expect(t,near(tween_advance(&tw,1),8))
    testing.expect(t,tw.done)
}

@(test)
tween_moves_vectors_of_every_size :: proc(t:^testing.T) {
    v2:=tween_make(math.Vec2{0,2},math.Vec2{2,4},1)
    testing.expect(t,near_vec(tween_advance(&v2,0.5),math.Vec2{1,3}))
    v3:=tween_make(math.Vec3{0,0,0},math.Vec3{2,4,6},1)
    testing.expect(t,near_vec(tween_advance(&v3,0.25),math.Vec3{0.5,1,1.5}))
    v4:=tween_make(math.Vec4{1,1,1,1},math.Vec4{3,5,7,9},2)
    testing.expect(t,near_vec(tween_advance(&v4,1),math.Vec4{2,3,4,5}))
}

@(test)
tween_slerps_quaternions_to_the_half_angle :: proc(t:^testing.T) {
    target:=math.quat_axis_angle({0,1,0},math.PI/2)
    tw:=tween_make(math.QUAT_IDENTITY,target,1)
    half:=tween_advance(&tw,0.5)
    testing.expect(t,near(math.quat_angle(math.QUAT_IDENTITY,half),math.PI/4,1e-3))
    testing.expect(t,near(abs(half),1,1e-4))
    testing.expect(t,near(math.quat_angle(tween_advance(&tw,0.5),target),0,1e-3))
}

@(test)
tween_color_mixes_in_oklab_when_asked :: proc(t:^testing.T) {
    red,green:=math.Vec4{1,0,0,1},math.Vec4{0,1,0,1}
    linear:=tween_make(red,green,1)
    oklab:=tween_make_color(red,green,1)
    a,b:=tween_advance(&linear,0.5),tween_advance(&oklab,0.5)
    testing.expect(t,near_vec(a,math.Vec4{0.5,0.5,0,1}))
    testing.expect(t,!near_vec(a,b,1e-3))
    testing.expect(t,near_vec(tween_advance(&oklab,0.5),green,1e-3))
    reset:=tween_make_color(red,green,1)
    testing.expect(t,near_vec(tween_value(reset),red,1e-3))
}

@(test)
tween_loops_and_ping_pongs :: proc(t:^testing.T) {
    loop:=tween_make(f32(0),f32(10),1,.Linear,0,.Loop)
    testing.expect(t,near(tween_advance(&loop,1.5),5))
    testing.expect(t,!loop.done)
    testing.expect(t,near(tween_advance(&loop,0.25),7.5))
    ping:=tween_make(f32(0),f32(10),1,.Linear,0,.Ping_Pong)
    testing.expect(t,near(tween_advance(&ping,1.5),5))
    testing.expect(t,near(tween_advance(&ping,0.25),2.5))
    testing.expect(t,near(tween_advance(&ping,100.25),0))
}

@(test)
tween_with_no_duration_is_already_at_its_end :: proc(t:^testing.T) {
    tw:=tween_make(f32(3),f32(9),0)
    testing.expect(t,tw.done && near(tween_value(tw),9))
    testing.expect(t,near(tween_advance(&tw,1),9))
}

@(test)
tween_rewinds_with_negative_time :: proc(t:^testing.T) {
    tw:=tween_make(f32(0),f32(10),2)
    tween_advance(&tw,1.5)
    testing.expect(t,near(tween_advance(&tw,-1),2.5))
    testing.expect(t,near(tween_advance(&tw,-5),0))
    testing.expect(t,!tw.done)
}
