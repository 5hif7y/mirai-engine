package render

import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

@(test)
an_entity_is_drawn_between_its_last_two_ticks_at_the_alpha_of_the_frame :: proc(t:^testing.T) {
    previous,current:=mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY
    current.position={2,0,0}
    world:=core.World_Transform{current,previous}
    testing.expect_value(t,drawn_transform(world,core.FRAME_TIME_DEFAULT),current)
    testing.expect_value(t,drawn_transform(world,{alpha=1}),current)
    testing.expect_value(t,drawn_transform(world,{alpha=0.5}).position,[3]f32{1,0,0})
    testing.expect_value(t,drawn_transform(world,{alpha=0}).position,previous.position)
}
