package mirai_anim

import "core:testing"
import math "mirai:std/math"

HIP :: u64(11)
ARM :: u64(22)

// A clip that holds one position on HIP for `duration` seconds.
pose_clip :: proc(lib:^Library,x:f32,duration:f32=1,loop:Loop=.Loop) -> Clip {
    clip,_:=clip_add(lib,{loop=loop,tracks={{target=HIP,property=.Position,keys={{time=0,value={x,0,0,0}},{time=duration,value={x,0,0,0}}}}}})
    return clip
}

@(test)
pose_blends_players_by_weight :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    pose:Pose
    testing.expect(t,pose_init(&pose,8))
    defer pose_destroy(&pose)
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,0),1,1))
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,8),1,3))
    position,weight,ok:=pose_position(&pose,HIP)
    testing.expect(t,ok && near_vec(position,math.Vec3{6,0,0}) && near(weight,4))
    testing.expect_value(t,pose.count,1)
    _,_,missing:=pose_position(&pose,ARM)
    testing.expect(t,!missing)
    pose_clear(&pose)
    _,_,gone:=pose_position(&pose,HIP)
    testing.expect(t,!gone && pose.count==0)
}

@(test)
pose_keeps_the_value_of_a_player_whose_weight_is_small :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,5),1,0.3))
    position,weight,_:=pose_position(&pose,HIP)
    testing.expect(t,near_vec(position,math.Vec3{5,0,0}) && near(weight,0.3))
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,9),1,0))
    _,after,_:=pose_position(&pose,HIP)
    testing.expect(t,near(after,0.3))
}

@(test)
pose_blends_rotations_on_the_short_arc :: proc(t:^testing.T) {
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    a:=math.quat_axis_angle({0,0,1},0.2)
    b:=math.quat_axis_angle({0,0,1},0.6)
    pose_add(&pose,HIP,.Rotation,0,quat_vec4(a),1)
    pose_add(&pose,HIP,.Rotation,0,-quat_vec4(b),1)
    q,weight,ok:=pose_rotation(&pose,HIP)
    testing.expect(t,ok && near(weight,2) && near(abs(q),1,1e-4))
    testing.expect(t,near(math.quat_angle(q,math.quat_axis_angle({0,0,1},0.4)),0,1e-3))
}

@(test)
pose_separates_targets_properties_and_slots :: proc(t:^testing.T) {
    pose:Pose
    testing.expect(t,pose_init(&pose,8))
    defer pose_destroy(&pose)
    pose_add(&pose,HIP,.Float,0,{1,0,0,0},1)
    pose_add(&pose,HIP,.Float,1,{2,0,0,0},1)
    pose_add(&pose,ARM,.Float,0,{3,0,0,0},1)
    pose_add(&pose,HIP,.Scale,0,{4,4,4,0},1)
    testing.expect_value(t,pose.count,4)
    a,_,_:=pose_float(&pose,HIP,0)
    b,_,_:=pose_float(&pose,HIP,1)
    c,_,_:=pose_float(&pose,ARM)
    scale,_,ok:=pose_scale(&pose,HIP)
    testing.expect(t,a==1 && b==2 && c==3 && ok && scale==math.Vec3{4,4,4})
    _,_,none:=pose_find(&pose,ARM,.Float,5)
    testing.expect(t,!none)
}

@(test)
pose_refuses_entries_past_its_capacity :: proc(t:^testing.T) {
    pose:Pose
    testing.expect(t,pose_init(&pose,2))
    defer pose_destroy(&pose)
    testing.expect(t,pose_add(&pose,1,.Float,0,{1,0,0,0},1))
    testing.expect(t,pose_add(&pose,2,.Float,0,{1,0,0,0},1))
    testing.expect(t,!pose_add(&pose,3,.Float,0,{1,0,0,0},1))
    testing.expect(t,pose_add(&pose,2,.Float,0,{3,0,0,0},1)) // an existing entry still mixes
    testing.expect_value(t,pose.failed,u64(1))
    testing.expect_value(t,pose.count,2)
    value,_,_:=pose_float(&pose,2)
    testing.expect(t,near(value,2))
    other:Pose
    testing.expect(t,!pose_init(&other,0))
    testing.expect(t,!pose_add(&other,1,.Float,0,{},1))
}

@(test)
fader_cross_fades_from_the_old_clip_to_the_new_one :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    idle,run:=pose_clip(&lib,0),pose_clip(&lib,10)
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    f:Fader
    fader_play(&f,idle)
    fader_advance(&lib,&f,0.5,nil)
    fader_play(&f,run,1,1)
    testing.expect(t,fader_fading(f) && near(fader_current_weight(f),0))
    fader_advance(&lib,&f,0.5,nil)
    fader_blend(&pose,&lib,f)
    position,weight,_:=pose_position(&pose,HIP)
    testing.expect(t,near(position.x,5) && near(weight,1))
    fader_advance(&lib,&f,0.75,nil)
    testing.expect(t,!fader_fading(f) && near(fader_current_weight(f),1))
    pose_clear(&pose)
    fader_blend(&pose,&lib,f)
    position,_,_=pose_position(&pose,HIP)
    testing.expect(t,near(position.x,10))
}

@(test)
fader_cuts_without_a_fade_and_nested_fades_keep_the_pose_where_it_was :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    a,b,c:=pose_clip(&lib,0),pose_clip(&lib,4),pose_clip(&lib,8)
    pose:Pose
    testing.expect(t,pose_init(&pose,8))
    defer pose_destroy(&pose)
    sample :: proc(pose:^Pose,lib:^Library,f:Fader) -> f32 {
        pose_clear(pose)
        fader_blend(pose,lib,f)
        position,_,_:=pose_position(pose,HIP)
        return position.x
    }
    f:Fader
    fader_play(&f,a)
    fader_play(&f,b)
    testing.expect(t,!fader_fading(f) && f.current.clip==b)
    fader_play(&f,a,1,2)
    fader_advance(&lib,&f,1,nil)
    before:=sample(&pose,&lib,f)
    testing.expect(t,near(before,2))
    // A third clip in the middle of the fade: the pose does not jump, and all three blend until it ends.
    fader_play(&f,c,1,2)
    testing.expect(t,f.current.clip==c && f.outgoing_count==2 && f.outgoing[0].player.clip==a && f.outgoing[1].player.clip==b)
    testing.expect(t,near(sample(&pose,&lib,f),before))
    fader_advance(&lib,&f,0.5,nil)
    middle:=sample(&pose,&lib,f)
    testing.expect(t,f.outgoing_count==2 && middle>before && middle<8)
    fader_advance(&lib,&f,1.5,nil)
    testing.expect(t,!fader_fading(f) && near(sample(&pose,&lib,f),8))
    // More fades than FADER_OUTGOING: the faintest leaves.
    for clip in ([?]Clip{a,b,c,a,b}) {
        fader_play(&f,clip,1,1)
        fader_advance(&lib,&f,0.1,nil)
    }
    testing.expect_value(t,f.outgoing_count,FADER_OUTGOING)
}

@(test)
fader_reports_the_markers_of_both_clips :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    a,_:=clip_add(&lib,{loop=.Loop,tracks={{target=HIP,property=.Float,keys={key(0,0),key(1,1)}}},markers={{0.5,1}}})
    b,_:=clip_add(&lib,{loop=.Loop,tracks={{target=HIP,property=.Float,keys={key(0,0),key(1,1)}}},markers={{0.5,2}}})
    f:Fader
    fader_play(&f,a)
    fader_advance(&lib,&f,0.25,nil)
    fader_play(&f,b,1,1)
    events:[4]Event
    written,dropped:=fader_advance(&lib,&f,0.5,events[:])
    testing.expect(t,written==2 && dropped==0 && events[0].id==2 && events[1].id==1)
    testing.expect(t,near(events[0].weight,1) && near(events[1].weight,1))
    written,dropped=fader_advance(&lib,&f,1,events[:0])
    testing.expect(t,written==0 && dropped==2)
}

@(test)
pose_drives_a_whole_clip_through_a_player :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{loop=.Once,tracks={
        {target=HIP,property=.Position,keys={{time=0,value={0,0,0,0}},{time=2,value={4,0,0,0}}}},
        {target=ARM,property=.Rotation,keys={rot_key(0,math.QUAT_IDENTITY),rot_key(2,math.quat_axis_angle({1,0,0},math.PI/2))}}}})
    p:=player_make(clip)
    player_advance(&lib,&p,1,nil)
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    pose_blend(&pose,&lib,p)
    position,_,_:=pose_position(&pose,HIP)
    rotation,_,_:=pose_rotation(&pose,ARM)
    testing.expect(t,near_vec(position,math.Vec3{2,0,0}) && near(math.quat_angle(math.QUAT_IDENTITY,rotation),math.PI/4,1e-3))
    pose_blend(&pose,&lib,player_make(99))
    testing.expect_value(t,pose.count,2)
}
