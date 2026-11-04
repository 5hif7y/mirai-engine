package mirai_anim

import "base:runtime"
import "core:math/linalg"
import math "mirai:std/math"

Optimize_Config :: struct {
    position_error,angular_error,scale_error,float_error,vector_error:f32,
    reduce,quantize:bool,
}
OPTIMIZE_DEFAULT :: Optimize_Config{position_error=.0005,angular_error=.001,scale_error=.0001,float_error=.0001,vector_error=.0001,reduce=true,quantize=true}
Optimize_Error :: enum u8 {None,Invalid,Out_Of_Memory,Prepared}
Optimize_Stats :: struct {
    raw_bytes,resident_bytes:int,
    original_keys,resident_keys,quantized_tracks,raw_tracks:int,
    position_bound,angular_bound,scale_bound,float_bound,vector_bound:f32,
}

@(private) Optimize_Plan :: struct {first,count:int,encoding:Key_Encoding,bounds:Packed_Bounds,error:f32}
@(private) Optimize_Interval :: struct {first,last:int}

library_resident_bytes :: proc "contextless" (lib:^Library) -> int {
    if lib==nil {return 0}
    return len(lib.keys)*size_of(Keyframe)+len(lib.packed_keys)*size_of(Packed_Key)+len(lib.packed_bounds)*size_of(Packed_Bounds)+len(lib.tracks)*size_of(Track)+len(lib.clips)*size_of(Clip_Data)+len(lib.markers)*size_of(Marker)
}

@(private)
optimize_config_valid :: proc "contextless" (config:Optimize_Config) -> bool {
    for value in ([5]f32{config.position_error,config.angular_error,config.scale_error,config.float_error,config.vector_error}) {if !anim_finite(value) || value<0 {return false}}
    return true
}
@(private)
optimize_tolerance :: proc "contextless" (config:Optimize_Config,property:Property) -> f32 {
    switch property {
    case .Position:return config.position_error
    case .Rotation:return config.angular_error
    case .Scale:return config.scale_error
    case .Float:return config.float_error
    case .Vector:return config.vector_error
    }
    return 0
}
@(private)
optimize_norm :: proc "contextless" (value:math.Vec4,property:Property) -> f32 {
    switch property {
    case .Float:return abs(value.x)
    case .Position,.Scale:return linalg.length(math.Vec3{value.x,value.y,value.z})
    case .Rotation,.Vector:return linalg.length(value)
    }
    return 0
}
@(private)
optimize_keys_valid :: proc "contextless" (keys:[]Keyframe,property:Property) -> bool {
    if property>.Vector {return false}
    for key,i in keys {
        if !anim_finite(key.time) || key.time<0 || i>0 && key.time<keys[i-1].time || key.interpolation>max(Interpolation) || key.ease>max(math.Ease) {return false}
        for v in key.value {if !anim_finite(v) {return false}}
        if key.tangents {for v in key.in_slope {if !anim_finite(v) {return false}};for v in key.out_slope {if !anim_finite(v) {return false}}}
        if property==.Rotation && abs(key.value.x)+abs(key.value.y)+abs(key.value.z)+abs(key.value.w)<1e-8 {return false}
    }
    return true
}
@(private)
optimize_simple :: proc "contextless" (keys:[]Keyframe) -> bool {
    for key,i in keys {if i>0 && key.time<=keys[i-1].time || key.tangents || key.ease!=.Linear || (key.interpolation!=.Linear && key.interpolation!=.Step) {return false}}
    return true
}
@(private)
optimize_reduction_roundoff :: proc "contextless" (keys:[]Keyframe,property:Property) -> f32 {
    high:math.Vec4
    for key in keys {for i in 0..<4 {high[i]=max(high[i],abs(key.value[i]))}}
    return optimize_norm(high*(8*1.1920929e-7),property)
}
@(private)
optimize_reduce :: proc "contextless" (keys:[]Keyframe,property:Property,tolerance:f32,keep:[]bool,stack:[]Optimize_Interval) -> f32 {
    if len(keys)<2 {if len(keys)==1 {keep[0]=true};return 0}
    constant:=true
    for key in keys[1:] {if key.value!=keys[0].value {constant=false;break}}
    if constant {keep[0]=true;return 0}
    linear:=property!=.Rotation
    for key in keys {if key.interpolation!=.Linear {linear=false;break}}
    if !linear || tolerance<=0 {for &value in keep {value=true};return 0}
    keep[0],keep[len(keys)-1]=true,true
    stack[0]={0,len(keys)-1};size:=1;bound:f32
    for size>0 {
        size-=1;interval:=stack[size];a,b:=keys[interval.first],keys[interval.last]
        worst:f32;at:=interval.first
        for i in interval.first+1..<interval.last {
            amount:=(keys[i].time-a.time)/(b.time-a.time)
            error:=optimize_norm(keys[i].value-(a.value+(b.value-a.value)*amount),property)
            if !anim_finite(error) {error=max(f32)}
            if error>worst {worst,at=error,i}
        }
        if worst>tolerance {
            keep[at]=true
            stack[size]={interval.first,at};size+=1
            stack[size]={at,interval.last};size+=1
        } else {bound=max(bound,worst)}
    }
    return bound
}
@(private)
optimize_bounds :: proc "contextless" (keys:[]Keyframe,indices:[]u32,property:Property) -> Packed_Bounds {
    if property==.Rotation {return {minimum={-1,-1,-1,-1},extent={2,2,2,2}}}
    low,high:=keys[indices[0]].value,keys[indices[0]].value
    for index in indices[1:] {for i in 0..<4 {low[i]=min(low[i],keys[index].value[i]);high[i]=max(high[i],keys[index].value[i])}}
    return {minimum=low,extent=high-low}
}
@(private)
optimize_quantization_bound :: proc "contextless" (bounds:Packed_Bounds,property:Property) -> f32 {
    if property==.Rotation {
        // Conservative geodesic distance of slerp away from its hemisphere cut.
        ENDPOINT_ERROR :: 2.0/65535
        return 16*ENDPOINT_ERROR/(1-ENDPOINT_ERROR)
    }
    roundoff:math.Vec4
    for i in 0..<4 {roundoff[i]=(abs(bounds.minimum[i])+bounds.extent[i])*8*1.1920929e-7}
    return optimize_norm(bounds.extent*(.5/65535)+roundoff,property)
}
@(private)
optimize_rotation_packable :: proc "contextless" (keys:[]Keyframe,indices:[]u32) -> bool {
    for index,i in indices {
        value:=keys[index].value
        if abs(linalg.dot(value,value)-1)>1e-5 {return false}
        if i>0 && abs(linalg.dot(value,keys[indices[i-1]].value))<.02 {return false}
    }
    return true
}
@(private)
optimize_pack_key :: proc "contextless" (key:Keyframe,bounds:Packed_Bounds) -> Packed_Key {
    packed:=Packed_Key{time=key.time,ease=key.ease,interpolation=key.interpolation}
    for i in 0..<4 {if bounds.extent[i]>0 {packed.value[i]=u16(clamp((key.value[i]-bounds.minimum[i])/bounds.extent[i],0,1)*65535+.5)}}
    return packed
}

// Transaction: failures keep the library editable. After success it does not accept clip_add.
library_optimize :: proc(lib:^Library,config:Optimize_Config=OPTIMIZE_DEFAULT) -> (stats:Optimize_Stats,error:Optimize_Error) {
    if lib==nil || lib.allocator.procedure==nil || !optimize_config_valid(config) || lib.key_count<0 || lib.key_count>len(lib.keys) || lib.track_count<0 || lib.track_count>len(lib.tracks) || lib.clip_count<0 || lib.clip_count>len(lib.clips) || lib.marker_count<0 || lib.marker_count>len(lib.markers) {return {},.Invalid}
    if lib.prepared {return {},.Prepared}
    for clip in lib.clips[:lib.clip_count] {
        if !anim_finite(clip.duration) || clip.duration<0 || int(clip.first_track)>lib.track_count || int(clip.track_count)>lib.track_count-int(clip.first_track) || int(clip.first_marker)>lib.marker_count || int(clip.marker_count)>lib.marker_count-int(clip.first_marker) {return {},.Invalid}
    }
    for marker in lib.markers[:lib.marker_count] {if !anim_finite(marker.time) || marker.time<0 {return {},.Invalid}}
    allocator:=lib.allocator
    stats.raw_bytes=library_resident_bytes(lib);stats.original_keys=lib.key_count
    plans,e1:=make([]Optimize_Plan,lib.track_count,allocator)
    indices,e2:=make([]u32,lib.key_count,allocator)
    keep,e3:=make([]bool,lib.key_count,allocator)
    stack,e4:=make([]Optimize_Interval,lib.key_count,allocator)
    defer delete(plans,allocator);defer delete(indices,allocator);defer delete(keep,allocator);defer delete(stack,allocator)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil {return stats,.Out_Of_Memory}
    raw_count,packed_count,bounds_count,at:=0,0,0,0
    for track,i in lib.tracks[:lib.track_count] {
        keys:=track_keys(lib,track)
        if len(keys)!=int(track.count) || !optimize_keys_valid(keys,track.property) || len(keys)>len(indices)-at {return stats,.Invalid}
        plan:=&plans[i];plan.first=at;simple:=optimize_simple(keys)
        tolerance:=optimize_tolerance(config,track.property)
        retained:=keep[:len(keys)];for &value in retained {value=false}
        roundoff:=optimize_reduction_roundoff(keys,track.property)
        if simple && config.reduce {plan.error=optimize_reduce(keys,track.property,max(tolerance*.5-roundoff,0),retained,stack)} else {for &value in retained {value=true}}
        for value,k in retained {if value {indices[at]=u32(k);at+=1}}
        plan.count=at-plan.first
        if plan.count>1 && plan.count<len(keys) {plan.error+=roundoff}
        stats.resident_keys+=plan.count
        if simple && config.quantize && plan.count>0 {
            retained_indices:=indices[plan.first:][:plan.count]
            plan.bounds=optimize_bounds(keys,retained_indices,track.property)
            quantization:=optimize_quantization_bound(plan.bounds,track.property)
            finite:=true;for value in plan.bounds.extent {if !anim_finite(value) {finite=false}}
            bytes:=plan.count*size_of(Packed_Key)+size_of(Packed_Bounds)
            if finite && plan.error+quantization<=tolerance && bytes<plan.count*size_of(Keyframe) && (track.property!=.Rotation || optimize_rotation_packable(keys,retained_indices)) {plan.encoding=.Quantized;plan.error+=quantization}
        }
        if plan.encoding==.Quantized {packed_count+=plan.count;bounds_count+=1;stats.quantized_tracks+=1} else {raw_count+=plan.count;stats.raw_tracks+=1}
        switch track.property {
        case .Position:stats.position_bound=max(stats.position_bound,plan.error)
        case .Rotation:stats.angular_bound=max(stats.angular_bound,plan.error)
        case .Scale:stats.scale_bound=max(stats.scale_bound,plan.error)
        case .Float:stats.float_bound=max(stats.float_bound,plan.error)
        case .Vector:stats.vector_bound=max(stats.vector_bound,plan.error)
        }
    }
    raw,e5:=make([]Keyframe,raw_count,allocator)
    packed,e6:=make([]Packed_Key,packed_count,allocator)
    bounds,e7:=make([]Packed_Bounds,bounds_count,allocator)
    tracks,e8:=make([]Track,lib.track_count,allocator)
    if e5!=nil || e6!=nil || e7!=nil || e8!=nil {delete(raw,allocator);delete(packed,allocator);delete(bounds,allocator);delete(tracks,allocator);return stats,.Out_Of_Memory}
    raw_at,packed_at,bound_at:=0,0,0
    for track,i in lib.tracks[:lib.track_count] {
        plan:=plans[i];keys:=track_keys(lib,track);result:=track;result.count=u32(plan.count);result.encoding=plan.encoding
        if plan.encoding==.Quantized {
            result.first=u32(packed_at);result.bounds=u32(bound_at);bounds[bound_at]=plan.bounds;bound_at+=1
            for index in indices[plan.first:][:plan.count] {packed[packed_at]=optimize_pack_key(keys[index],plan.bounds);packed_at+=1}
        } else {
            result.first=u32(raw_at)
            for index in indices[plan.first:][:plan.count] {raw[raw_at]=keys[index];raw_at+=1}
        }
        tracks[i]=result
    }
    delete(lib.keys,allocator);delete(lib.tracks,allocator)
    lib.keys,lib.packed_keys,lib.packed_bounds,lib.tracks=raw,packed,bounds,tracks
    lib.key_count=raw_count;lib.prepared=true
    stats.resident_bytes=library_resident_bytes(lib)
    return stats,.None
}
