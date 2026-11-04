package mirai_anim

import "base:runtime"
import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(test)
resident_animation_preserves_slots_markers_duration_and_samples_within_error_budgets :: proc(t:^testing.T) {
    COUNT :: 121
    keys:[5][COUNT]Keyframe;tracks:[5]Track_Desc
    for &track,p in tracks {
        track={target=19,property=Property(p),slot=u8(p+3),keys=keys[p][:]}
        for &key,k in keys[p] {
            phase:=f32(k)/f32(COUNT-1);s,c:=cmath.sincos(phase*math.TAU)
            key.time=phase*3
            switch track.property {
            case .Position:key.value={s*.8,phase*.03,c*.2,0}
            case .Rotation:key.value=quat_vec4(math.quat_axis_angle({0,1,0},s*1.4));if k%3==0 {key.value=-key.value}
            case .Scale:key.value={1+.1*s,1+.02*c,1,0}
            case .Float:key.value={phase*.3+cmath.sin(phase*21)*.01,0,0,0}
            case .Vector:key.value={s,c,s*.4,c*.05}
            }
        }
    }
    lib:=make_library(t,keys=COUNT*5,tracks=5,clips=2,markers=2);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{name=73,loop=.Once,tracks=tracks[:],markers={{time=2.1,id=17},{time=.2,id=11}}})
    original:=clip_data(&lib,clip);lib.clips[1]=original;lib.clips[1].loop=.Loop;lib.clip_count=2
    config:=OPTIMIZE_DEFAULT
    stats,error:=library_optimize(&lib,config)
    testing.expect_value(t,error,Optimize_Error.None)
    testing.expect(t,stats.resident_bytes<stats.raw_bytes && stats.resident_keys<stats.original_keys && stats.quantized_tracks==5)
    testing.expect_value(t,clip_data(&lib,clip),original)
    testing.expect(t,clip_data(&lib,2).loop==.Loop && clip_tracks(&lib,clip)[0]==clip_tracks(&lib,2)[0])
    testing.expect_value(t,clip_markers(&lib,clip)[0],Marker{time=.2,id=11})
    testing.expect_value(t,clip_markers(&lib,clip)[1],Marker{time=2.1,id=17})
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    max_errors:[5]f32
    for track,p in clip_tracks(&lib,clip) {
        testing.expect_value(t,track.slot,u8(p+3))
        testing.expect(t,track_keys(&lib,track)==nil)
        for sample in 0..<1501 {
            time:=f32(sample)/1500*3
            before:=track_evaluate(keys[p][:],track.property,time);after:=clip_evaluate(&lib,track,time)
            error:=optimize_norm(after-before,track.property)
            if track.property==.Rotation {error=math.quat_angle(vec4_quat(before),vec4_quat(after))}
            max_errors[p]=max(max_errors[p],error)
            testing.expect(t,error<=optimize_tolerance(config,track.property)+2e-6)
        }
        decoded,valid:=track_key(&lib,track,0);testing.expect(t,valid && decoded.time==0)
        _,valid=track_key(&lib,track,-1);testing.expect(t,!valid)
    }
    context=saved
    testing.expect(t,max_errors[0]<=stats.position_bound+2e-6 && max_errors[1]<=stats.angular_bound+2e-6 && max_errors[2]<=stats.scale_bound+2e-6 && max_errors[3]<=stats.float_bound+2e-6 && max_errors[4]<=stats.vector_bound+2e-6)
    _,refused:=clip_add(&lib,{})
    testing.expect_value(t,refused,Clip_Error.Prepared)
    _,error=library_optimize(&lib);testing.expect_value(t,error,Optimize_Error.Prepared)
}

@(test)
resident_animation_keeps_cubic_tangents_easing_and_ambiguous_rotation_arcs_raw :: proc(t:^testing.T) {
    cubic:=[3]Keyframe{key(0,0,.Cubic_Spline),key(1,1,.Cubic_Spline),key(2,0,.Cubic_Spline)}
    for &key in cubic {key.tangents=true;key.in_slope={-2,0,0,0};key.out_slope={3,0,0,0}}
    eased:=[2]Keyframe{key(0,0),key(1,3,.Linear,.Back_Out)}
    ambiguous:=[2]Keyframe{rot_key(0,1),rot_key(1,math.quat_axis_angle({0,1,0},math.PI))}
    spline:=[3]Keyframe{rot_key(0,1,.Cubic),rot_key(1,math.quat_axis_angle({0,1,0},.4),.Cubic),rot_key(2,math.quat_axis_angle({0,1,0},.8),.Cubic)}
    desc:=[4]Track_Desc{{property=.Float,keys=cubic[:]},{property=.Float,keys=eased[:]},{property=.Rotation,keys=ambiguous[:]},{property=.Rotation,keys=spline[:]}}
    lib:=make_library(t);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks=desc[:]})
    _,error:=library_optimize(&lib)
    testing.expect_value(t,error,Optimize_Error.None)
    for track,i in clip_tracks(&lib,clip) {
        testing.expect_value(t,track.encoding,Key_Encoding.Raw)
        testing.expect_value(t,int(track.count),len(desc[i].keys))
        for sample in 0..<101 {time:=f32(sample)/100*2;testing.expect_value(t,clip_evaluate(&lib,track,time),track_evaluate(desc[i].keys,track.property,time))}
    }
    testing.expect(t,track_keys(&lib,clip_tracks(&lib,clip)[0])[1].out_slope==cubic[1].out_slope)
}

@(test)
resident_animation_reduces_constants_and_linear_tracks_without_changing_clip_duration :: proc(t:^testing.T) {
    constant:=[4]Keyframe{key(0,7),key(1,7),key(2,7),key(5,7)}
    line:=[5]Keyframe{key(0,0),key(1,2),key(2,4),key(3,6),key(4,8)}
    step:=[3]Keyframe{key(0,1),key(1,3,.Step),key(2,2,.Step)}
    one:=[1]Keyframe{key(1,9)}
    lib:=make_library(t);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks={{property=.Float,keys=constant[:]},{property=.Float,keys=line[:]},{property=.Float,keys=step[:]},{property=.Float,keys=one[:]},{property=.Float}}})
    config:=OPTIMIZE_DEFAULT;config.quantize=false
    _,error:=library_optimize(&lib,config);testing.expect_value(t,error,Optimize_Error.None)
    tracks:=clip_tracks(&lib,clip)
    testing.expect_value(t,tracks[0].count,u32(1));testing.expect_value(t,tracks[1].count,u32(2))
    testing.expect_value(t,tracks[2].count,u32(3));testing.expect_value(t,tracks[3].count,u32(1));testing.expect_value(t,tracks[4].count,u32(0))
    testing.expect_value(t,clip_duration(&lib,clip),f32(5))
    for sample in 0..<101 {time:=f32(sample)/20;testing.expect_value(t,clip_evaluate(&lib,tracks[0],time).x,f32(7));testing.expect(t,near(clip_evaluate(&lib,tracks[1],time).x,min(time*2,8)))}
}

@(test)
resident_animation_accepts_valid_repeated_times_and_nonunit_source_rotations_as_raw :: proc(t:^testing.T) {
    repeated:=[4]Keyframe{key(0,0),key(1,1),key(1,3),key(2,5)}
    rotations:=[2]Keyframe{rot_key(0,math.Quat(2)),rot_key(1,math.quat_axis_angle({0,1,0},.7)*2)}
    lib:=make_library(t);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks={{property=.Float,keys=repeated[:]},{property=.Rotation,keys=rotations[:]}}})
    _,error:=library_optimize(&lib);testing.expect_value(t,error,Optimize_Error.None)
    tracks:=clip_tracks(&lib,clip)
    testing.expect(t,tracks[0].encoding==.Raw && tracks[1].encoding==.Raw && tracks[0].count==4 && tracks[1].count==2)
    for sample in 0..<101 {
        time:=f32(sample)/50
        testing.expect_value(t,clip_evaluate(&lib,tracks[0],time),track_evaluate(repeated[:],.Float,time))
        testing.expect_value(t,clip_evaluate(&lib,tracks[1],time),track_evaluate(rotations[:],.Rotation,time))
    }
}

@(private) Optimize_Allocation_Failure :: struct {owner:runtime.Allocator,remaining:int}
@(private)
optimize_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Optimize_Allocation_Failure)(data)
    if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {if state.remaining==0 {return nil,.Out_Of_Memory};state.remaining-=1}
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
resident_animation_preparation_rolls_back_every_allocation_failure_and_rejects_hostile_data :: proc(t:^testing.T) {
    success:=false
    for budget in 0..<16 {
        failure:=Optimize_Allocation_Failure{owner=context.allocator,remaining=32}
        lib:Library;testing.expect(t,library_init(&lib,{max_keys=8,max_tracks=2,max_clips=1,max_markers=1,allocator={optimize_failure_allocator,&failure}}))
        clip,_:=clip_add(&lib,{tracks={{property=.Position,keys={{time=0,value={0,1,2,0}},{time=1,value={1,0,3,0}}}},{property=.Float,keys={key(0,0,.Cubic),key(1,3,.Cubic)}}},markers={{time=.5,id=19}}})
        old_keys,old_tracks:=raw_data(lib.keys),raw_data(lib.tracks);old_count:=lib.key_count
        failure.remaining=budget
        _,error:=library_optimize(&lib)
        if error==.None {success=true;library_destroy(&lib);break}
        testing.expect_value(t,error,Optimize_Error.Out_Of_Memory)
        testing.expect(t,raw_data(lib.keys)==old_keys && raw_data(lib.tracks)==old_tracks && lib.key_count==old_count && !lib.prepared && lib.packed_keys==nil)
        testing.expect(t,near(clip_evaluate(&lib,clip_tracks(&lib,clip)[0],.5).x,.5))
        library_destroy(&lib)
    }
    testing.expect(t,success)
    lib:=make_library(t);defer library_destroy(&lib)
    clip_add(&lib,{tracks={{property=.Float,keys={key(0,0),key(1,1)}}}})
    original:=lib.keys[1];lib.keys[1].time=-.1
    _,error:=library_optimize(&lib);testing.expect_value(t,error,Optimize_Error.Invalid);testing.expect(t,!lib.prepared)
    lib.keys[1]=original;lib.keys[1].value.x=transmute(f32)u32(0x7f800000)
    _,error=library_optimize(&lib);testing.expect_value(t,error,Optimize_Error.Invalid)
    lib.keys[1]=original
    config:=OPTIMIZE_DEFAULT;config.angular_error=-1
    _,error=library_optimize(&lib,config);testing.expect_value(t,error,Optimize_Error.Invalid)
    config=OPTIMIZE_DEFAULT;config.float_error=0
    _,error=library_optimize(&lib,config);testing.expect_value(t,error,Optimize_Error.None)
    testing.expect_value(t,clip_tracks(&lib,1)[0].encoding,Key_Encoding.Raw)
}

@(test)
resident_animation_decoder_rejects_corrupt_ranges_bounds_and_quantized_key_metadata :: proc(t:^testing.T) {
    lib:=make_library(t);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks={{property=.Vector,keys={{time=0,value={1,2,3,4}},{time=1,value={4,1,2,7}}}}}})
    _,error:=library_optimize(&lib);testing.expect_value(t,error,Optimize_Error.None)
    track:=clip_tracks(&lib,clip)[0];testing.expect_value(t,track.encoding,Key_Encoding.Quantized)
    bad:=track;bad.first=max(u32);testing.expect_value(t,clip_evaluate(&lib,bad,.5),math.Vec4{})
    bad=track;bad.count=max(u32);_,valid:=track_source(&lib,bad);testing.expect(t,!valid)
    bad=track;bad.bounds=max(u32);_,valid=track_key(&lib,bad,0);testing.expect(t,!valid)
    bounds:=lib.packed_bounds[track.bounds];lib.packed_bounds[track.bounds].extent.x=-1
    _,valid=track_source(&lib,track);testing.expect(t,!valid);testing.expect_value(t,clip_evaluate(&lib,track,.5),math.Vec4{})
    lib.packed_bounds[track.bounds]=bounds
    lib.packed_keys[track.first].ease=.Back_Out
    _,valid=track_key(&lib,track,0);testing.expect(t,!valid)
    lib.packed_keys[track.first].ease=.Linear;lib.packed_keys[track.first].time=transmute(f32)u32(0x7f800000)
    _,valid=track_key(&lib,track,0);testing.expect(t,!valid)
}

@(test)
resident_animation_randomized_linear_curves_respect_continuous_error_and_raw_fallback :: proc(t:^testing.T) {
    rng:=math.rng_make(419)
    ROUNDS :: #config(ANIM_COMPACT_HOSTILE_ROUNDS,80)
    for round in 0..<ROUNDS {
        keys:[16]Keyframe
        property:=Property(round%5)
        for &key,i in keys {
            key.time=f32(i)*.13
            key.value={math.random_range(&rng,-3,3),math.random_range(&rng,-3,3),math.random_range(&rng,-3,3),math.random_range(&rng,-3,3)}
            if property==.Rotation {key.value=quat_vec4(math.quat_axis_angle({0,1,0},math.random_range(&rng,-3,3)))}
        }
        lib:=make_library(t,keys=16,tracks=1,clips=1,markers=0)
        clip,_:=clip_add(&lib,{tracks={{property=property,keys=keys[:]}}})
        _,error:=library_optimize(&lib);testing.expect_value(t,error,Optimize_Error.None)
        track:=clip_tracks(&lib,clip)[0]
        for sample in 0..<201 {
            time:=f32(sample)/200*keys[len(keys)-1].time;before:=track_evaluate(keys[:],property,time);after:=clip_evaluate(&lib,track,time)
            error:=optimize_norm(after-before,property);if property==.Rotation {error=math.quat_angle(vec4_quat(before),vec4_quat(after))}
            testing.expect(t,error<=optimize_tolerance(OPTIMIZE_DEFAULT,property)+3e-6)
        }
        library_destroy(&lib)
    }
}
