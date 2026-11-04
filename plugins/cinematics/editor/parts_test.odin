package cinematics_editor

import "core:testing"
import lib "mirai:std/anim"
import cine "plugins:cinematics/runtime"

@(test)
keys_stay_in_order_replace_the_one_at_their_tick_and_move :: proc(t:^testing.T) {
    track:cine.Cinematic_Track
    testing.expect(t,key_put(&track,{time=20,value={2,0,0,0}}))
    testing.expect(t,key_put(&track,{time=0,value={0,0,0,0}}))
    testing.expect(t,key_put(&track,{time=10,value={1,0,0,0}}))
    testing.expect(t,key_put(&track,{time=10,value={5,0,0,0},interpolation=.Step}))
    testing.expect_value(t,track.key_count,u32(3))
    testing.expect_value(t,track.keys[1],lib.Keyframe{time=10,value={5,0,0,0},interpolation=.Step})
    testing.expect(t,key_move(&track,10,30))
    times:=[3]f32{track.keys[0].time,track.keys[1].time,track.keys[2].time}
    testing.expect_value(t,times,[3]f32{0,20,30})
    testing.expect_value(t,track.keys[2].interpolation,lib.Interpolation.Step)
    testing.expect(t,key_move(&track,30,20)) // over the key there
    testing.expect_value(t,track.key_count,u32(2))
    testing.expect(t,!key_put(&track,{time=7},true))
    testing.expect(t,key_put(&track,{time=0},true))
    testing.expect_value(t,track.key_count,u32(1))
    testing.expect_value(t,track.keys[1],lib.Keyframe{})
}

@(test)
a_track_takes_sixteen_keys :: proc(t:^testing.T) {
    track:cine.Cinematic_Track
    for i in 0..<cine.CINEMATIC_KEYS {testing.expect(t,key_put(&track,{time=f32(cine.CINEMATIC_KEYS-i)}))}
    testing.expect(t,!key_put(&track,{time=100}))
    testing.expect(t,key_put(&track,{time=1,value={1,1,1,1}}))
    _,valid:=cine.cinematic_track_value(&track,3)
    testing.expect(t,valid)
}
