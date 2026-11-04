package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

Key_Encoding :: enum u8 {Raw,Quantized}

Packed_Key :: struct {
    time:f32,
    value:[4]u16,
    ease:math.Ease,
    interpolation:Interpolation,
}
Packed_Bounds :: struct {minimum,extent:math.Vec4}

// A view owns no memory; cooked keys are decoded when queried.
Key_Source :: struct {
    keys:[]Keyframe,
    packed:[]Packed_Key,
    bounds:Packed_Bounds,
}
@(private) Packed_Source :: struct {keys:[]Packed_Key,bounds:Packed_Bounds}

@(private) key_source_count :: #force_inline proc "contextless" (source:$T) -> int {
    when T==[]Keyframe {return len(source)} else {return len(source.keys)}
}
@(private) key_source_time :: #force_inline proc "contextless" (source:$T,index:int) -> f32 {
    when T==[]Keyframe {return source[index].time} else {return source.keys[index].time}
}
@(private) key_source_key :: #force_inline proc "contextless" (source:$T,index:int,property:Property) -> Keyframe {
    when T==[]Keyframe {return source[index]} else {
        packed:=source.keys[index]
        value:math.Vec4
        for i in 0..<4 {value[i]=source.bounds.minimum[i]+source.bounds.extent[i]*(f32(packed.value[i])/65535)}
        if property==.Rotation {value=quat_vec4(linalg.normalize0(vec4_quat(value)))}
        return {time=packed.time,value=value,ease=packed.ease,interpolation=packed.interpolation}
    }
}

track_source :: #force_inline proc "contextless" (lib:^Library,track:Track) -> (Key_Source,bool) {
    if lib==nil || track.property>.Vector {return {},false}
    switch track.encoding {
    case .Raw:
        keys:=track_keys(lib,track)
        return {keys=keys},len(keys)==int(track.count)
    case .Quantized:
        if int(track.first)>len(lib.packed_keys) || int(track.count)>len(lib.packed_keys)-int(track.first) || int(track.bounds)>=len(lib.packed_bounds) {return {},false}
        bounds:=lib.packed_bounds[track.bounds]
        for i in 0..<4 {if !anim_finite(bounds.minimum[i]) || !anim_finite(bounds.extent[i]) || !anim_finite(bounds.minimum[i]+bounds.extent[i]) || bounds.extent[i]<0 {return {},false}}
        return {packed=lib.packed_keys[track.first:][:track.count],bounds=bounds},true
    }
    return {},false
}

// Includes the raw and the prepared keys, without requiring editable storage.
track_key :: proc "contextless" (lib:^Library,track:Track,index:int) -> (Keyframe,bool) {
    source,valid:=track_source(lib,track)
    if !valid || index<0 || index>=int(track.count) {return {},false}
    key:Keyframe
    if track.encoding==.Raw {key=key_source_key(source.keys,index,track.property)} else {key=key_source_key(Packed_Source{source.packed,source.bounds},index,track.property)}
    if track.encoding==.Quantized && (!anim_finite(key.time) || key.time<0 || key.interpolation>.Step || key.ease!=.Linear || track.property==.Rotation && !anim_rotation_valid(vec4_quat(key.value))) {return {},false}
    return key,true
}
