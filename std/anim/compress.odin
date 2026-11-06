package mirai_anim

import "base:runtime"
import cmath "core:math"
import "core:math/linalg"
import "core:slice"
import math "mirai:std/math"

// How far library_compress may move what a clip animates. The error of a transform is measured
// on the skeleton the clip plays on: two points `shell` away from each bone, in the space of the
// entity that plays it, so that a rotation near the root counts for everything below it.
Compress_Config :: struct {
    precision:f32, // the farthest a shell point may move, in scene units
    shell:f32,
    float_precision,vector_precision:f32, // per component of Float and Vector tracks
}
COMPRESS_DEFAULT :: Compress_Config{precision=.0001,shell=.03,float_precision=.0001,vector_precision=.0001}
// The sample rate of a clip whose keys have no interval in common.
COMPRESS_RATE :: 30
Compress_Error :: enum u8 {None,Invalid,Out_Of_Memory,Prepared}
Compress_Stats :: struct {
    raw_bytes,resident_bytes:int,
    raw_tracks,constant_tracks,sampled_tracks:int,
    // The farthest a shell point moved and the largest change of a curve component, measured at
    // the samples and at three points between each two.
    error,curve_error:f32,
}

// Points measured per sample interval: the samples and those between them.
@(private) COMPRESS_SUBDIVISIONS :: 4
@(private) COMPRESS_BITS :: [?]u8{0,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,SAMPLED_RAW}
@(private) Compress_Kind :: enum u8 {Raw,Constant,Sampled}
@(private) Compress_Plan :: struct {kind:Compress_Kind,track:Sampled_Track,bytes:int}
@(private) Compress_Bone :: struct {
    target:u64,
    slot:u8,
    parent:int,
    tracks:[3]int, // its Position, Rotation and Scale tracks in the clip, -1 for none
    rest:math.Transform, // what it holds where it has no track
    depth,height:int,
    reach,scale:f32,
}
// What one clip needs while its tracks are compressed. Per track and fine sample (the samples
// and COMPRESS_SUBDIVISIONS-1 points between each two) the exact and the decoded value; per bone
// and fine sample its exact and decoded transform in the space of the entity.
@(private) Compress_Work :: struct {
    first,count,samples,fine,segments:int,
    skeleton:Skeleton,
    rate,duration:f32,
    exact,decoded:[]math.Vec4,
    world,moved:[]math.Transform,
    bones:[]Compress_Bone,
    bone_count:int,
    bone_of:[]int,
    kind:[]Compress_Kind,
    minimum,extent:[]math.Vec4,
    gain:[]f32, // how far a component error moves a shell point
    bits,low,span:[]u8, // bits per track and segment; low and span per track, segment and component
    bump:[]bool,
    order:[]int,             // while sorting the bones: their order and where each went
    sorted:[]Compress_Bone,
    allocator:runtime.Allocator,
}

library_resident_bytes :: proc "contextless" (lib:^Library) -> int {
    if lib==nil {return 0}
    return len(lib.keys)*size_of(Keyframe)+len(lib.sampled)*size_of(Sampled_Track)+len(lib.segments)*size_of(u32)+len(lib.samples)+len(lib.tracks)*size_of(Track)+len(lib.clips)*size_of(Clip_Data)+len(lib.markers)*size_of(Marker)
}

@(private)
compress_config_valid :: proc "contextless" (config:Compress_Config) -> bool {
    for value in ([4]f32{config.precision,config.shell,config.float_precision,config.vector_precision}) {if !anim_finite(value) || value<0 {return false}}
    return true
}
@(private)
compress_keys_valid :: proc "contextless" (keys:[]Keyframe,property:Property) -> bool {
    if property>.Vector {return false}
    for key,i in keys {
        if !anim_finite(key.time) || key.time<0 || i>0 && key.time<keys[i-1].time || key.interpolation>max(Interpolation) || key.ease>max(math.Ease) {return false}
        for v in key.value {if !anim_finite(v) {return false}}
        if key.tangents {for v in key.in_slope {if !anim_finite(v) {return false}};for v in key.out_slope {if !anim_finite(v) {return false}}}
        if property==.Rotation && abs(key.value.x)+abs(key.value.y)+abs(key.value.z)+abs(key.value.w)<1e-8 {return false}
    }
    return true
}

// Transaction: the transform, Float and Vector tracks of every clip become sampled where that
// keeps them within `config` and takes fewer bytes; the rest keep their keys. `skeletons` gives
// for each clip of the library the skeleton it plays on, whose rest pose holds what the clip does
// not move; an empty or invalid one is none. A track whose target is no bone of it hangs from the
// track `parents` gives for it, of the bone above its target in the same clip, -1 for none;
// without both, every bone is measured alone. Failures leave the library as it was; after
// success it does not accept clip_add.
library_compress :: proc(lib:^Library,parents:[]i32=nil,skeletons:[]Skeleton=nil,config:=COMPRESS_DEFAULT) -> (stats:Compress_Stats,error:Compress_Error) {
    if lib==nil || lib.allocator.procedure==nil || !compress_config_valid(config) || lib.key_count<0 || lib.key_count>len(lib.keys) || lib.track_count<0 || lib.track_count>len(lib.tracks) || lib.clip_count<0 || lib.clip_count>len(lib.clips) || lib.marker_count<0 || lib.marker_count>len(lib.markers) {return {},.Invalid}
    if lib.prepared {return {},.Prepared}
    if parents!=nil && len(parents)!=lib.track_count {return {},.Invalid}
    for clip in lib.clips[:lib.clip_count] {
        if !anim_finite(clip.duration) || clip.duration<0 || int(clip.first_track)>lib.track_count || int(clip.track_count)>lib.track_count-int(clip.first_track) || int(clip.first_marker)>lib.marker_count || int(clip.marker_count)>lib.marker_count-int(clip.first_marker) {return {},.Invalid}
    }
    for track in lib.tracks[:lib.track_count] {
        if track.encoding!=.Raw {return {},.Invalid}
        keys:=track_keys(lib,track)
        if len(keys)!=int(track.count) || !compress_keys_valid(keys,track.property) {return {},.Invalid}
    }
    for parent in parents {if parent< -1 || int(parent)>=lib.track_count {return {},.Invalid}}
    allocator:=lib.allocator
    stats.raw_bytes=library_resident_bytes(lib)
    plans,e1:=make([]Compress_Plan,lib.track_count,allocator)
    done,e2:=make([]bool,lib.track_count,allocator)
    out:=make([dynamic]u8,allocator)
    defer {delete(plans,allocator);delete(done,allocator);delete(out)}
    if e1!=nil || e2!=nil {return stats,.Out_Of_Memory}
    for clip,c in lib.clips[:lib.clip_count] {
        if clip.track_count==0 || done[clip.first_track] {continue}
        for i in 0..<int(clip.track_count) {done[int(clip.first_track)+i]=true}
        skeleton:Skeleton
        if c<len(skeletons) && len(skeletons[c].parents)>0 && skeleton_validate(skeletons[c]) {skeleton=skeletons[c]}
        clip_error,curve_error,ok:=compress_clip(lib,clip,parents,skeleton,config,plans[clip.first_track:][:clip.track_count],&out)
        if !ok {return stats,.Out_Of_Memory}
        stats.error=max(stats.error,clip_error);stats.curve_error=max(stats.curve_error,curve_error)
    }
    raw_count,sampled_count,segment_count:=0,0,0
    for plan,i in plans {
        switch plan.kind {
        case .Raw:raw_count+=int(lib.tracks[i].count);stats.raw_tracks+=1
        case .Constant:sampled_count+=1;stats.constant_tracks+=1
        case .Sampled:sampled_count+=1;segment_count+=(int(plan.track.count)+SAMPLED_SEGMENT-1)/SAMPLED_SEGMENT;stats.sampled_tracks+=1
        }
    }
    keys,e3:=make([]Keyframe,raw_count,allocator)
    sampled,e4:=make([]Sampled_Track,sampled_count,allocator)
    segments,e5:=make([]u32,segment_count,allocator)
    samples,e6:=make([]u8,len(out)+SAMPLED_PADDING,allocator)
    if e3!=nil || e4!=nil || e5!=nil || e6!=nil {delete(keys,allocator);delete(sampled,allocator);delete(segments,allocator);delete(samples,allocator);return stats,.Out_Of_Memory}
    copy(samples,out[:])
    key_at,sampled_at,segment_at:=0,0,0
    for &track,i in lib.tracks[:lib.track_count] {
        plan:=plans[i]
        if plan.kind==.Raw {
            copy(keys[key_at:],track_keys(lib,track));track.first=u32(key_at);key_at+=int(track.count)
            continue
        }
        s:=plan.track;s.first_segment=u32(segment_at)
        _,count,_:=sampled_walk(s,track.property,samples,segments[segment_at:])
        segment_at+=count
        sampled[sampled_at]=s
        track={target=track.target,property=track.property,slot=track.slot,encoding=.Sampled,first=u32(sampled_at),count=1}
        sampled_at+=1
    }
    delete(lib.keys,allocator);delete(lib.sampled,allocator);delete(lib.segments,allocator);delete(lib.samples,allocator)
    lib.keys,lib.sampled,lib.segments,lib.samples=keys,sampled,segments,samples
    lib.key_count,lib.sampled_count,lib.segment_count,lib.sample_count=raw_count,sampled_count,segment_count,len(out)
    lib.prepared=true
    stats.resident_bytes=library_resident_bytes(lib)
    return stats,.None
}

// Plans the tracks of one clip and appends the segments of those that are sampled to `out`. A
// clip without memory to measure it keeps its keys; ok is false only when `out` cannot grow.
@(private)
compress_clip :: proc(lib:^Library,clip:Clip_Data,parents:[]i32,skeleton:Skeleton,config:Compress_Config,plans:[]Compress_Plan,out:^[dynamic]u8) -> (worst,curve_worst:f32,ok:bool) {
    tracks:=lib.tracks[clip.first_track:][:clip.track_count]
    w:=Compress_Work{first=int(clip.first_track),count=len(tracks),duration=clip.duration,skeleton=skeleton,allocator=lib.allocator}
    rate,rated:=compress_rate(lib,tracks,w.allocator)
    if !rated {return 0,0,true}
    // On the grid of the keys from 0; a duration between two samples makes the last interval shorter.
    w.samples=1
    if clip.duration>0 && rate>0 {w.samples=min(int(cmath.ceil(f64(clip.duration)*f64(rate)-1e-3))+1,SAMPLED_MAX_COUNT)}
    if w.samples>=SAMPLED_MAX_COUNT {return 0,0,true}
    if w.samples<2 {
        // Nothing moves over time: every track with keys is its value at 0.
        for track,i in tracks {
            if track.count==0 {plans[i]={kind=.Raw};continue}
            value:=compress_exact(lib,track,0)
            plans[i]={kind=.Constant,track={minimum=value,count=1,duration=clip.duration}}
        }
        return 0,0,true
    }
    w.rate=rate
    w.fine=COMPRESS_SUBDIVISIONS*(w.samples-1)+1
    w.segments=(w.samples+SAMPLED_SEGMENT-1)/SAMPLED_SEGMENT
    defer compress_work_free(&w)
    if !compress_work_init(&w) {return 0,0,true}
    for track,i in tracks {
        w.kind[i]=.Raw if track.count==0 else .Sampled
        for j in 0..<w.fine {w.exact[i*w.fine+j]=compress_exact(lib,track,compress_time(&w,j))}
    }
    compress_bones(&w,tracks,parents,config)
    for track,i in tracks {
        if w.kind[i]==.Raw {continue}
        compress_track_plan(&w,track,i,config)
    }
    // Raise the bit rate of what moves a point too far until nothing does or nothing can.
    for _ in 0..<4096 {if !compress_measure(&w,tracks,config) {break}}
    // A track takes its keys back when they cost fewer bytes than its samples.
    for track,i in tracks {
        if w.kind[i]!=.Sampled {continue}
        if compress_track_bytes(&w,track,i)>=int(track.count)*size_of(Keyframe) {w.kind[i]=.Raw}
    }
    worst,curve_worst=compress_measure_final(&w,tracks,config)
    for track,i in tracks {
        switch w.kind[i] {
        case .Raw:plans[i]={kind=.Raw}
        case .Constant:plans[i]={kind=.Constant,track={minimum=w.exact[i*w.fine],count=1,duration=clip.duration}}
        case .Sampled:
            bytes:=compress_track_bytes(&w,track,i)
            at:=len(out)
            if resize(out,at+bytes)!=nil {return}
            compress_encode(&w,track,i,out[at:][:bytes])
            plans[i]={kind=.Sampled,bytes=bytes,track={minimum=w.minimum[i],extent=w.extent[i],duration=clip.duration,rate=w.rate,count=u32(w.samples),data=u32(at)}}
        }
    }
    return worst,curve_worst,true
}

@(private)
compress_work_init :: proc(w:^Compress_Work) -> bool {
    a:=w.allocator
    e:[17]runtime.Allocator_Error
    bones:=w.count+len(w.skeleton.parents)
    w.exact,e[0]=make([]math.Vec4,w.count*w.fine,a)
    w.decoded,e[1]=make([]math.Vec4,w.count*w.fine,a)
    w.bones,e[2]=make([]Compress_Bone,bones,a)
    w.world,e[3]=make([]math.Transform,bones*w.fine,a)
    w.moved,e[4]=make([]math.Transform,bones*w.fine,a)
    w.order,e[15]=make([]int,2*bones,a)
    w.sorted,e[16]=make([]Compress_Bone,bones,a)
    w.bone_of,e[5]=make([]int,w.count,a)
    w.kind,e[6]=make([]Compress_Kind,w.count,a)
    w.minimum,e[7]=make([]math.Vec4,w.count,a)
    w.extent,e[8]=make([]math.Vec4,w.count,a)
    w.gain,e[9]=make([]f32,w.count,a)
    w.bits,e[11]=make([]u8,w.count*w.segments,a)
    w.low,e[12]=make([]u8,w.count*w.segments*4,a)
    w.span,e[13]=make([]u8,w.count*w.segments*4,a)
    w.bump,e[14]=make([]bool,w.count*w.segments,a)
    for value in e {if value!=nil {return false}}
    return true
}
@(private)
compress_work_free :: proc(w:^Compress_Work) {
    a:=w.allocator
    delete(w.exact,a);delete(w.decoded,a);delete(w.bones,a);delete(w.world,a);delete(w.moved,a);delete(w.bone_of,a);delete(w.kind,a)
    delete(w.order,a);delete(w.sorted,a)
    delete(w.minimum,a);delete(w.extent,a);delete(w.gain,a);delete(w.bits,a);delete(w.low,a);delete(w.span,a);delete(w.bump,a)
}

@(private)
compress_time :: #force_inline proc "contextless" (w:^Compress_Work,fine:int) -> f32 {
    k:=fine/COMPRESS_SUBDIVISIONS
    at:=min(f32(k)/w.rate,w.duration)
    if fine%COMPRESS_SUBDIVISIONS==0 {return at}
    next:=min(f32(k+1)/w.rate,w.duration)
    return at+(next-at)*(f32(fine%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS)
}
// The exact value of a raw track, a rotation as a unit quaternion with w>=0.
@(private)
compress_exact :: proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {
    value:=track_evaluate(track_keys(lib,track),track.property,time)
    if track.property==.Rotation {
        value=linalg.normalize0(value)
        if value.w<0 {value=-value}
    }
    return value
}

// The rate the keys of a clip were made at: the interval most of them share, else COMPRESS_RATE.
@(private)
compress_rate :: proc(lib:^Library,tracks:[]Track,allocator:runtime.Allocator) -> (rate:f32,ok:bool) {
    count:=0
    for track in tracks {count+=max(int(track.count)-1,0)}
    if count==0 {return 0,true}
    intervals,e:=make([]f32,count,allocator);if e!=nil {return}
    defer delete(intervals,allocator)
    at:=0
    for track in tracks {
        keys:=track_keys(lib,track)
        for i in 1..<len(keys) {if keys[i].time>keys[i-1].time {intervals[at]=keys[i].time-keys[i-1].time;at+=1}}
    }
    if at==0 {return 0,true}
    sorted:=intervals[:at]
    slice.sort(sorted)
    best,best_count,start:=f32(0),0,0
    for i in 1..=len(sorted) {
        if i<len(sorted) && sorted[i]-sorted[start]<=sorted[start]*1e-3 {continue}
        if i-start>best_count {best,best_count=sorted[(start+i-1)/2],i-start}
        start=i
    }
    if best_count*4<at || !(best>0) || 1/best>FRAMES_MAX_RATE {return COMPRESS_RATE,true}
    rate=1/best
    if whole:=cmath.round(rate);abs(rate-whole)<=whole*1e-4 {rate=whole}
    return rate,true
}

// The bones of the skeleton the clip plays on and those its other transform tracks move,
// parents first, with how far below each the skeleton reaches and the largest scale of each, from
// the exact samples. Outside a skeleton, a bone without a Position track sits at its parent.
@(private)
compress_bones :: proc(w:^Compress_Work,tracks:[]Track,parents:[]i32,config:Compress_Config) {
    for &bone in w.bone_of {bone=-1}
    for target,b in w.skeleton.names {
        w.bones[b]={target=target,parent=int(w.skeleton.parents[b]),tracks={-1,-1,-1},rest=w.skeleton.rest[b]}
    }
    w.bone_count=len(w.skeleton.names)
    for track,i in tracks {
        if track.property>.Scale || track.count==0 {continue}
        b:=-1
        for &bone,at in w.bones[:w.bone_count] {if bone.target==track.target && bone.slot==track.slot {b=at;break}}
        if b<0 {b=w.bone_count;w.bones[b]={target=track.target,slot=track.slot,parent=-1,tracks={-1,-1,-1},rest=math.TRANSFORM_IDENTITY};w.bone_count+=1}
        w.bones[b].tracks[track.property]=i
        w.bone_of[i]=b
    }
    bones:=w.bones[:w.bone_count]
    // A bone outside the skeleton hangs from the bone of the track `parents` names, in this clip.
    for &bone in bones[len(w.skeleton.names):] {
        if parents==nil {continue}
        parent:=int(parents[w.first+compress_bone_track(bone)])-w.first
        if parent>=0 && parent<w.count && w.bone_of[parent]>=0 {bone.parent=w.bone_of[parent]}
    }
    // Depths by walking up; a loop of parents leaves its bones without one.
    for &bone in bones {
        depth,at:=0,bone.parent
        for at>=0 && depth<=len(bones) {depth+=1;at=bones[at].parent}
        if depth>len(bones) {bone.parent=-1;depth=0}
        bone.depth=depth
    }
    // Parents first: a stable sort by depth, then parents and tracks follow their bones.
    order,moved_to:=w.order[:len(bones)],w.order[len(bones):][:len(bones)]
    for &o,i in order {o=i}
    for i in 1..<len(order) {
        at,j:=order[i],i
        for j>0 && bones[order[j-1]].depth>bones[at].depth {order[j]=order[j-1];j-=1}
        order[j]=at
    }
    sorted:=w.sorted[:len(bones)]
    for old,i in order {moved_to[old]=i;sorted[i]=bones[old]}
    for &bone in sorted {if bone.parent>=0 {bone.parent=moved_to[bone.parent]}}
    copy(bones,sorted)
    for &b in w.bone_of {if b>=0 {b=moved_to[b]}}
    compress_world(w,false)
    for &bone in bones {bone.height=1;bone.reach=config.shell}
    #reverse for &bone,b in bones {
        for j in 0..<w.fine {
            t:=w.world[b*w.fine+j]
            bone.scale=max(bone.scale,abs(t.scale.x),abs(t.scale.y),abs(t.scale.z))
            if bone.parent>=0 {
                parent:=&bones[bone.parent]
                parent.reach=max(parent.reach,linalg.length(t.position-w.world[bone.parent*w.fine+j].position)+bone.reach)
            }
        }
        if bone.parent>=0 {bones[bone.parent].height=max(bones[bone.parent].height,bone.height+1)}
    }
}
@(private)
compress_bone_track :: proc "contextless" (bone:Compress_Bone) -> int {
    for t in bone.tracks {if t>=0 {return t}}
    return -1
}

// The transforms of every bone at every fine sample, from the exact or the decoded values.
@(private)
compress_world :: proc "contextless" (w:^Compress_Work,decoded:bool) {
    values:=w.decoded if decoded else w.exact
    out:=w.moved if decoded else w.world
    for bone,b in w.bones[:w.bone_count] {
        for j in 0..<w.fine {
            local:=bone.rest
            if t:=bone.tracks[Property.Position];t>=0 {local.position=values[t*w.fine+j].xyz}
            if t:=bone.tracks[Property.Rotation];t>=0 {local.rotation=vec4_quat(values[t*w.fine+j])}
            if t:=bone.tracks[Property.Scale];t>=0 {local.scale=values[t*w.fine+j].xyz}
            out[b*w.fine+j]=local if bone.parent<0 else math.transform_compose(out[bone.parent*w.fine+j],local)
        }
    }
}

// Whether a track holds still, can be sampled at the clip's rate or keeps its keys, and its first
// bit rates: those its range allows within its share of the error.
@(private)
compress_track_plan :: proc(w:^Compress_Work,track:Track,i:int,config:Compress_Config) {
    exact:=w.exact[i*w.fine:][:w.fine]
    components:=sampled_components(track.property)
    precision:=config.float_precision if track.property==.Float else config.vector_precision
    gain:f32=1
    if b:=w.bone_of[i];b>=0 {
        bone:=w.bones[b]
        precision=config.precision
        switch track.property {
        case .Position:gain=w.bones[bone.parent].scale if bone.parent>=0 else 1
        case .Rotation:gain=2*bone.reach
        case .Scale:gain=bone.reach
        case .Float,.Vector:
        }
    }
    w.gain[i]=gain
    // Linear between the samples must follow the keys between them.
    for j in 0..<w.fine {
        if j%COMPRESS_SUBDIVISIONS==0 {continue}
        k:=j/COMPRESS_SUBDIVISIONS
        mixed:=sampled_mix(exact[k*COMPRESS_SUBDIVISIONS],exact[(k+1)*COMPRESS_SUBDIVISIONS],f32(j%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS,track.property)
        if compress_distance(mixed,exact[j],track.property)*gain>precision*.5 {w.kind[i]=.Raw;return}
    }
    still:=true
    for value in exact {if compress_distance(value,exact[0],track.property)*gain>precision*.25 {still=false;break}}
    if still {w.kind[i]=.Constant;return}
    low,high:=compress_stored(exact[0],track.property),compress_stored(exact[0],track.property)
    for j:=0;j<w.fine;j+=COMPRESS_SUBDIVISIONS {
        v:=compress_stored(exact[j],track.property)
        for c in 0..<components {low[c]=min(low[c],v[c]);high[c]=max(high[c],v[c])}
    }
    w.minimum[i],w.extent[i]=low,high-low
    for s in 0..<w.segments {
        seg_low,seg_high:=high,low
        for k in s*SAMPLED_SEGMENT..<min((s+1)*SAMPLED_SEGMENT,w.samples) {
            v:=compress_stored(exact[COMPRESS_SUBDIVISIONS*k],track.property)
            for c in 0..<components {seg_low[c]=min(seg_low[c],v[c]);seg_high[c]=max(seg_high[c],v[c])}
        }
        for c in 0..<components {
            at:=(i*w.segments+s)*4+c
            extent:=w.extent[i][c]
            if !(extent>0) {w.low[at],w.span[at]=0,0;continue}
            l:=clamp(cmath.floor((seg_low[c]-low[c])/extent*255),0,255)
            h:=clamp(cmath.ceil((seg_high[c]-low[c])/extent*255),l,255)
            w.low[at],w.span[at]=u8(l),u8(h-l)
        }
        bits:=COMPRESS_BITS
        w.bits[i*w.segments+s]=SAMPLED_RAW
        for candidate in bits {
            if compress_step(w,i,s,int(candidate),components)*gain<=precision*.5 {w.bits[i*w.segments+s]=candidate;break}
        }
    }
}
// What a track stores of a value: a rotation's x, y and z with w>=0.
@(private)
compress_stored :: #force_inline proc "contextless" (v:math.Vec4,property:Property) -> math.Vec4 {
    if property==.Rotation {return v if v.w>=0 else -v}
    return v
}
// The largest error quantization at `bits` can make on a component of a segment.
@(private)
compress_step :: proc "contextless" (w:^Compress_Work,i,s,bits,components:int) -> f32 {
    if bits==SAMPLED_RAW {return 0}
    worst:f32
    for c in 0..<components {
        span:=w.extent[i][c]*f32(w.span[(i*w.segments+s)*4+c])/255
        worst=max(worst,span if bits==0 else span/f32(u32(1)<<uint(bits)-1)*.5)
    }
    return worst
}
// How far apart two values are: the distance of positions and scales, the angle of rotations, the
// largest component of curves.
@(private)
compress_distance :: proc "contextless" (a,b:math.Vec4,property:Property) -> f32 {
    switch property {
    case .Position,.Scale:return linalg.length(a.xyz-b.xyz)
    case .Rotation:
        // The chord between unit quaternions is 2sin(angle/4): exact for small angles, where acos is not.
        chord:=linalg.length(a-b) if linalg.dot(a,b)>=0 else linalg.length(a+b)
        return 4*cmath.asin(min(chord*.5,1))
    case .Float:return abs(a.x-b.x)
    case .Vector:return max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z),abs(a.w-b.w))
    }
    return 0
}

@(private)
compress_quantize :: #force_inline proc "contextless" (value,minimum,extent:f32,low,span:u8,bits:int) -> u32 {
    if bits==0 || !(extent>0) || span==0 {return 0}
    t:=((value-minimum)/extent*255-f32(low))/f32(span)
    return u32(clamp(t,0,1)*f32(u32(1)<<uint(bits)-1)+.5)
}
// The value the runtime decodes for sample k of a track, as sampled_value does.
@(private)
compress_decode :: proc "contextless" (w:^Compress_Work,track:Track,i,k:int) -> math.Vec4 {
    exact:=w.exact[i*w.fine+COMPRESS_SUBDIVISIONS*k]
    if w.kind[i]!=.Sampled {return exact}
    components:=sampled_components(track.property)
    stored:=compress_stored(exact,track.property)
    s:=k/SAMPLED_SEGMENT
    bits:=int(w.bits[i*w.segments+s])
    value:math.Vec4
    for c in 0..<components {
        if bits==SAMPLED_RAW {value[c]=stored[c];continue}
        at:=(i*w.segments+s)*4+c
        q:=compress_quantize(stored[c],w.minimum[i][c],w.extent[i][c],w.low[at],w.span[at],bits)
        value[c]=w.minimum[i][c]+w.extent[i][c]*sampled_part(w.low[at],w.span[at],bits,q)
    }
    return sampled_finish(value,track.property)
}
@(private)
compress_decode_all :: proc "contextless" (w:^Compress_Work,tracks:[]Track) {
    for track,i in tracks {
        values:=w.decoded[i*w.fine:][:w.fine]
        if w.kind[i]!=.Sampled {
            copy(values,w.exact[i*w.fine:][:w.fine])
            if w.kind[i]==.Constant {for &value in values {value=w.exact[i*w.fine]}}
            continue
        }
        for k in 0..<w.samples {values[COMPRESS_SUBDIVISIONS*k]=compress_decode(w,track,i,k)}
        for j in 0..<w.fine {
            if j%COMPRESS_SUBDIVISIONS==0 {continue}
            k:=j/COMPRESS_SUBDIVISIONS
            values[j]=sampled_mix(values[k*COMPRESS_SUBDIVISIONS],values[(k+1)*COMPRESS_SUBDIVISIONS],f32(j%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS,track.property)
        }
    }
}
// How far the decoded pose moves the shell points of a bone at a fine sample. The points turn with
// the bone and its exact scale, so a bone scaled down by its parents is still measured in scene units.
@(private)
compress_bone_error :: #force_inline proc "contextless" (w:^Compress_Work,b,j:int,shell:f32) -> f32 {
    exact,decoded:=w.world[b*w.fine+j],w.moved[b*w.fine+j]
    ratio:math.Vec3=1
    for c in 0..<3 {if abs(exact.scale[c])>1e-12 {ratio[c]=decoded.scale[c]/exact.scale[c]}}
    worst:=linalg.length(exact.position-decoded.position)
    for point in ([2]math.Vec3{{shell,0,0},{0,shell,0}}) {
        a:=exact.position+math.quat_rotate(exact.rotation,point)
        b:=decoded.position+math.quat_rotate(decoded.rotation,point*ratio)
        worst=max(worst,linalg.length(a-b))
    }
    return worst
}
// Decodes, measures and raises one bit rate where a point moves too far: the rate of the track
// above it that contributes most in that segment. False when nothing moves too far or nothing
// can be raised.
@(private)
compress_measure :: proc(w:^Compress_Work,tracks:[]Track,config:Compress_Config) -> bool {
    compress_decode_all(w,tracks)
    compress_world(w,true)
    for &value in w.bump {value=false}
    over:=false
    for _,b in w.bones[:w.bone_count] {
        for j in 0..<w.fine {
            if compress_bone_error(w,b,j,config.shell)<=config.precision {continue}
            over=true
            k:=j/COMPRESS_SUBDIVISIONS
            for s in ([2]int{k/SAMPLED_SEGMENT,min(k+min(j%COMPRESS_SUBDIVISIONS,1),w.samples-1)/SAMPLED_SEGMENT}) {
                best,best_track:=f32(0),-1
                for at:=b;at>=0;at=w.bones[at].parent {
                    for t in w.bones[at].tracks {
                        if t<0 || w.kind[t]!=.Sampled {continue}
                        bits:=int(w.bits[t*w.segments+s])
                        if bits==SAMPLED_RAW {continue}
                        contribution:=compress_step(w,t,s,bits,3)*w.gain[t]
                        if contribution>=best {best,best_track=contribution,t}
                    }
                }
                if best_track>=0 {w.bump[best_track*w.segments+s]=true}
            }
        }
    }
    for track,i in tracks {
        if w.bone_of[i]>=0 || w.kind[i]!=.Sampled {continue}
        precision:=config.float_precision if track.property==.Float else config.vector_precision
        for j in 0..<w.fine {
            if compress_distance(w.decoded[i*w.fine+j],w.exact[i*w.fine+j],track.property)<=precision {continue}
            over=true
            k:=j/COMPRESS_SUBDIVISIONS
            w.bump[i*w.segments+k/SAMPLED_SEGMENT]=true
            w.bump[i*w.segments+min(k+min(j%COMPRESS_SUBDIVISIONS,1),w.samples-1)/SAMPLED_SEGMENT]=true
        }
    }
    if !over {return false}
    raised:=false
    bits:=COMPRESS_BITS
    for bump,at in w.bump {
        if !bump {continue}
        for candidate,c in bits[:len(bits)-1] {
            if candidate==w.bits[at] {w.bits[at]=bits[c+1];raised=true;break}
        }
    }
    return raised
}
@(private)
compress_measure_final :: proc(w:^Compress_Work,tracks:[]Track,config:Compress_Config) -> (worst,curve_worst:f32) {
    compress_decode_all(w,tracks)
    compress_world(w,true)
    for _,b in w.bones[:w.bone_count] {for j in 0..<w.fine {worst=max(worst,compress_bone_error(w,b,j,config.shell))}}
    for track,i in tracks {
        if w.bone_of[i]>=0 {continue}
        for j in 0..<w.fine {curve_worst=max(curve_worst,compress_distance(w.decoded[i*w.fine+j],w.exact[i*w.fine+j],track.property))}
    }
    return
}

@(private)
compress_track_bytes :: proc "contextless" (w:^Compress_Work,track:Track,i:int) -> int {
    components:=sampled_components(track.property)
    bytes:=0
    for s in 0..<w.segments {bytes+=sampled_segment_bytes(components,int(w.bits[i*w.segments+s]),min(SAMPLED_SEGMENT,w.samples-s*SAMPLED_SEGMENT))}
    return bytes
}
// Writes the segments of a sampled track as sampled_value reads them.
@(private)
compress_encode :: proc "contextless" (w:^Compress_Work,track:Track,i:int,out:[]u8) {
    components:=sampled_components(track.property)
    at:=0
    for s in 0..<w.segments {
        bits:=int(w.bits[i*w.segments+s])
        out[at]=u8(bits)
        for c in 0..<components {out[at+1+c],out[at+1+components+c]=w.low[(i*w.segments+s)*4+c],w.span[(i*w.segments+s)*4+c]}
        at+=1+2*components
        word:u64;used:uint
        for k in s*SAMPLED_SEGMENT..<min((s+1)*SAMPLED_SEGMENT,w.samples) {
            stored:=compress_stored(w.exact[i*w.fine+COMPRESS_SUBDIVISIONS*k],track.property)
            for c in 0..<components {
                q:u32
                if bits==SAMPLED_RAW {q=transmute(u32)stored[c]} else {
                    seg:=(i*w.segments+s)*4+c
                    q=compress_quantize(stored[c],w.minimum[i][c],w.extent[i][c],w.low[seg],w.span[seg],bits)
                }
                word|=u64(q)<<used;used+=uint(bits)
                for used>=8 {out[at]=u8(word);at+=1;word>>=8;used-=8}
            }
        }
        if used>0 {out[at]=u8(word);at+=1}
    }
}
