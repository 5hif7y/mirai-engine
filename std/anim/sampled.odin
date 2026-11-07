package mirai_anim

import "base:intrinsics"
import cmath "core:math"
import "core:simd"
import math "mirai:std/math"

Key_Encoding :: enum u8 {Raw,Sampled}

// The tracks of a clip as library_compress leaves them: one stream per clip with every track's
// values at a uniform rate from time 0 to `duration` (sample k at min(k/rate,duration): the last
// interval may be shorter). Little endian, without alignment:
//
//   Stream_Header
//   codes      4 bits per track of the clip, from the lowest: its Stream_Kind and then its
//              Stream_Width
//   constants  per Constant track its components as f32
//   ranges     per Animated track the minimum of each component and, after those of every
//              track, the extent of each, as f32
//   segments   per segment its Stream_Segment
//   per segment, from Stream_Segment.bits: a byte per Animated track with its bits per component
//              (stream_bits_valid), two bytes per component of each with fewer than STREAM_RAW,
//              and its samples one after another, each with the components of every Animated
//              track in their order, packed from the lowest bit
//
// A component with b bits in 1..STREAM_MAX_BITS is q/(2^b-1) of its segment's range, which starts
// low/255 into the track's range and spans span/255 of it (its two bytes); with 0 bits it holds
// still in the segment at (low|span<<8)/65535 of the track's range; STREAM_RAW keeps its f32. A
// stream of one segment has no range bytes and no 0 bits: its segment's range is the track's. A
// rotation stores x, y and z of its quaternion with w>=0. A Default track holds STREAM_DEFAULTS
// of its property; a Keys track keeps its keys in the library.
Stream_Header :: struct #packed {
    bytes:u32, // the whole stream, without the STREAM_PADDING after it
    count:u32, // samples
    rate,duration:f32,
    tracks,constants,animated,segments:u32,
    ranges,table:u32, // where the ranges and the segments start
}
Stream_Segment :: struct #packed {
    start:u32,   // its first sample
    bits:u32,    // where its bytes start in the stream
    samples:u32, // where its samples start in the stream
    stride:u32,  // the bits of one of its samples
}
Stream_Kind :: enum u8 {Default,Constant,Animated,Keys}
Stream_Width :: enum u8 {One,Three,Four}

STREAM_RAW :: 32
STREAM_MAX_BITS :: 23
// The bytes after the last stream: a component reads 8 bytes from the one it starts in.
STREAM_PADDING :: 8
STREAM_MAX_COUNT :: 1<<24
// What a Default track of each property holds.
STREAM_DEFAULTS :: [Property]math.Vec4{.Position={},.Rotation={0,0,0,1},.Scale={1,1,1,0},.Float={},.Vector={}}
stream_default :: #force_inline proc "contextless" (property:Property) -> math.Vec4 {
    #partial switch property {
    case .Rotation:return {0,0,0,1}
    case .Scale:return {1,1,1,0}
    }
    return {}
}

stream_components :: #force_inline proc "contextless" (property:Property) -> int {
    switch property {
    case .Float:return 1
    case .Vector:return 4
    case .Position,.Rotation,.Scale:return 3
    }
    return 0
}
stream_width :: #force_inline proc "contextless" (property:Property) -> Stream_Width {
    switch property {
    case .Float:return .One
    case .Vector:return .Four
    case .Position,.Rotation,.Scale:return .Three
    }
    return .One
}
stream_bits_valid :: #force_inline proc "contextless" (bits:int) -> bool {return bits==STREAM_RAW || bits>=0 && bits<=STREAM_MAX_BITS}

@(private) STREAM_HEADER :: size_of(Stream_Header)

@(private)
stream_load :: #force_inline proc "contextless" ($T:typeid,data:[]u8,at:int) -> T {
    return intrinsics.unaligned_load((^T)(raw_data(data[at:][:size_of(T)])))
}
@(private)
stream_code :: #force_inline proc "contextless" (data:[]u8,i:int) -> (kind:Stream_Kind,components:int) {
    code:=data[STREAM_HEADER+i>>1]>>(uint(i&1)*4)
    width:=int((code>>2)&3)
    return Stream_Kind(code&3),1 if width==0 else width+2 if width<3 else 0
}
@(private)
stream_constants :: #force_inline proc "contextless" (h:Stream_Header) -> int {return STREAM_HEADER+(int(h.tracks)+1)/2}
@(private)
stream_animated_floats :: #force_inline proc "contextless" (h:Stream_Header) -> int {return (int(h.table)-int(h.ranges))/8}

// The bytes of a stream whose clip has `tracks` (rows with a property and an encoding, the
// Sampled ones in the stream and the Raw ones Keys). ok is false unless the header, codes,
// values, segments and bit rates are consistent and finite and it fits in `data` with `padding`
// bytes after it.
stream_check :: proc "contextless" (data:[]u8,tracks:[]$T,padding:=STREAM_PADDING) -> (bytes:int,ok:bool) {
    if len(data)<STREAM_HEADER || padding<0 {return}
    h:=stream_load(Stream_Header,data,0)
    bytes=int(h.bytes)
    if bytes<STREAM_HEADER || bytes>len(data)-padding || h.count==0 || h.count>STREAM_MAX_COUNT || !anim_finite(h.duration) || h.duration<0 || int(h.tracks)!=len(tracks) || stream_constants(h)>bytes {return}
    if h.count==1 {
        if h.segments!=0 || h.animated!=0 {return}
    } else {
        span:=h.rate*h.duration
        if !(h.duration>0) || !anim_finite(h.rate) || !(span>f32(h.count)-2) || span>f32(h.count-1)+1e-3 || h.animated==0 || h.segments==0 || h.segments>h.count {return}
    }
    constants,animated,constant_floats,animated_floats:=0,0,0,0
    for track,i in tracks {
        kind,components:=stream_code(data,i)
        if (kind==.Keys)!=(track.encoding==.Raw) || track.encoding>.Sampled || track.property>max(Property) {return}
        if kind!=.Keys && components!=stream_components(track.property) {return}
        if kind==.Constant {constants+=1;constant_floats+=components} else if kind==.Animated {animated+=1;animated_floats+=components}
    }
    if constants!=int(h.constants) || animated!=int(h.animated) || int(h.ranges)!=stream_constants(h)+4*constant_floats || int(h.table)!=int(h.ranges)+8*animated_floats {return}
    end:=int(h.table)+int(h.segments)*size_of(Stream_Segment)
    if end>bytes {return}
    at:=stream_constants(h)
    for track,i in tracks {
        kind,components:=stream_code(data,i)
        if kind!=.Constant {continue}
        squares:f32
        for c in 0..<components {
            v:=stream_load(f32,data,at+4*c)
            if !anim_finite(v) {return}
            squares+=v*v
        }
        if track.property==.Rotation && squares>1.0001 {return}
        at+=4*components
    }
    for i in 0..<animated_floats {
        minimum,extent:=stream_load(f32,data,int(h.ranges)+4*i),stream_load(f32,data,int(h.ranges)+4*(animated_floats+i))
        if !anim_finite(minimum) || !anim_finite(extent) || extent<0 || !anim_finite(minimum+extent) {return}
    }
    ranged:=h.segments>1
    for s in 0..<int(h.segments) {
        segment:=stream_load(Stream_Segment,data,int(h.table)+s*size_of(Stream_Segment))
        next:=stream_load(Stream_Segment,data,int(h.table)+(s+1)*size_of(Stream_Segment)).start if s+1<int(h.segments) else h.count
        if s==0 && segment.start!=0 || next<=segment.start || next>h.count || int(segment.bits)!=end || int(h.animated)>bytes-end {return}
        ranges:=end+int(h.animated)
        stride,a:=0,0
        for i in 0..<len(tracks) {
            kind,components:=stream_code(data,i)
            if kind!=.Animated {continue}
            bits:=int(data[end+a]);a+=1
            if !stream_bits_valid(bits) || bits==0 && !ranged {return}
            stride+=bits*components
            if bits==STREAM_RAW || !ranged {continue}
            if 2*components>bytes-ranges {return}
            if bits>0 {for c in 0..<components {if int(data[ranges+2*c])+int(data[ranges+2*c+1])>255 {return}}}
            ranges+=2*components
        }
        size:=(int(next-segment.start)*stride+7)/8
        if int(segment.samples)!=ranges || int(segment.stride)!=stride || size>bytes-ranges {return}
        end=ranges+size
    }
    if end!=bytes {return}
    return bytes,true
}

@(private,rodata) stream_inverse:=[STREAM_MAX_BITS+1]f32{0,1.0/1,1.0/3,1.0/7,1.0/15,1.0/31,1.0/63,1.0/127,1.0/255,1.0/511,1.0/1023,1.0/2047,1.0/4095,1.0/8191,1.0/16383,1.0/32767,1.0/65535,1.0/131071,1.0/262143,1.0/524287,1.0/1048575,1.0/2097151,1.0/4194303,1.0/8388607}
@(private) Stream_F4 :: #simd[4]f32

// The components of a sample from their quantized values: a fraction of the segment's range,
// which is a fraction of the track's range; the same arithmetic in library_compress and here.
@(private)
stream_dequantize :: #force_inline proc "contextless" (minimum,extent:math.Vec4,low,span:[4]u8,bits:int,q:[4]u32,ranged:bool) -> math.Vec4 {
    l:=Stream_F4{f32(low[0]),f32(low[1]),f32(low[2]),f32(low[3])}
    w:=Stream_F4{f32(span[0]),f32(span[1]),f32(span[2]),f32(span[3])}
    part:Stream_F4
    if bits==0 {part=(l+w*Stream_F4(256))*Stream_F4(1.0/65535)} else {
        part=Stream_F4{f32(q[0]),f32(q[1]),f32(q[2]),f32(q[3])}*Stream_F4(stream_inverse[bits])
        if ranged {part=(l+w*part)*Stream_F4(1.0/255)}
    }
    return transmute(math.Vec4)(transmute(Stream_F4)minimum+transmute(Stream_F4)extent*part)
}
// 64 bits of the stream from a bit on, or 0 past its padding.
@(private)
stream_word :: #force_inline proc "contextless" (data:[]u8,position:int) -> u64 {
    at:=position>>3
    if at<0 || at>len(data)-8 {return 0}
    return intrinsics.unaligned_load((^u64)(uintptr(raw_data(data))+uintptr(at)))>>uint(position&7)
}
// Four floats from a byte, the ones past `components` zero, or zero past the padding.
@(private)
stream_floats :: #force_inline proc "contextless" (data:[]u8,at,components:int) -> (v:math.Vec4) {
    if at<0 || at>len(data)-16 {return}
    v=intrinsics.unaligned_load((^math.Vec4)(uintptr(raw_data(data))+uintptr(at)))
    if components<4 {v.w=0}
    if components<2 {v.y,v.z=0,0}
    return
}

// x, y and z of a unit quaternion with w>=0, with its w again.
@(private)
stream_quat :: #force_inline proc "contextless" (v:math.Vec4) -> math.Vec4 {return {v.x,v.y,v.z,intrinsics.sqrt(max(1-v.x*v.x-v.y*v.y-v.z*v.z,0))}}
@(private)
stream_finish :: #force_inline proc "contextless" (v:math.Vec4,property:Property) -> math.Vec4 {return stream_quat(v) if property==.Rotation else v}

// Between two decoded samples. A rotation follows the short arc at constant speed, as slerp does:
// normalized lerp at an amount moved by the series, in 1-cos of the half angle and to its third
// term, of the amount at which it is slerp (under 1e-7 radians up to 50 degrees between samples);
// past STREAM_SLERP_COS, slerp itself. The terms of the series that depend only on the amount are
// those of every track of a pose.
@(private)
Stream_Terms :: struct {amount,cubic,second,third:f32}
@(private)
stream_terms :: #force_inline proc "contextless" (amount:f32) -> Stream_Terms {
    u:=(amount-.5)*(amount-.5)
    return {amount,amount*(amount-1)*(amount-.5),2.0/15+8.0/15*u,4.0/105+u*(62.0/315+136.0/315*u)}
}
@(private)
stream_rotation_mix :: #force_inline proc "contextless" (a,b:math.Vec4,terms:Stream_Terms) -> math.Vec4 {
    d:=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w
    b:=b
    if d<0 {b=-b;d=-d}
    if d<STREAM_SLERP_COS {return stream_slerp(a,b,d,terms.amount)}
    x:=1-d
    x2:=x*x
    t:=terms.amount+terms.cubic*(x*(2.0/3)+x2*terms.second+x2*x*terms.third)
    q:=a+(b-a)*t
    length:=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w
    return q*(1/intrinsics.sqrt(length)) if length>0 else {0,0,0,1}
}
@(private)
stream_mix :: #force_inline proc "contextless" (a,b:math.Vec4,amount:f32,property:Property) -> math.Vec4 {
    if property!=.Rotation {return a+(b-a)*amount}
    return stream_rotation_mix(a,b,stream_terms(amount))
}

// The cosine of half the largest rotation between two samples that stream_mix follows by its series.
@(private) STREAM_SLERP_COS :: .9
@(private)
stream_slerp :: proc "contextless" (a,b:math.Vec4,d,amount:f32) -> math.Vec4 {
    angle:=cmath.acos(d)
    q:=a*cmath.sin((1-amount)*angle)+b*cmath.sin(amount*angle)
    length:=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w
    return q*(1/intrinsics.sqrt(length)) if length>0 else a
}

// The sample a time falls after and how far toward the next, as every sampled track reads it.
@(private)
stream_position :: #force_inline proc "contextless" (h:Stream_Header,time:f32) -> (index:int,amount:f32) {
    last:=int(h.count)-1
    if last<=0 {return 0,0}
    position:=time*h.rate
    if !(position>0) {position=0}
    end:=h.duration*h.rate
    if position>=end || position>=f32(last) {return last-1,1}
    index=min(int(position),last-1)
    amount=position-f32(index)
    if index==last-1 {amount=min(amount/(end-f32(index)),1)}
    return
}

// Where one side of an interpolation reads its segment: its bit rates, the next range bytes and
// the bit of the next component of its sample.
@(private)
Stream_Cursor :: struct {bits,ranges,offset:int,ranged:bool}

@(private)
stream_cursor :: #force_inline proc "contextless" (data:[]u8,h:Stream_Header,sample:int) -> (c:Stream_Cursor,ok:bool) {
    low,high:=0,int(h.segments)-1
    for low<high {
        middle:=(low+high+1)>>1
        if int(stream_load(u32,data,int(h.table)+middle*size_of(Stream_Segment)))<=sample {low=middle} else {high=middle-1}
    }
    segment:=stream_load(Stream_Segment,data,int(h.table)+low*size_of(Stream_Segment))
    if int(segment.bits)>int(h.bytes)-int(h.animated) || int(segment.start)>sample {return}
    c.bits=int(segment.bits)
    c.ranges=c.bits+int(h.animated)
    c.offset=int(segment.samples)*8+(sample-int(segment.start))*int(segment.stride)
    c.ranged=h.segments>1
    return c,true
}

// The next Animated track's components at one side of the interpolation, moving past them.
@(private)
stream_unpack :: #force_inline proc "contextless" (data:[]u8,c:^Stream_Cursor,a,components:int,minimum,extent:math.Vec4) -> (value:math.Vec4,ok:bool) {
    at:=c.bits+a
    if at<0 || at>=len(data) {return}
    bits:=int(data[at])
    if bits==STREAM_RAW {
        for i in 0..<components {value[i]=transmute(f32)u32(stream_word(data,c.offset+32*i))}
        c.offset+=32*components
        return value,true
    }
    if bits>STREAM_MAX_BITS {return}
    low,span:[4]u8
    if c.ranged {
        if c.ranges<0 || c.ranges>len(data)-2*components {return}
        for i in 0..<components {low[i],span[i]=data[c.ranges+2*i],data[c.ranges+2*i+1]}
        c.ranges+=2*components
    } else if bits==0 {return}
    q:[4]u32
    if bits>0 {
        mask:=u64(1)<<uint(bits)-1
        if bits*components<=57 {
            word:=stream_word(data,c.offset)
            for i in 0..<components {q[i]=u32(word&mask);word>>=uint(bits)}
        } else {
            for i in 0..<components {q[i]=u32(stream_word(data,c.offset+bits*i)&mask)}
        }
        c.offset+=bits*components
    }
    return stream_dequantize(minimum,extent,low,span,bits,q,c.ranged),true
}
// stream_unpack of a track of three components, in scalars: the arithmetic of stream_dequantize.
@(private)
stream_unpack3 :: #force_inline proc "contextless" (data:[]u8,c:^Stream_Cursor,a:int,minimum,extent:math.Vec3) -> (v:math.Vec3,ok:bool) {
    at:=c.bits+a
    if at<0 || at>=len(data) {return}
    bits:=uint(data[at])
    if bits==STREAM_RAW {
        v={transmute(f32)u32(stream_word(data,c.offset)),transmute(f32)u32(stream_word(data,c.offset+32)),transmute(f32)u32(stream_word(data,c.offset+64))}
        c.offset+=96
        return v,true
    }
    if bits>STREAM_MAX_BITS {return}
    lx,ly,lz,sx,sy,sz:f32
    if c.ranged {
        if c.ranges<0 || c.ranges>len(data)-8 {return}
        r:=intrinsics.unaligned_load((^u64)(uintptr(raw_data(data))+uintptr(c.ranges)))
        lx,sx,ly,sy,lz,sz=f32(r&255),f32((r>>8)&255),f32((r>>16)&255),f32((r>>24)&255),f32((r>>32)&255),f32((r>>40)&255)
        c.ranges+=6
    } else if bits==0 {return}
    px,py,pz:f32
    if bits==0 {
        px,py,pz=(lx+sx*256)*(1.0/65535),(ly+sy*256)*(1.0/65535),(lz+sz*256)*(1.0/65535)
    } else {
        mask:=u64(1)<<bits-1
        qx,qy,qz:u64
        if bits*3<=57 {
            word:=stream_word(data,c.offset)
            qx,qy,qz=word&mask,(word>>bits)&mask,(word>>(2*bits))&mask
        } else {
            qx,qy,qz=stream_word(data,c.offset)&mask,stream_word(data,c.offset+int(bits))&mask,stream_word(data,c.offset+2*int(bits))&mask
        }
        c.offset+=3*int(bits)
        i:=stream_inverse[bits]
        px,py,pz=f32(qx)*i,f32(qy)*i,f32(qz)*i
        if c.ranged {px,py,pz=(lx+sx*px)*(1.0/255),(ly+sy*py)*(1.0/255),(lz+sz*pz)*(1.0/255)}
    }
    return {minimum.x+extent.x*px,minimum.y+extent.y*py,minimum.z+extent.z*pz},true
}

// Past the next Animated track at one side without reading it.
@(private)
stream_skip :: #force_inline proc "contextless" (data:[]u8,c:^Stream_Cursor,a,components:int) {
    bits:=int(data[c.bits+a])
    c.offset+=bits*components
    if bits!=STREAM_RAW && c.ranged {c.ranges+=2*components}
}

// Reads the tracks of a clip at one time in one pass, one after another in the clip's order. It
// decodes STREAM_CHUNK tracks ahead: their rotations four at a time.
Clip_Reader :: struct {
    data:[]u8, // the clip's stream, nil when it has none
    h:Stream_Header,
    a,b:Stream_Cursor,
    amount,time:f32,
    terms:Stream_Terms,
    constant_at,range_at,animated,next:int,
    tracks:[]Track, // the clip's
    index,start:int, // the next track clip_reader_next gives and the first one in chunk
    chunk:[STREAM_CHUNK]math.Vec4,
    failed:bool,
}
STREAM_CHUNK :: 32

// Starts a reader on a stream without clearing its chunk, which it fills before reading it.
@(private)
stream_reader :: proc "contextless" (r:^Clip_Reader,data:[]u8,time:f32) {
    r.data,r.h,r.a,r.b,r.amount,r.time,r.terms={},{},{},{},0,time,{}
    r.constant_at,r.range_at,r.animated,r.next,r.tracks,r.index,r.start,r.failed=0,0,0,0,nil,0,0,false
    if len(data)<STREAM_HEADER {r.failed=true;return}
    h:=stream_load(Stream_Header,data,0)
    bytes:=int(h.bytes)
    if bytes>len(data)-STREAM_PADDING || bytes<stream_constants(h) || int(h.ranges)<stream_constants(h) || int(h.table)<int(h.ranges) || int(h.table)+int(h.segments)*size_of(Stream_Segment)>bytes {r.failed=true;return}
    r.data,r.h=data,h
    r.constant_at,r.range_at=stream_constants(h),int(h.ranges)
    if h.animated>0 {
        if h.segments==0 || h.count<2 {r.failed=true;return}
        index:int
        index,r.amount=stream_position(h,time)
        r.terms=stream_terms(r.amount)
        ok_a,ok_b:bool
        r.a,ok_a=stream_cursor(data,h,index)
        r.b,ok_b=stream_cursor(data,h,index+1)
        r.failed=!ok_a || !ok_b
    }
}

// The value of the next track of the stream, of `property`, decoded alone.
@(private)
stream_next :: proc "contextless" (r:^Clip_Reader,property:Property) -> (value:math.Vec4) {
    if r.failed || r.next>=int(r.h.tracks) {r.failed=true;return}
    data:=r.data
    kind,components:=stream_code(data,r.next)
    r.next+=1
    switch kind {
    case .Keys:
    case .Default:value=stream_default(property)
    case .Constant:
        if components!=stream_components(property) {r.failed=true;return}
        value=stream_finish(stream_floats(data,r.constant_at,components),property)
        r.constant_at+=4*components
    case .Animated:
        if components!=stream_components(property) {r.failed=true;return}
        a:=r.animated
        r.animated+=1
        minimum,extent:=stream_floats(data,r.range_at,components),stream_floats(data,r.range_at+4*stream_animated_floats(r.h),components)
        r.range_at+=4*components
        if components==3 {
            first,ok_a:=stream_unpack3(data,&r.a,a,minimum.xyz,extent.xyz)
            second,ok_b:=stream_unpack3(data,&r.b,a,minimum.xyz,extent.xyz)
            if !ok_a || !ok_b {r.failed=true;return {}}
            if property!=.Rotation {
                value.xyz=first+(second-first)*r.amount
                return
            }
            return stream_rotation_mix(stream_quat({first.x,first.y,first.z,0}),stream_quat({second.x,second.y,second.z,0}),r.terms)
        }
        first,ok_a:=stream_unpack(data,&r.a,a,components,minimum,extent)
        second,ok_b:=stream_unpack(data,&r.b,a,components,minimum,extent)
        if !ok_a || !ok_b {r.failed=true;return {}}
        value=stream_mix(stream_finish(first,property),stream_finish(second,property),r.amount,property)
    }
    return
}

// The stream of a clip with its padding, or nil when it has none or it lies outside the library.
@(private)
clip_stream :: #force_inline proc "contextless" (lib:^Library,clip:Clip_Data) -> []u8 {
    if clip.stream_bytes==0 || lib.stream_bytes<0 || lib.stream_bytes>len(lib.streams)-STREAM_PADDING || int(clip.stream)>lib.stream_bytes || int(clip.stream_bytes)>lib.stream_bytes-int(clip.stream) {return nil}
    return lib.streams[clip.stream:][:int(clip.stream_bytes)+STREAM_PADDING]
}

// Starts a reader of every track of a clip at a time: clip_reader_next gives them in the clip's
// order. A reader is declared without zeroing (`r:Clip_Reader=---`): this sets what it reads.
clip_reader :: proc "contextless" (r:^Clip_Reader,lib:^Library,clip:Clip,time:f32) {
    stream_reader(r,nil,time)
    r.failed=false
    if !clip_valid(lib,clip) {r.failed=true;return}
    data:=lib.clips[clip-1]
    if data.stream_bytes==0 {return}
    stream:=clip_stream(lib,data)
    tracks:=clip_tracks(lib,clip)
    if stream==nil || int(data.first_track)>lib.track_count || int(data.track_count)>lib.track_count-int(data.first_track) {r.failed=true;return}
    stream_reader(r,stream,time)
    if int(r.h.tracks)!=len(tracks) {r.failed=true}
    r.tracks=tracks
}
// The value of the next track of the clip, which must be `track`, as clip_evaluate gives it.
clip_reader_next :: #force_inline proc "contextless" (r:^Clip_Reader,lib:^Library,track:Track) -> math.Vec4 {
    if r.data==nil || track.encoding==.Raw {
        r.index+=1
        // A clip over part of another's tracks reads them from that clip's stream.
        if track.encoding==.Sampled {return stream_evaluate(lib,track,r.time)}
        return track_evaluate(track_keys(lib,track),track.property,r.time)
    }
    for r.index>=r.next && !r.failed {stream_chunk(r)}
    at:=r.index-r.start
    r.index+=1
    return r.chunk[at] if !r.failed && at>=0 && at<STREAM_CHUNK else {}
}

// Decodes the next STREAM_CHUNK tracks of the clip into r.chunk: what holds still and positions and
// scales at once, rotations gathered and then mixed four at a time.
@(private)
stream_chunk :: proc "contextless" (r:^Clip_Reader) {
    data:=r.data
    r.start=r.next
    end:=min(r.next+STREAM_CHUNK,len(r.tracks))
    if r.next>=end {r.failed=true;return}
    a,b:=r.a,r.b
    floats:=stream_animated_floats(r.h)
    constant_at,range_at,animated_at,amount,start:=r.constant_at,r.range_at,r.animated,r.amount,r.start
    tracks:=r.tracks
    chunk:=&r.chunk
    // The rotations to mix: their samples at both sides and their place in the chunk.
    ax,ay,az,bx,by,bz:[STREAM_CHUNK+3]f32=---,---,---,---,---,---
    slots:[STREAM_CHUNK]int=---
    rotations:=0
    for i in r.next..<end {
        track:=tracks[i]
        kind,components:=stream_code(data,i)
        value:math.Vec4
        switch kind {
        case .Keys:
        case .Default:value=stream_default(track.property)
        case .Constant:
            value=stream_finish(stream_floats(data,constant_at,components),track.property)
            constant_at+=4*components
        case .Animated:
            minimum,extent:=stream_floats(data,range_at,components),stream_floats(data,range_at+4*floats,components)
            range_at+=4*components
            animated:=animated_at
            animated_at+=1
            if components==3 {
                first,ok_a:=stream_unpack3(data,&a,animated,minimum.xyz,extent.xyz)
                second,ok_b:=stream_unpack3(data,&b,animated,minimum.xyz,extent.xyz)
                if !ok_a || !ok_b {r.failed=true;return}
                if track.property==.Rotation {
                    ax[rotations],ay[rotations],az[rotations]=first.x,first.y,first.z
                    bx[rotations],by[rotations],bz[rotations]=second.x,second.y,second.z
                    slots[rotations]=i-start
                    rotations+=1
                    continue
                }
                value.xyz=first+(second-first)*amount
            } else {
                first,ok_a:=stream_unpack(data,&a,animated,components,minimum,extent)
                second,ok_b:=stream_unpack(data,&b,animated,components,minimum,extent)
                if !ok_a || !ok_b {r.failed=true;return}
                value=stream_mix(stream_finish(first,track.property),stream_finish(second,track.property),amount,track.property)
            }
        }
        chunk[i-start]=value
    }
    r.a,r.b=a,b
    r.next,r.constant_at,r.range_at,r.animated=end,constant_at,range_at,animated_at
    for k in rotations..<rotations+3 {ax[k],ay[k],az[k],bx[k],by[k],bz[k]=0,0,0,0,0,0}
    // The arithmetic of stream_quat and stream_rotation_mix, lane by lane.
    F :: Stream_F4
    terms:=r.terms
    for g:=0;g<rotations;g+=4 {
        x0,y0,z0:=F{ax[g],ax[g+1],ax[g+2],ax[g+3]},F{ay[g],ay[g+1],ay[g+2],ay[g+3]},F{az[g],az[g+1],az[g+2],az[g+3]}
        x1,y1,z1:=F{bx[g],bx[g+1],bx[g+2],bx[g+3]},F{by[g],by[g+1],by[g+2],by[g+3]},F{bz[g],bz[g+1],bz[g+2],bz[g+3]}
        w0:=simd.sqrt(simd.max(F(1)-x0*x0-y0*y0-z0*z0,F(0)))
        w1:=simd.sqrt(simd.max(F(1)-x1*x1-y1*y1-z1*z1,F(0)))
        d:=x0*x1+y0*y1+z0*z1+w0*w1
        flip:=simd.lanes_lt(d,F(0))
        x1,y1,z1,w1=simd.select(flip,-x1,x1),simd.select(flip,-y1,y1),simd.select(flip,-z1,z1),simd.select(flip,-w1,w1)
        d=simd.abs(d)
        x:=F(1)-d
        x2:=x*x
        t:=F(terms.amount)+F(terms.cubic)*(x*F(2.0/3)+x2*F(terms.second)+x2*x*F(terms.third))
        qx,qy,qz,qw:=x0+(x1-x0)*t,y0+(y1-y0)*t,z0+(z1-z0)*t,w0+(w1-w0)*t
        length:=qx*qx+qy*qy+qz*qz+qw*qw
        positive:=simd.lanes_gt(length,F(0))
        inverse:=F(1)/simd.sqrt(simd.select(positive,length,F(1)))
        qx,qy,qz,qw=simd.select(positive,qx*inverse,F(0)),simd.select(positive,qy*inverse,F(0)),simd.select(positive,qz*inverse,F(0)),simd.select(positive,qw*inverse,F(1))
        lx,ly,lz,lw,ld:=simd.to_array(qx),simd.to_array(qy),simd.to_array(qz),simd.to_array(qw),simd.to_array(d)
        for lane in 0..<min(4,rotations-g) {
            k:=g+lane
            r.chunk[slots[k]]=ld[lane]<STREAM_SLERP_COS ? stream_rotation_mix(stream_quat({ax[k],ay[k],az[k],0}),stream_quat({bx[k],by[k],bz[k],0}),terms) : math.Vec4{lx[lane],ly[lane],lz[lane],lw[lane]}
        }
    }
}

// Every track of a clip at a time into out, in the clip's order. False when out is shorter than
// the clip's tracks or its stream does not match them.
clip_sample :: proc "contextless" (lib:^Library,clip:Clip,time:f32,out:[]math.Vec4) -> bool {
    tracks:=clip_tracks(lib,clip)
    if len(out)<len(tracks) || !clip_valid(lib,clip) {return false}
    r:Clip_Reader=---
    clip_reader(&r,lib,clip,time)
    for track,i in tracks {out[i]=clip_reader_next(&r,lib,track)}
    return !r.failed
}

// The value of one sampled track at a time, as clip_evaluate gives it: `first` is the byte of
// lib.streams its clip's stream starts at and `count` its place among the clip's tracks.
stream_evaluate :: proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {
    if lib.stream_bytes<0 || lib.stream_bytes>len(lib.streams)-STREAM_PADDING || int(track.first)>lib.stream_bytes-STREAM_HEADER {return {}}
    data:=lib.streams[track.first:]
    h:=stream_load(Stream_Header,data,0)
    if int(h.bytes)>lib.stream_bytes-int(track.first) || int(track.count)>=int(h.tracks) || stream_constants(h)>int(h.bytes) {return {}}
    data=data[:int(h.bytes)+STREAM_PADDING]
    target:=int(track.count)
    kind,components:=stream_code(data,target)
    if kind==.Default {return stream_default(track.property)}
    if kind==.Keys || components!=stream_components(track.property) {return {}}
    // The others' properties only set how wide they are, which their codes say.
    r:Clip_Reader=---
    stream_reader(&r,data,time)
    if r.failed {return {}}
    for i in 0..<target {
        kind_i,components_i:=stream_code(data,i)
        switch kind_i {
        case .Constant:r.constant_at+=4*components_i
        case .Animated:
            if h.animated>0 {stream_skip(data,&r.a,r.animated,components_i);stream_skip(data,&r.b,r.animated,components_i)}
            r.range_at+=4*components_i;r.animated+=1
        case .Default,.Keys:
        }
    }
    r.next=target
    value:=stream_next(&r,track.property)
    return {} if r.failed else value
}
