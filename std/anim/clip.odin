package mirai_anim

import "base:runtime"
import "core:slice"
import math "mirai:std/math"

// A moment of a clip that playback reports when it crosses it.
Marker :: struct {
    time:f32,
    id:u32,
}

// One property of one target over time. `target` is the name_hash of whatever
// the caller drives (a node, a bone, a material); `slot` tells apart several
// Float or Vector tracks of one target.
// A track is its keys or, when sampled.track.count>0, its samples.
Track_Desc :: struct {
    target:u64,
    property:Property,
    slot:u8,
    keys:[]Keyframe,
    sampled:Sampled_Desc,
}
Clip_Desc :: struct {
    name:u64,
    loop:Loop,
    tracks:[]Track_Desc,
    markers:[]Marker,
}

Track :: struct {
    target:u64,
    first,count:u32, // keys of the library; for a sampled track, its row of Library.sampled and 1
    property:Property,
    slot:u8,
    encoding:Key_Encoding,
}
Clip_Data :: struct {
    name:u64,
    loop:Loop,
    duration:f32,
    first_track,track_count:u32,
    first_marker,marker_count:u32,
}

// Handle of a clip of a library: its index plus one. Zero is none.
Clip :: distinct u32

// The clips of a game: immutable once added, shared by every player. Capacities
// are fixed at init; clip_add refuses what does not fit and says why.
Library :: struct {
    keys:[]Keyframe,
    sampled:[]Sampled_Track,
    segments:[]u32,
    samples:[]u8, // segments of the sampled tracks, with SAMPLED_PADDING bytes after the last
    tracks:[]Track,
    clips:[]Clip_Data,
    markers:[]Marker,
    key_count,track_count,clip_count,marker_count:int,
    sampled_count,segment_count,sample_count:int,
    prepared:bool,
    allocator:runtime.Allocator,
}
Library_Desc :: struct {
    max_keys,max_tracks,max_clips,max_markers:int,
    max_sampled,max_segments,max_samples:int, // sampled tracks added by clip_add, their segments and bytes
    allocator:runtime.Allocator, // context.allocator when unset
}

library_init :: proc(lib:^Library,desc:Library_Desc) -> bool {
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    lib^={allocator=allocator}
    if desc.max_keys<=0 || desc.max_tracks<=0 || desc.max_clips<=0 || desc.max_markers<0 || desc.max_sampled<0 || desc.max_segments<0 || desc.max_samples<0 {return false}
    e1,e2,e3,e4,e5,e6,e7:runtime.Allocator_Error
    lib.keys,e1=make([]Keyframe,desc.max_keys,allocator)
    lib.tracks,e2=make([]Track,desc.max_tracks,allocator)
    lib.clips,e3=make([]Clip_Data,desc.max_clips,allocator)
    lib.markers,e4=make([]Marker,desc.max_markers,allocator)
    if desc.max_sampled>0 {
        lib.sampled,e5=make([]Sampled_Track,desc.max_sampled,allocator)
        lib.segments,e6=make([]u32,desc.max_segments,allocator)
        lib.samples,e7=make([]u8,desc.max_samples+SAMPLED_PADDING,allocator)
    }
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil || e6!=nil || e7!=nil {library_destroy(lib);return false}
    return true
}
library_destroy :: proc(lib:^Library) {
    if lib.allocator.procedure==nil {lib^={};return}
    delete(lib.keys,lib.allocator);delete(lib.tracks,lib.allocator);delete(lib.clips,lib.allocator);delete(lib.markers,lib.allocator)
    delete(lib.sampled,lib.allocator);delete(lib.segments,lib.allocator);delete(lib.samples,lib.allocator)
    lib^={}
}

// Why clip_add refused a clip.
Clip_Error :: enum u8 {
    None,
    Prepared, // the library was prepared: it takes no more clips
    Unsorted, // the keys of a track are not sorted by time
    Full,     // the clip passes max_clips, max_tracks, max_keys, max_markers or the sampled capacities of the library
    Invalid,  // a sampled track whose header or bytes are not consistent
}

// Adds a clip, copying its keys and markers; markers are stored sorted by
// time. Its duration is the time of its last key or marker. Returns 0 and
// why when it is refused.
clip_add :: proc(lib:^Library,desc:Clip_Desc) -> (Clip,Clip_Error) {
    if lib.prepared {return 0,.Prepared}
    keys,sampled,segments,samples:=0,0,0,0
    for track in desc.tracks {
        keys+=len(track.keys)
        for i in 1..<len(track.keys) {
            if track.keys[i].time<track.keys[i-1].time {return 0,.Unsorted}
        }
        if track.sampled.track.count==0 {continue}
        s:=track.sampled.track;s.data=0
        if len(track.keys)>0 {return 0,.Invalid}
        bytes,count,ok:=sampled_walk(s,track.property,track.sampled.data,padding=0)
        if !ok || bytes!=len(track.sampled.data) {return 0,.Invalid}
        sampled+=1;segments+=count;samples+=bytes
    }
    if lib.clip_count>=len(lib.clips) || lib.track_count+len(desc.tracks)>len(lib.tracks) || lib.key_count+keys>len(lib.keys) || lib.marker_count+len(desc.markers)>len(lib.markers) || sampled>0 && (lib.sampled_count+sampled>len(lib.sampled) || lib.segment_count+segments>len(lib.segments) || lib.sample_count+samples>len(lib.samples)-SAMPLED_PADDING) {
        return 0,.Full
    }
    data:=Clip_Data{name=desc.name,loop=desc.loop,first_track=u32(lib.track_count),track_count=u32(len(desc.tracks)),first_marker=u32(lib.marker_count),marker_count=u32(len(desc.markers))}
    for track in desc.tracks {
        if track.sampled.track.count>0 {
            s:=track.sampled.track
            s.data,s.first_segment=u32(lib.sample_count),u32(lib.segment_count)
            copy(lib.samples[lib.sample_count:],track.sampled.data)
            _,count,_:=sampled_walk(s,track.property,lib.samples,lib.segments[lib.segment_count:])
            // By copy: assigning `s` makes Odin warn at callers that clip_add may keep their stack memory.
            header:=[1]Sampled_Track{s}
            copy(lib.sampled[lib.sampled_count:],header[:])
            lib.tracks[lib.track_count]={target=track.target,property=track.property,slot=track.slot,encoding=.Sampled,first=u32(lib.sampled_count),count=1}
            lib.sampled_count+=1;lib.segment_count+=count;lib.sample_count+=len(track.sampled.data);lib.track_count+=1
            data.duration=max(data.duration,s.duration)
            continue
        }
        lib.tracks[lib.track_count]={target=track.target,property=track.property,slot=track.slot,first=u32(lib.key_count),count=u32(len(track.keys))}
        lib.track_count+=1
        copy(lib.keys[lib.key_count:],track.keys)
        lib.key_count+=len(track.keys)
        if len(track.keys)>0 {data.duration=max(data.duration,track.keys[len(track.keys)-1].time)}
    }
    stored:=lib.markers[lib.marker_count:][:len(desc.markers)]
    copy(stored,desc.markers)
    slice.stable_sort_by(stored,proc(a,b:Marker) -> bool {return a.time<b.time})
    for marker in stored {data.duration=max(data.duration,marker.time)}
    lib.marker_count+=len(desc.markers)
    lib.clips[lib.clip_count]=data
    lib.clip_count+=1
    return Clip(lib.clip_count),.None
}

clip_valid :: #force_inline proc "contextless" (lib:^Library,clip:Clip) -> bool {return clip!=0 && int(clip)<=lib.clip_count}
// The clip added with this name hash, or 0.
clip_find :: proc "contextless" (lib:^Library,name:u64) -> Clip {
    for i in 0..<lib.clip_count {if lib.clips[i].name==name {return Clip(i+1)}}
    return 0
}
// Zero data for a handle that is not valid.
clip_data :: proc "contextless" (lib:^Library,clip:Clip) -> Clip_Data {
    if !clip_valid(lib,clip) {return {}}
    return lib.clips[clip-1]
}
clip_duration :: proc "contextless" (lib:^Library,clip:Clip) -> f32 {return clip_data(lib,clip).duration}
clip_tracks :: proc "contextless" (lib:^Library,clip:Clip) -> []Track {
    if !clip_valid(lib,clip) {return nil}
    data:=lib.clips[clip-1]
    return lib.tracks[data.first_track:][:data.track_count]
}
clip_markers :: proc "contextless" (lib:^Library,clip:Clip) -> []Marker {
    if !clip_valid(lib,clip) {return nil}
    data:=lib.clips[clip-1]
    return lib.markers[data.first_marker:][:data.marker_count]
}
// Empty for a track whose keys lie outside the library.
track_keys :: #force_inline proc "contextless" (lib:^Library,track:Track) -> []Keyframe {
    if lib==nil || track.encoding!=.Raw || lib.key_count<0 || lib.key_count>len(lib.keys) || int(track.first)>lib.key_count || int(track.count)>lib.key_count-int(track.first) {return nil}
    return lib.keys[track.first:][:track.count]
}

// The value of one track of a clip at a time inside the clip.
clip_evaluate :: #force_inline proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {
    if track.encoding==.Raw {return track_evaluate(track_keys(lib,track),track.property,time)}
    return sampled_evaluate(lib,track,time)
}

clip_curve :: proc "contextless" (lib:^Library,player:Player,target:u64,slot:u8,default_value:f32=0) -> f32 {
    for track in clip_tracks(lib,player.clip) {
        if track.target==target && track.slot==slot && track.property==.Float {return clip_evaluate(lib,track,player_time(lib,player)).x}
    }
    return default_value
}
