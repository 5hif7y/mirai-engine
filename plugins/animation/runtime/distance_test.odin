package anim

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"

@(test)
distance_playback_requests_select_named_clips_and_times_reject_invalid_data_and_reuse_queue_memory :: proc(t:^testing.T) {
    entity:=core.entity_make(1,1);profile:=motion_test_profile();defer motion_profile_free(&profile)
    requests:Animation_Requests;defer delete(requests.distances.items)
    testing.expect(t,motion_play_distance(&requests,entity,profile,"stop",2))
    testing.expect_value(t,requests.distances.items[0],Animation_Distance_Request{entity=entity,clip=base.name_hash("walk"),time=.5})
    clear(&requests.distances.items)
    testing.expect(t,motion_play_distance(&requests,entity,profile,"stop",0,true))
    testing.expect_value(t,requests.distances.items[0],Animation_Distance_Request{entity=entity,clip=base.name_hash("walk"),time=2,seek=true})
    testing.expect(t,!animation_distance(nil,entity,1,0) && !animation_distance(&requests,core.NONE,1,0) && !animation_distance(&requests,entity,0,0) && !animation_distance(&requests,entity,1,-1) && !animation_distance(&requests,entity,1,f32(0h7fc00000)))
    testing.expect(t,!motion_play_distance(&requests,entity,profile,"missing",0) && !motion_play_distance(&requests,entity,profile,"stop",f32(0h7f800000)))
    clear(&requests.distances.items)
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    stable:=true
    for _ in 0..<REQUEST_CAPACITY {stable &&=motion_play_distance(&requests,entity,profile,"stop",2)}
    full_rejected:=!motion_play_distance(&requests,entity,profile,"stop",2)
    clear(&requests.distances.items);stable &&=motion_play_distance(&requests,entity,profile,"stop",1)
    context=saved
    testing.expect(t,stable && full_rejected && requests.distances.items[0].time==1)
}
