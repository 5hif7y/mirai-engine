package asset

import "core:mem"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/serial"

// .anim: clips that move named things over time.
//
//   clips     Animation_Clip: its name and where its tracks and markers are
//   tracks    Animation_Track: what it moves, by name, and where its keys are
//   keys      anim.Keyframe, those of a track in time order
//   markers   Animation_Marker: a named moment of a clip
//
// A track names the entity it moves below the one that plays the clip; an
// empty target is that entity itself. How a clip repeats belongs to whoever
// plays it. A morph target's weight is the target "<path>/@morph/<target>".

ANIMATION_VERSION :: 1
ANIMATION_NAME_CAPACITY :: 64
// The path of a node or bone below the entity that plays, with its zero: a
// track target, a skeleton bone, a root bone.
NODE_PATH_CAPACITY :: 512
ANIMATION_MAX_CLIPS :: 1024
ANIMATION_MAX_TRACKS :: 65536
ANIMATION_MAX_KEYS :: 1<<24
ANIMATION_MAX_MARKERS :: 1<<20
ANIMATION_MORPH_PATH :: "/@morph/"

Animation_Clip :: struct {
    name:[ANIMATION_NAME_CAPACITY]u8 `mirai:"text"`,
    first_track,track_count:u32,
    first_marker,marker_count:u32,
    root:Animation_Root,
}
Animation_Root :: struct {
    bone:[NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    translation,rotation:bool,
}
Animation_Track :: struct {
    target:[NODE_PATH_CAPACITY]u8 `mirai:"text"`,
    property:anim.Property,
    slot:u8,
    first_key,key_count:u32,
}
Animation_Marker :: struct {
    time:f32,
    name:[ANIMATION_NAME_CAPACITY]u8 `mirai:"text"`,
}

Animation_Track_Desc :: struct {
    target:string,
    property:anim.Property,
    slot:u8,
    keys:[]anim.Keyframe,
}
Animation_Marker_Desc :: struct {time:f32,name:string}
Animation_Clip_Desc :: struct {
    name:string,
    tracks:[]Animation_Track_Desc,
    markers:[]Animation_Marker_Desc,
    root:Animation_Root,
}
Animation_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of: the prefab of the import that made it
    clips:[]Animation_Clip_Desc,
    source:^Import_Info,
    compression:Compression,
}

Animation_View :: struct {
    clips:[]Animation_Clip,
    tracks:[]Animation_Track,
    keys:[]anim.Keyframe,
    markers:[]Animation_Marker,
    source:^Import_Info,
}

animation_document :: proc(doc:^Document,types:^Types,desc:Animation_Desc,allocator:=context.allocator) -> Error {
    if len(desc.clips)>ANIMATION_MAX_CLIPS {return .Invalid}
    track_count,key_count,marker_count:=0,0,0
    for clip in desc.clips {
        if len(clip.tracks)>ANIMATION_MAX_TRACKS-track_count || len(clip.markers)>ANIMATION_MAX_MARKERS-marker_count {return .Invalid}
        track_count+=len(clip.tracks);marker_count+=len(clip.markers)
        for track in clip.tracks {
            if len(track.keys)>ANIMATION_MAX_KEYS-key_count {return .Invalid}
            key_count+=len(track.keys)
        }
    }
    clips:=make([dynamic]Animation_Clip,context.temp_allocator)
    tracks:=make([dynamic]Animation_Track,context.temp_allocator)
    keys:=make([dynamic]anim.Keyframe,context.temp_allocator)
    markers:=make([dynamic]Animation_Marker,context.temp_allocator)
    for clip in desc.clips {
        if len(clip.name)==0 || len(clip.name)>=ANIMATION_NAME_CAPACITY {return .Invalid}
        row:=Animation_Clip{first_track=u32(len(tracks)),track_count=u32(len(clip.tracks)),first_marker=u32(len(markers)),marker_count=u32(len(clip.markers))}
        row.root=clip.root
        text_set(row.name[:],clip.name)
        append(&clips,row)
        for track in clip.tracks {
            if len(track.target)>=NODE_PATH_CAPACITY {return .Invalid}
            stored:=Animation_Track{property=track.property,slot=track.slot,first_key=u32(len(keys)),key_count=u32(len(track.keys))}
            text_set(stored.target[:],track.target)
            append(&tracks,stored)
            append(&keys,..track.keys)
        }
        for marker in clip.markers {
            if len(marker.name)==0 || len(marker.name)>=ANIMATION_NAME_CAPACITY {return .Invalid}
            stored:=Animation_Marker{time=marker.time}
            text_set(stored.name[:],marker.name)
            append(&markers,stored)
        }
    }
    view:=Animation_View{clips=clips[:],tracks=tracks[:],keys=keys[:],markers=markers[:]}
    if !animation_check(view) {return .Invalid}
    document_init(doc,KIND_ANIMATION,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=ANIMATION_VERSION
    error:=animation_tables(doc,types,view,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
animation_tables :: proc(doc:^Document,types:^Types,view:Animation_View,desc:Animation_Desc) -> Error {
    document_put(doc,types,"clips",view.clips) or_return
    document_put(doc,types,"tracks",view.tracks) or_return
    document_put(doc,types,"keys",view.keys,{},desc.compression) or_return
    document_put(doc,types,"markers",view.markers) or_return
    return import_put(doc,types,desc.source)
}

animation_save :: proc(path:string,types:^Types,desc:Animation_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    animation_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

animation_view :: proc(a:^Asset,types:^Types) -> (view:Animation_View,error:Error) {
    kind_check(a,KIND_ANIMATION,ANIMATION_VERSION) or_return
    view.clips=table_rows(a,types,"clips",Animation_Clip) or_return
    view.tracks=table_rows(a,types,"tracks",Animation_Track) or_return
    view.keys=table_rows(a,types,"keys",anim.Keyframe) or_return
    view.markers=table_rows(a,types,"markers",Animation_Marker) or_return
    view.source=import_info(a,types) or_return
    if !animation_check(view) {return {},.Corrupt}
    return view,.None
}

// Every range inside its table, the keys of a track in time order, numbers
// finite and names ended and, for clips, different from each other.
animation_check :: proc(view:Animation_View) -> bool {
    if len(view.clips)>ANIMATION_MAX_CLIPS || len(view.tracks)>ANIMATION_MAX_TRACKS || len(view.keys)>ANIMATION_MAX_KEYS || len(view.markers)>ANIMATION_MAX_MARKERS {return false}
    for &clip,i in view.clips {
        if !text_valid(clip.name[:]) || clip.name[0]==0 {return false}
        if !text_valid(clip.root.bone[:]) {return false}
        if u64(clip.first_track)+u64(clip.track_count)>u64(len(view.tracks)) {return false}
        if u64(clip.first_marker)+u64(clip.marker_count)>u64(len(view.markers)) {return false}
        for &other in view.clips[:i] {
            if other.name==clip.name {return false}
        }
    }
    for &track in view.tracks {
        if !text_valid(track.target[:]) || track.property>max(anim.Property) {return false}
        if u64(track.first_key)+u64(track.key_count)>u64(len(view.keys)) {return false}
        keys:=view.keys[track.first_key:][:track.key_count]
        for key,k in keys {
            if !finite(key.time,key.value[0],key.value[1],key.value[2],key.value[3]) || key.time<0 {return false}
            if key.ease>max(type_of(key.ease)) || key.interpolation>max(anim.Interpolation) {return false}
            if !finite(key.in_slope.x,key.in_slope.y,key.in_slope.z,key.in_slope.w,key.out_slope.x,key.out_slope.y,key.out_slope.z,key.out_slope.w) {return false}
            if track.property==.Rotation && abs(key.value.x)+abs(key.value.y)+abs(key.value.z)+abs(key.value.w)<1e-8 {return false}
            if key.interpolation==.Cubic_Spline && !key.tangents {return false}
            if k>0 && key.time<keys[k-1].time {return false}
        }
    }
    for &marker in view.markers {
        if !text_valid(marker.name[:]) || marker.name[0]==0 || !finite(marker.time) || marker.time<0 {return false}
    }
    return true
}

// What a library needs to hold the clips of a view once.
animation_library_desc :: proc(view:Animation_View) -> anim.Library_Desc {
    desc:=anim.Library_Desc{max_clips=max(len(view.clips),1)}
    if !animation_check(view) {return desc}
    for clip in view.clips {
        desc.max_tracks+=int(clip.track_count);desc.max_markers+=int(clip.marker_count)
        for track in view.tracks[clip.first_track:][:clip.track_count] {desc.max_keys+=int(track.key_count)}
    }
    desc.max_tracks=max(desc.max_tracks,1);desc.max_keys=max(desc.max_keys,1)
    return desc
}

// The clips of a view as descriptions to change and save again: their names,
// tracks and markers point into the view, which must stay open until they are
// saved. False when allocator has no room for them.
animation_descs :: proc(view:Animation_View,allocator:=context.allocator) -> (clips:[]Animation_Clip_Desc,ok:bool) {
    error:mem.Allocator_Error
    if clips,error=make([]Animation_Clip_Desc,len(view.clips),allocator);error!=nil {return nil,false}
    for &clip,i in view.clips {
        tracks,e1:=make([]Animation_Track_Desc,int(clip.track_count),allocator)
        markers,e2:=make([]Animation_Marker_Desc,int(clip.marker_count),allocator)
        if e1!=nil || e2!=nil {return nil,false}
        for &track,j in view.tracks[clip.first_track:][:clip.track_count] {tracks[j]={target=base.text_get(track.target[:]),property=track.property,slot=track.slot,keys=view.keys[track.first_key:][:track.key_count]}}
        for &marker,j in view.markers[clip.first_marker:][:clip.marker_count] {markers[j]={marker.time,base.text_get(marker.name[:])}}
        clips[i]={name=base.text_get(clip.name[:]),tracks=tracks,markers=markers,root=clip.root}
    }
    return clips,true
}

// Adds the clips of a checked view to a library, in their order, each with
// the loop given. Tracks and clips carry the name_hash of their names (0 for
// a track without target); the id of a marker is its row in view.markers.
// Returns the first clip, or 0 without changes when the library has no room.
animation_clips_add :: proc(view:Animation_View,lib:^anim.Library,loop:=anim.Loop.Once) -> anim.Clip {
    if !animation_check(view) || len(view.clips)>len(lib.clips)-lib.clip_count {return 0}
    needed_tracks,needed_keys,needed_markers:u64
    for clip in view.clips {
        needed_tracks+=u64(clip.track_count);needed_markers+=u64(clip.marker_count)
        for track in view.tracks[clip.first_track:][:clip.track_count] {needed_keys+=u64(track.key_count)}
    }
    if needed_tracks>u64(len(lib.tracks)-lib.track_count) || needed_keys>u64(len(lib.keys)-lib.key_count) || needed_markers>u64(len(lib.markers)-lib.marker_count) {return 0}
    first:anim.Clip
    for &clip in view.clips {
        tracks:=make([]anim.Track_Desc,clip.track_count,context.temp_allocator)
        for &track,i in view.tracks[clip.first_track:][:clip.track_count] {
            target:=serial.text_field(track.target[:])
            tracks[i]={target=target!=""?base.name_hash(target):0,property=track.property,slot=track.slot,keys=view.keys[track.first_key:][:track.key_count]}
        }
        markers:=make([]anim.Marker,clip.marker_count,context.temp_allocator)
        for &marker,i in view.markers[clip.first_marker:][:clip.marker_count] {
            markers[i]={marker.time,clip.first_marker+u32(i)}
        }
        added,_:=anim.clip_add(lib,{name=base.name_hash(serial.text_field(clip.name[:])),loop=loop,tracks=tracks,markers=markers})
        if added==0 {return 0}
        if first==0 {first=added}
    }
    return first
}
