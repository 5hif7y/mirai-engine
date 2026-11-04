package animation_editor

import "base:runtime"
import "core:fmt"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/serial"
import mm "mirai:std/math"

AUTHORING_KEYS :: 512
Authoring_Keyframe :: struct {
    time:f32 `mirai:"min=0,unit=s"`,
    value:mm.Vec4,
    ease:mm.Ease `mirai:"optional"`,
    interpolation:lib.Interpolation `mirai:"optional"`,
    tangents:bool `mirai:"optional"`,
    in_slope,out_slope:mm.Vec4 `mirai:"optional"`,
}

@(private)
authoring_keyframe :: proc(value:Authoring_Keyframe) -> lib.Keyframe {
    return {time=value.time,value=value.value,ease=value.ease,interpolation=value.interpolation,tangents=value.tangents,in_slope=value.in_slope,out_slope=value.out_slope}
}
Clip_Inspect_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text,optional,label=Clip name; empty selects the first clip"`,
    offset:u32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=256"`,
}
Clip_Create_Params :: struct {
    asset:base.Asset_Id `mirai:"optional,label=Existing .anim asset to append a clip to; mutually exclusive with path"`,
    path:[1024]u8 `mirai:"text,optional,label=New .anim file; mutually exclusive with asset"`,
    name:[64]u8 `mirai:"text"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Clip_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text,label=Existing clip name"`,
    name:[64]u8 `mirai:"text,label=New clip name"`,
    root:aa.Animation_Root,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Track_Inspect_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    track:u32 `mirai:"label=Index within the selected clip"`,
    offset:u32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=512"`,
}
Track_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    target:[aa.NODE_PATH_CAPACITY]u8 `mirai:"text,label=Canonical bone or rigid-node path; scalar curve name for Float/Vector"`,
    property:lib.Property,
    slot:u8 `mirai:"optional"`,
    keys:[AUTHORING_KEYS]Authoring_Keyframe `mirai:"optional,label=Ordered by time; animation.key.set edits a longer track key by key"`,
    remove:bool `mirai:"optional,label=Removes the track"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Key_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    track:u32,
    index:u32 `mirai:"label=Existing key index or the key count to append"`,
    key:Authoring_Keyframe `mirai:"optional"`,
    remove:bool `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Marker_Set_Params :: struct {
    asset:base.Asset_Id,
    clip:[64]u8 `mirai:"text"`,
    index:u32 `mirai:"label=Existing marker index or the marker count to append"`,
    marker:aa.Animation_Marker `mirai:"optional"`,
    remove:bool `mirai:"optional"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}

@(private)
authoring_clip_register :: proc(s:^editor.Session) {
    inspect:=Clip_Inspect_Params{limit=128}
    track:=Track_Inspect_Params{limit=128}
    authoring_method_register(s,{name="animation.clip.create",summary="Creates an empty named clip in a new .anim or after the clips of an existing one. One step of undo.",params=Clip_Create_Params,params_info=type_info_of(Clip_Create_Params),run=authoring_clip_create},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_method_register(s,{name="animation.clip.set",summary="Renames a clip and replaces its root motion; its tracks and markers stay.",params=Clip_Set_Params,params_info=type_info_of(Clip_Set_Params),run=authoring_clip_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_method_register(s,{name="animation.track.set",summary="Creates, replaces or removes the track of a clip found by target, property and slot.",params=Track_Set_Params,params_info=type_info_of(Track_Set_Params),run=authoring_track_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_method_register(s,{name="animation.key.set",summary="Replaces, appends or removes one key of a track; the clip must stay valid, with finite values and ordered times.",params=Key_Set_Params,params_info=type_info_of(Key_Set_Params),run=authoring_key_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
    authoring_method_register(s,{name="animation.marker.set",summary="Replaces, appends or removes a named clip marker used for animation events and synchronization.",params=Marker_Set_Params,params_info=type_info_of(Marker_Set_Params),run=authoring_marker_set},Authoring_Write_Result,type_info_of(Authoring_Write_Result))
}

@(private)
authoring_clip_index :: proc(call:^api.Call,view:aa.Animation_View,name:string) -> (int,bool) {
    for &clip,i in view.clips {if base.text_get(clip.name[:])==name || name=="" && i==0 {return i,true}}
    authoring_failure(call,"clip","Missing_Clip","a clip name in the asset",name,"The clip does not exist")
    return -1,false
}

@(private)
authoring_clip_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,result:^Authoring_File) -> (view:aa.Animation_View,ok:bool) {
    if !authoring_open(s,call,id,aa.KIND_ANIMATION,result) {return}
    error:aa.Error
    view,error=aa.animation_view(&result.file,&s.app.assets.types)
    if error!=.None {authoring_failure(call,"asset","Invalid_Asset","a valid .anim asset",fmt.tprintf("%v",error),"The animation asset is invalid");return}
    return view,true
}

@(private)
authoring_clip_descs :: proc(view:aa.Animation_View,call:^api.Call) -> (clips:[]aa.Animation_Clip_Desc,ok:bool) {
    if clips,ok=aa.animation_descs(view,call.allocator);!ok {authoring_failure(call,"clips","Out_Of_Memory","memory for clip descriptions","allocation failed","The clip descriptions could not be allocated",api.INTERNAL_ERROR)}
    return
}

@(private)
authoring_clip_save :: proc(s:^editor.Session,call:^api.Call,target:Authoring_File,id:base.Asset_Id,view:aa.Animation_View,clips:[]aa.Animation_Clip_Desc) {
    doc:aa.Document
    defer aa.document_destroy(&doc)
    if error:=aa.animation_document(&doc,&s.app.assets.types,{id=id,clips=clips,source=view.source},s.app.allocator);error!=.None {authoring_failure(call,"clips","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","valid names, root metadata and ordered finite keys within clip capacities",fmt.tprintf("%v",error),"The animation edit could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    _=authoring_publish(s,call,target,&doc)
}

@(private)
authoring_clip_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Clip_Inspect_Params)
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    selected,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    out:=call.out
    serial.text_write_raw(out,"{");authoring_result(call,p.asset,file.path)
    api.write_key(out,"clips");serial.text_write_raw(out,"[")
    for &clip,i in view.clips {if i>0 {serial.text_write_raw(out,",")};serial.text_write_raw(out,"{");api.write_text(out,"name",base.text_get(clip.name[:]),true);serial.write_u8(out,'}')}
    serial.text_write_raw(out,"]")
    clip:=view.clips[selected]
    api.write_text(out,"clip",base.text_get(clip.name[:]))
    api.write_key(out,"root");authoring_write_value(call,&clip.root,type_info_of(aa.Animation_Root))
    tracks:=view.tracks[clip.first_track:][:clip.track_count]
    api.write_uint(out,"tracks_total",u64(len(tracks)))
    api.write_key(out,"tracks");serial.text_write_raw(out,"[")
    start:=min(int(p.offset),len(tracks));end:=min(start+int(p.limit),len(tracks))
    for &track,i in tracks[start:end] {
        if i>0 {serial.text_write_raw(out,",")}
        serial.text_write_raw(out,"{");api.write_int(out,"index",i64(start+i),true)
        api.write_text(out,"target",base.text_get(track.target[:]))
        api.write_key(out,"property");authoring_write_value(call,&track.property,type_info_of(lib.Property))
        api.write_uint(out,"slot",u64(track.slot));api.write_uint(out,"keys_total",u64(track.key_count));serial.text_write_raw(out,"}")
    }
    serial.text_write_raw(out,"]")
    markers:=view.markers[clip.first_marker:][:clip.marker_count]
    api.write_uint(out,"markers_total",u64(len(markers)))
    api.write_key(out,"markers");serial.text_write_raw(out,"[")
    start=min(int(p.offset),len(markers));end=min(start+int(p.limit),len(markers))
    for &marker,i in markers[start:end] {if i>0 {serial.text_write_raw(out,",")};serial.text_write_raw(out,"{");api.write_int(out,"index",i64(start+i),true);api.write_key(out,"marker");authoring_write_value(call,&marker,type_info_of(aa.Animation_Marker));serial.text_write_raw(out,"}")}
    serial.text_write_raw(out,"]}")
}

@(private)
authoring_clip_create :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Clip_Create_Params)
    if !authoring_editable(s,call) {return}
    path:=base.text_get(p.path[:])
    if (p.asset!={})==(path!="") {authoring_failure(call,"asset","Exclusive_Reference","exactly one of asset or path","both supplied or both empty","Supply exactly one of asset or path");return}
    clip:=aa.Animation_Clip_Desc{name=base.text_get(p.name[:])}
    if p.asset!={} {
        target:Authoring_File;defer aa.asset_close(&target.file)
        view,ok:=authoring_clip_open(s,call,p.asset,&target);if !ok {return}
        clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
        updated,appended:=authoring_replace_row(clips,len(clips),clip,false,aa.ANIMATION_MAX_CLIPS,call.allocator)
        if !appended {authoring_failure(call,"clips","Capacity","space for an additional clip","full or allocation failed","The animation asset has no capacity for another clip");return}
        authoring_clip_save(s,call,target,p.asset,view,updated)
        return
    }
    target,id,ok:=authoring_create_target(s,call,path,".anim");if !ok {return}
    authoring_clip_save(s,call,target,id,{},([]aa.Animation_Clip_Desc{clip}))
}

@(private)
authoring_clip_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Clip_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    clips[index].name,clips[index].root=base.text_get(p.name[:]),p.root
    authoring_clip_save(s,call,file,p.asset,view,clips)
}

@(private)
authoring_track_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Track_Inspect_Params)
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clip:=view.clips[index]
    if p.track>=clip.track_count {authoring_failure(call,"track","Out_Of_Range",fmt.tprintf("an index below %d",clip.track_count),fmt.tprintf("%d",p.track),"track is outside the selected clip");return}
    track:=view.tracks[clip.first_track+p.track]
    keys:=view.keys[track.first_key:][:track.key_count]
    out:=call.out
    serial.text_write_raw(out,"{");authoring_result(call,p.asset,file.path)
    api.write_text(out,"clip",base.text_get(clip.name[:]));api.write_text(out,"target",base.text_get(track.target[:]))
    api.write_key(out,"property");authoring_write_value(call,&track.property,type_info_of(lib.Property))
    api.write_uint(out,"slot",u64(track.slot));api.write_uint(out,"keys_total",u64(len(keys)))
    api.write_key(out,"keys");serial.text_write_raw(out,"[")
    start:=min(int(p.offset),len(keys));end:=min(start+int(p.limit),len(keys))
    for &key,i in keys[start:end] {if i>0 {serial.text_write_raw(out,",")};serial.text_write_raw(out,"{");api.write_int(out,"index",i64(start+i),true);api.write_key(out,"key");authoring_write_value(call,&key,type_info_of(lib.Keyframe));serial.text_write_raw(out,"}")}
    serial.text_write_raw(out,"]}")
}

@(private)
authoring_track_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Track_Set_Params)
    if !authoring_editable(s,call) {return}
    count,present:=api.params_array_count(call,"keys")
    if !p.remove && !present || count>len(p.keys) {authoring_failure(call,"keys","Capacity","an array with at most 512 entries",fmt.tprintf("%d entries; present=%t",count,present),"keys must be an array with at most 512 entries");return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    tracks:=clips[index].tracks
    at:=len(tracks)
    for track,i in tracks {if track.target==base.text_get(p.target[:]) && track.property==p.property && track.slot==p.slot {at=i;break}}
    keys,error:=make([]lib.Keyframe,count,call.allocator)
    if error!=nil {authoring_failure(call,"keys","Out_Of_Memory","memory for track keys","allocation failed","The keys could not be prepared",api.INTERNAL_ERROR);return}
    for value,i in p.keys[:count] {keys[i]=authoring_keyframe(value)}
    updated,replaced:=authoring_replace_row(tracks,at,aa.Animation_Track_Desc{target=base.text_get(p.target[:]),property=p.property,slot=p.slot,keys=keys},p.remove,aa.ANIMATION_MAX_TRACKS,call.allocator)
    if !replaced {authoring_failure(call,"target","Invalid_Edit","an existing track to remove or capacity to add","missing track, capacity exceeded or allocation failed","The track cannot be added or removed");return}
    clips[index].tracks=updated
    authoring_clip_save(s,call,file,p.asset,view,clips)
}

@(private)
authoring_key_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Key_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    if int(p.track)>=len(clips[index].tracks) {authoring_failure(call,"track","Out_Of_Range",fmt.tprintf("an index below %d",len(clips[index].tracks)),fmt.tprintf("%d",p.track),"track is outside the selected clip");return}
    track:=&clips[index].tracks[p.track]
    keys,replaced:=authoring_replace_row(track.keys,int(p.index),authoring_keyframe(p.key),p.remove,aa.ANIMATION_MAX_KEYS,call.allocator)
    if !replaced {authoring_failure(call,"index","Invalid_Edit",fmt.tprintf("an existing key or append at %d",len(track.keys)),fmt.tprintf("%d; remove=%t",p.index,p.remove),"The key edit cannot be prepared within capacity");return}
    track.keys=keys
    authoring_clip_save(s,call,file,p.asset,view,clips)
}

@(private)
authoring_marker_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Marker_Set_Params)
    if !authoring_editable(s,call) {return}
    file:Authoring_File;defer aa.asset_close(&file.file)
    view,ok:=authoring_clip_open(s,call,p.asset,&file);if !ok {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clips,prepared:=authoring_clip_descs(view,call);if !prepared {return}
    marker:=aa.Animation_Marker_Desc{p.marker.time,base.text_get(p.marker.name[:])}
    markers,replaced:=authoring_replace_row(clips[index].markers,int(p.index),marker,p.remove,aa.ANIMATION_MAX_MARKERS,call.allocator)
    if !replaced {authoring_failure(call,"index","Invalid_Edit",fmt.tprintf("an existing marker or append at %d",len(clips[index].markers)),fmt.tprintf("%d; remove=%t",p.index,p.remove),"The marker edit cannot be prepared within capacity");return}
    clips[index].markers=markers
    authoring_clip_save(s,call,file,p.asset,view,clips)
}
