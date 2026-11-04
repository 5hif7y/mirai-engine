package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

Inertial_State :: struct {elapsed,duration:f32,active:bool}
Inertial_Bone :: struct {position,rotation,scale,position_velocity,rotation_velocity,scale_velocity:math.Vec3}
Inertial_Curve :: struct {offset,velocity:f32}
Inertial_Input :: struct {
    previous,current,target_previous,target:[]math.Transform,
    previous_curves,current_curves,target_previous_curves,target_curves:[]f32,
    dt,duration:f32,
}

@(private)
inertial_rotation_delta :: proc "contextless" (from,to:math.Quat) -> math.Vec3 {
    delta:=conj(from)*to
    if real(delta)<0 {delta=-delta}
    return quat_log(delta)
}

@(private)
inertial_buffers_overlap :: proc "contextless" (a:[]$A,b:[]$B) -> bool {
    if len(a)==0 || len(b)==0 {return false}
    first,second:=uintptr(raw_data(a)),uintptr(raw_data(b))
    return second-first<uintptr(len(a))*size_of(A) if second>=first else first-second<uintptr(len(b))*size_of(B)
}

@(private)
inertial_input_valid :: proc "contextless" (input:Inertial_Input,bones:[]Inertial_Bone,curves:[]Inertial_Curve) -> bool {
    count:=len(input.current)
    if len(input.previous)!=count || len(input.target)!=count || len(bones)!=count || len(input.target_previous)!=0 && len(input.target_previous)!=count {return false}
    count=len(input.current_curves)
    if len(input.previous_curves)!=count || len(input.target_curves)!=count || len(curves)!=count || len(input.target_previous_curves)!=0 && len(input.target_previous_curves)!=count {return false}
    if !anim_finite(input.dt) || input.dt<0 || !anim_finite(input.duration) || input.duration<0 {return false}
    if !anim_pose_valid(input.previous) || !anim_pose_valid(input.current) || !anim_pose_valid(input.target_previous) || !anim_pose_valid(input.target) {return false}
    for values in ([4][]f32{input.previous_curves,input.current_curves,input.target_previous_curves,input.target_curves}) {for value in values {if !anim_finite(value) {return false}}}
    return true
}

inertial_capture :: proc "contextless" (state:^Inertial_State,bones:[]Inertial_Bone,curves:[]Inertial_Curve,input:Inertial_Input) -> bool {
    if state==nil || !inertial_input_valid(input,bones,curves) {return false}
    for current,i in input.current {
        target:=input.target[i]
        value:=Inertial_Bone{position=current.position-target.position,rotation=inertial_rotation_delta(target.rotation,current.rotation),scale=current.scale-target.scale}
        if input.dt>1e-8 {
            previous:=input.previous[i]
            value.position_velocity=(current.position-previous.position)/input.dt
            value.scale_velocity=(current.scale-previous.scale)/input.dt
            previous_target:=target
            if len(input.target_previous)>0 {
                previous_target=input.target_previous[i]
                value.position_velocity-=(target.position-previous_target.position)/input.dt
                value.scale_velocity-=(target.scale-previous_target.scale)/input.dt
            }
            residual:=conj(target.rotation)*current.rotation;if real(residual)<0 {residual=-residual}
            prior:=conj(previous_target.rotation)*previous.rotation;if linalg.dot(residual,prior)<0 {prior=-prior}
            value.rotation_velocity=(value.rotation-quat_log(prior))/input.dt
        }
        if !anim_vec3_valid(value.position) || !anim_vec3_valid(value.scale) || !anim_vec3_valid(value.position_velocity) || !anim_vec3_valid(value.rotation_velocity) || !anim_vec3_valid(value.scale_velocity) {return false}
        bones[i]=value
    }
    for current,i in input.current_curves {
        value:=Inertial_Curve{offset=current-input.target_curves[i]}
        if input.dt>1e-8 {
            value.velocity=(current-input.previous_curves[i])/input.dt
            if len(input.target_previous_curves)>0 {value.velocity-=(input.target_curves[i]-input.target_previous_curves[i])/input.dt}
        }
        if !anim_finite(value.offset) || !anim_finite(value.velocity) {return false}
        curves[i]=value
    }
    state^={duration=input.duration,active=input.duration>0}
    return true
}

inertial_advance :: proc "contextless" (state:^Inertial_State,dt:f32) -> bool {
    if state==nil || !anim_finite(dt) || dt<0 || !anim_finite(state.elapsed) || state.elapsed<0 || !anim_finite(state.duration) || state.duration<0 {return false}
    state.elapsed=f32(min(f64(state.elapsed)+f64(dt),f64(state.duration)))
    state.active=state.elapsed<state.duration
    return true
}

@(private)
inertial_factors :: proc "contextless" (state:Inertial_State) -> (offset,velocity:f32,ok:bool) {
    if !anim_finite(state.elapsed) || !anim_finite(state.duration) || state.elapsed<0 || state.duration<0 {return 0,0,false}
    if !state.active || state.duration==0 || state.elapsed>=state.duration {return 0,0,true}
    t:=f64(state.elapsed)/f64(state.duration)
    t2,t3:=t*t,t*t*t
    t4,t5:=t3*t,t3*t*t
    return f32(1-10*t3+15*t4-6*t5),f32(f64(state.duration)*(t-6*t3+8*t4-3*t5)),true
}

inertial_pose_apply :: proc "contextless" (state:Inertial_State,bones:[]Inertial_Bone,target,out:[]math.Transform,mask:[]f32=nil) -> bool {
    if len(bones)!=len(target) || len(out)!=len(target) || len(mask)!=0 && len(mask)!=len(target) || !anim_pose_valid(target) {return false}
    if raw_data(target)!=raw_data(out) && inertial_buffers_overlap(target,out) {return false}
    a,b,ok:=inertial_factors(state);if !ok {return false}
    for value in bones {if !anim_vec3_valid(value.position) || !anim_vec3_valid(value.rotation) || !anim_vec3_valid(value.scale) || !anim_vec3_valid(value.position_velocity) || !anim_vec3_valid(value.rotation_velocity) || !anim_vec3_valid(value.scale_velocity) {return false}}
    for value in mask {if !anim_finite(value) || value<0 || value>1 {return false}}
    for value,i in target {
        delta:=bones[i]
        weight:=mask[i] if len(mask)>0 else f32(1)
        result:=math.Transform{position=value.position+(delta.position*a+delta.position_velocity*b)*weight,rotation=linalg.normalize0(value.rotation*quat_exp((delta.rotation*a+delta.rotation_velocity*b)*weight)),scale=value.scale+(delta.scale*a+delta.scale_velocity*b)*weight}
        if !anim_transform_valid(result) {return false}
        out[i]=result
    }
    return true
}

inertial_curves_apply :: proc "contextless" (state:Inertial_State,curves:[]Inertial_Curve,target,out:[]f32,filtered:[]bool=nil) -> bool {
    if len(curves)!=len(target) || len(out)!=len(target) || len(filtered)!=0 && len(filtered)!=len(target) {return false}
    if raw_data(target)!=raw_data(out) && inertial_buffers_overlap(target,out) {return false}
    a,b,ok:=inertial_factors(state);if !ok {return false}
    for value,i in curves {if !anim_finite(value.offset) || !anim_finite(value.velocity) || !anim_finite(target[i]) {return false}}
    for value,i in curves {
        result:=target[i]
        if len(filtered)==0 || !filtered[i] {result+=value.offset*a+value.velocity*b}
        if !anim_finite(result) {return false}
        out[i]=result
    }
    return true
}
