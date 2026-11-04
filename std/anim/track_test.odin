package mirai_anim

import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

key :: proc(time:f32,x:f32,interpolation:Interpolation=.Linear,ease:math.Ease=.Linear) -> Keyframe {
    return {time=time,value={x,0,0,0},ease=ease,interpolation=interpolation}
}
rot_key :: proc(time:f32,q:math.Quat,interpolation:Interpolation=.Linear) -> Keyframe {
    return {time=time,value=quat_vec4(q),interpolation=interpolation}
}

@(test)
track_holds_its_ends_and_interpolates_linearly :: proc(t:^testing.T) {
    keys:=[]Keyframe{key(1,10),key(3,20),key(4,0)}
    testing.expect(t,near(track_evaluate(keys,.Float,0).x,10))
    testing.expect(t,near(track_evaluate(keys,.Float,1).x,10))
    testing.expect(t,near(track_evaluate(keys,.Float,2).x,15))
    testing.expect(t,near(track_evaluate(keys,.Float,3.5).x,10))
    testing.expect(t,near(track_evaluate(keys,.Float,9).x,0))
    testing.expect(t,track_evaluate(nil,.Float,1)==math.Vec4{})
    testing.expect(t,near(track_evaluate(keys[:1],.Float,5).x,10))
}

@(test)
track_step_holds_the_previous_value_until_the_key :: proc(t:^testing.T) {
    keys:=[]Keyframe{key(0,1),key(1,5,.Step),key(2,9,.Step)}
    testing.expect(t,near(track_evaluate(keys,.Float,0.99).x,1))
    testing.expect(t,near(track_evaluate(keys,.Float,1).x,5))
    testing.expect(t,near(track_evaluate(keys,.Float,1.99).x,5))
    testing.expect(t,near(track_evaluate(keys,.Float,2).x,9))
}

@(test)
track_easing_shapes_each_segment_by_the_arrival_key :: proc(t:^testing.T) {
    keys:=[]Keyframe{key(0,0),key(2,8,.Linear,.Quad_In)}
    testing.expect(t,near(track_evaluate(keys,.Float,1).x,2))
}

@(test)
track_cubic_passes_through_keys_and_uses_neighbor_slopes :: proc(t:^testing.T) {
    keys:=[]Keyframe{key(0,0),key(1,1,.Cubic),key(2,0,.Cubic)}
    for k in keys {testing.expect(t,near(track_evaluate(keys,.Float,k.time).x,k.value.x))}
    testing.expect(t,near(track_evaluate(keys,.Float,0.5).x,0.625))
    testing.expect(t,near(track_evaluate(keys,.Float,1.5).x,0.625))
    line:=[]Keyframe{key(0,0),key(1,1,.Cubic),key(2,2,.Cubic),key(3,3,.Cubic)}
    for time in ([]f32{0.25,1.5,2.75}) {testing.expect(t,near(track_evaluate(line,.Float,time).x,time))}
}

@(test)
track_vectors_interpolate_every_component :: proc(t:^testing.T) {
    keys:=[]Keyframe{{time=0,value={0,2,4,6}},{time=2,value={2,4,6,8}}}
    testing.expect(t,near_vec(track_evaluate(keys,.Vector,1),math.Vec4{1,3,5,7}))
}

@(test)
track_rotation_takes_the_short_arc_and_stays_unit :: proc(t:^testing.T) {
    a:=math.quat_axis_angle({0,1,0},0)
    b:=math.quat_axis_angle({0,1,0},math.PI/2)
    for sign in ([]f32{1,-1}) {
        flipped:=quaternion(w=sign*b.w,x=sign*b.x,y=sign*b.y,z=sign*b.z)
        keys:=[]Keyframe{rot_key(0,a),rot_key(1,flipped)}
        mid:=vec4_quat(track_evaluate(keys,.Rotation,0.5))
        testing.expect(t,near(math.quat_angle(a,mid),math.PI/4,1e-3))
        testing.expect(t,near(abs(mid),1,1e-4))
    }
    cubic:=[]Keyframe{rot_key(0,a,.Cubic),rot_key(1,b,.Cubic),rot_key(2,math.quat_axis_angle({0,1,0},math.PI),.Cubic)}
    for time in ([]f32{0.3,0.7,1.2,1.9}) {
        q:=vec4_quat(track_evaluate(cubic,.Rotation,time))
        testing.expect(t,near(abs(q),1,1e-4))
    }
    at_key:=vec4_quat(track_evaluate(cubic,.Rotation,1))
    testing.expect(t,near(math.quat_angle(at_key,b),0,1e-3))
}

@(test)
track_with_repeated_times_does_not_divide_by_zero :: proc(t:^testing.T) {
    keys:=[]Keyframe{key(0,0),key(1,1,.Cubic),key(1,5,.Cubic),key(2,6,.Cubic)}
    for time in ([]f32{0.5,1,1.5}) {
        v:=track_evaluate(keys,.Float,time).x
        testing.expect(t,v==v && abs(v)<100)
    }
}

make_library :: proc(t:^testing.T,keys:=64,tracks:=16,clips:=8,markers:=16) -> Library {
    lib:Library
    testing.expect(t,library_init(&lib,{max_keys=keys,max_tracks=tracks,max_clips=clips,max_markers=markers}))
    return lib
}

@(test)
library_stores_clips_with_their_duration_tracks_and_sorted_markers :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    move:=base.name_hash("move")
    clip,_:=clip_add(&lib,{name=base.name_hash("walk"),loop=.Loop,
        tracks={{target=move,property=.Position,keys={{time=0,value={0,0,0,0}},{time=2,value={4,0,0,0}}}},{target=move,property=.Float,slot=3,keys={key(0,1),key(1.5,2)}}},
        markers={{time=1.5,id=7},{time=0.5,id=3}}})
    testing.expect(t,clip==1)
    testing.expect(t,near(clip_duration(&lib,clip),2))
    testing.expect_value(t,clip_find(&lib,base.name_hash("walk")),clip)
    testing.expect_value(t,clip_find(&lib,base.name_hash("run")),Clip(0))
    tracks:=clip_tracks(&lib,clip)
    testing.expect_value(t,len(tracks),2)
    testing.expect_value(t,tracks[1].slot,u8(3))
    testing.expect_value(t,len(track_keys(&lib,tracks[0])),2)
    markers:=clip_markers(&lib,clip)
    testing.expect(t,len(markers)==2 && markers[0].id==3 && markers[1].id==7)
    testing.expect(t,near(clip_evaluate(&lib,tracks[0],1).x,2))
    testing.expect_value(t,clip_data(&lib,clip).loop,Loop.Loop)
}

@(test)
library_refuses_unsorted_keys_and_exhausted_capacity :: proc(t:^testing.T) {
    lib:=make_library(t,keys=4,tracks=2,clips=2,markers=1)
    defer library_destroy(&lib)
    unsorted:=Track_Desc{target=1,keys={key(1,0),key(0,1)}}
    added :: proc(t:^testing.T,lib:^Library,desc:Clip_Desc,clip:Clip,error:Clip_Error,loc:=#caller_location) {
        got,why:=clip_add(lib,desc)
        testing.expect_value(t,got,clip,loc=loc)
        testing.expect_value(t,why,error,loc=loc)
    }
    added(t,&lib,{tracks={unsorted}},0,.Unsorted)
    three:=[]Keyframe{key(0,0),key(1,1),key(2,2)}
    added(t,&lib,{tracks={{target=1,keys=three}}},1,.None)
    added(t,&lib,{tracks={{target=1,keys=three}}},0,.Full) // keys: 3+3 > 4
    added(t,&lib,{markers={{time=1,id=1},{time=2,id=2}}},0,.Full) // markers: 2 > 1
    added(t,&lib,{tracks={{target=1,keys={key(0,0)}},{target=2},{target=3}}},0,.Full) // tracks: 1+3 > 2
    added(t,&lib,{markers={{time=1,id=1}}},2,.None)
    added(t,&lib,{},0,.Full) // clips: 2 of 2
    testing.expect_value(t,lib.clip_count,2)
}

@(test)
library_in_zero_state_and_with_invalid_handles_is_safe :: proc(t:^testing.T) {
    lib:Library
    zero,_:=clip_add(&lib,{})
    testing.expect_value(t,zero,Clip(0))
    testing.expect_value(t,clip_duration(&lib,1),f32(0))
    testing.expect(t,clip_tracks(&lib,5)==nil && clip_markers(&lib,0)==nil)
    library_destroy(&lib)
    testing.expect(t,!library_init(&lib,{}))
    testing.expect(t,!library_init(&lib,{max_keys=1,max_tracks=1,max_clips=0}))
    full:=make_library(t)
    defer library_destroy(&full)
    testing.expect_value(t,clip_data(&full,3),Clip_Data{})
}
