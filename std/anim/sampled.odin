package mirai_anim

import "base:intrinsics"
import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

Key_Encoding :: enum u8 {Raw,Sampled}

// The values of a track at a uniform rate from time 0 to `duration`, quantized by
// library_compress. With one sample it is a constant and `minimum` is its value (a rotation in
// xyzw). With more, they go in segments of SAMPLED_SEGMENT samples: a byte with the bit rate, a
// byte per component with where the segment's range starts and another with its span, both in
// 255ths of the track's range, and the samples packed component after component from the lowest
// bit. A rotation stores x, y and z of its quaternion with w>=0.
Sampled_Track :: struct {
    minimum,extent:math.Vec4,
    duration,rate:f32, // sample k is at min(k/rate,duration): the last interval may be shorter
    count:u32,
    data:u32,          // the byte of Library.samples where its first segment starts
    first_segment:u32, // in Library.segments
}
// A sampled track to add to a library: its header and the bytes of its segments.
Sampled_Desc :: struct {track:Sampled_Track,data:[]u8}

SAMPLED_SEGMENT :: 16
// The bits of a component stored as its f32.
SAMPLED_RAW :: 32
SAMPLED_MAX_BITS :: 19
// The bytes after the last segment: a component reads 8 bytes from the one it starts in.
SAMPLED_PADDING :: 8
SAMPLED_MAX_COUNT :: 1<<24

sampled_components :: #force_inline proc "contextless" (property:Property) -> int {
    switch property {
    case .Float:return 1
    case .Vector:return 4
    case .Position,.Rotation,.Scale:return 3
    }
    return 0
}
sampled_bits_valid :: #force_inline proc "contextless" (bits:int) -> bool {return bits==0 || bits==SAMPLED_RAW || bits>=3 && bits<=SAMPLED_MAX_BITS}
sampled_segment_bytes :: #force_inline proc "contextless" (components,bits,samples:int) -> int {return 1+2*components+(samples*components*bits+7)/8}

// The bytes and the segments of a sampled track whose segments start at track.data of `samples`,
// writing where each starts into `segments` when given. ok is false for a header that is not
// finite or not consistent, or a segment that does not fit with `padding` bytes after it.
sampled_walk :: proc "contextless" (track:Sampled_Track,property:Property,samples:[]u8,segments:[]u32=nil,padding:=SAMPLED_PADDING) -> (bytes,count:int,ok:bool) {
    components:=sampled_components(property)
    if components==0 || track.count==0 || track.count>SAMPLED_MAX_COUNT || !anim_finite(track.duration) || track.duration<0 {return}
    for i in 0..<4 {if !anim_finite(track.minimum[i]) || !anim_finite(track.extent[i]) || track.extent[i]<0 || !anim_finite(track.minimum[i]+track.extent[i]) {return}}
    if track.count==1 {return 0,0,true}
    span:=track.rate*track.duration
    if !(track.duration>0) || !anim_finite(track.rate) || !(span>f32(track.count)-2) || span>f32(track.count-1)+1e-3 {return}
    count=(int(track.count)+SAMPLED_SEGMENT-1)/SAMPLED_SEGMENT
    if segments!=nil && len(segments)<count {return}
    at:=int(track.data)
    if at>len(samples) {return}
    for s in 0..<count {
        if len(samples)-at<1+2*components {return}
        bits:=int(samples[at])
        if !sampled_bits_valid(bits) {return}
        for c in 0..<components {if int(samples[at+1+c])+int(samples[at+1+components+c])>255 {return}}
        size:=sampled_segment_bytes(components,bits,min(SAMPLED_SEGMENT,int(track.count)-s*SAMPLED_SEGMENT))
        if size>len(samples)-at-padding {return}
        if segments!=nil {segments[s]=u32(at)}
        at+=size
    }
    return at-int(track.data),count,true
}

// The value of a sampled track at a time, as clip_evaluate gives it.
sampled_evaluate :: proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {
    if int(track.first)>=len(lib.sampled) {return {}}
    s:=lib.sampled[track.first]
    if s.count<=1 {return s.minimum}
    components:=sampled_components(track.property)
    last:=int(s.count)-1
    position:=time*s.rate
    if !(position>0) {position=0}
    end:=s.duration*s.rate
    if position>=end || position>=f32(last) {return sampled_finish(sampled_value(lib,s,components,last),track.property)}
    index:=min(int(position),last-1)
    amount:=position-f32(index)
    if index==last-1 {amount=min(amount/(end-f32(index)),1)}
    return sampled_mix(sampled_value(lib,s,components,index),sampled_value(lib,s,components,index+1),amount,track.property)
}

// Between two decoded samples: a rotation by normalized lerp on the short arc.
@(private)
sampled_mix :: #force_inline proc "contextless" (a,b:math.Vec4,amount:f32,property:Property) -> math.Vec4 {
    if property==.Rotation {
        qa,qb:=sampled_quat(a),sampled_quat(b)
        if linalg.dot(qa,qb)<0 {qb=-qb}
        return linalg.normalize0(qa+(qb-qa)*amount)
    }
    return a+(b-a)*amount
}
@(private)
sampled_finish :: #force_inline proc "contextless" (v:math.Vec4,property:Property) -> math.Vec4 {return sampled_quat(v) if property==.Rotation else v}
// x, y and z of a unit quaternion with w>=0, with its w again.
@(private)
sampled_quat :: #force_inline proc "contextless" (v:math.Vec4) -> math.Vec4 {return {v.x,v.y,v.z,cmath.sqrt(max(1-v.x*v.x-v.y*v.y-v.z*v.z,0))}}

@(private)
sampled_value :: proc "contextless" (lib:^Library,track:Sampled_Track,components,index:int) -> (value:math.Vec4) {
    at:=int(lib.segments[int(track.first_segment)+index/SAMPLED_SEGMENT])
    data:=lib.samples
    bits:=int(data[at])
    position:=(at+1+2*components)*8+(index%SAMPLED_SEGMENT)*components*bits
    for c in 0..<components {
        if bits==SAMPLED_RAW {value[c]=transmute(f32)sampled_read(data,position,SAMPLED_RAW)} else {
            value[c]=track.minimum[c]+track.extent[c]*sampled_part(data[at+1+c],data[at+1+components+c],bits,sampled_read(data,position,bits) if bits>0 else 0)
        }
        position+=bits
    }
    return
}
@(private)
sampled_read :: #force_inline proc "contextless" (data:[]u8,position,bits:int) -> u32 {
    word:=intrinsics.unaligned_load((^u64)(raw_data(data[position>>3:][:8])))
    return u32((word>>uint(position&7))&(u64(1)<<uint(bits)-1))
}
// Where a quantized value falls in its track's range, in [0,1].
@(private)
sampled_part :: #force_inline proc "contextless" (low,span:u8,bits:int,q:u32) -> f32 {
    if bits==0 {return f32(low)/255}
    return (f32(low)+f32(span)*(f32(q)/f32(u32(1)<<uint(bits)-1)))/255
}
