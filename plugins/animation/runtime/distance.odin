package anim

import "mirai:core"
import "mirai:std/base"

Animation_Distance_Request :: struct {entity:core.Entity,clip:u64,time:f32,seek:bool,animation:base.Asset_Id}
Distance_Error :: enum u8 {None,Missing_Player,Missing_Clip,Inactive_Clip,Backwards,Unsupported_Clock,Invalid_Time}

animation_distance :: proc(requests:^Animation_Requests,entity:core.Entity,clip:u64,time:f32,seek:bool=false,animation:base.Asset_Id={}) -> bool {
    if requests==nil || entity==core.NONE || clip==0 || !finite(time) || time<0 {return false}
    if cap(requests.distances.items)==0 && reserve(&requests.distances.items,REQUEST_CAPACITY)!=nil {return false}
    if len(requests.distances.items)>=REQUEST_CAPACITY {return false}
    core.push(&requests.distances,Animation_Distance_Request{entity=entity,clip=clip,time=time,seek=seek,animation=animation});return true
}

motion_play_distance :: proc(requests:^Animation_Requests,rig:core.Entity,profile:Motion_Profile,name:string,distance:f32,seek:bool=false) -> bool {
    time,clip,ok:=motion_distance_time(profile,name,distance)
    return ok && animation_distance(requests,rig,base.name_hash(base.text_get(clip[:])),time,seek,motion_distance_source(profile,name))
}
