package anim

import "core:math/linalg"
import "core:testing"
import "mirai:core"
import mm "mirai:std/math"

// The feet of the rig of a character stand along the up of its vertical,
// whatever its bones do; a rig of no character, along its up in the frame
// it is placed in.
@(test)
the_feet_stand_along_the_vertical_of_the_character :: proc(t:^testing.T) {
    es:core.Entities;core.entities_init(&es);defer core.entities_destroy(&es)
    transforms:core.Table(core.Transform);core.table_init(&transforms,"Transform");defer core.table_destroy(&transforms)
    parents:core.Table(core.Parent);core.table_init(&parents,"Parent");defer core.table_destroy(&parents)
    verticals:core.Table(core.Vertical);core.table_init(&verticals,"Vertical");defer core.table_destroy(&verticals)
    character,rig,statue:=core.create(&es),core.create(&es),core.create(&es)
    side:=mm.quat_between({0,1,0},{1,0,0})
    core.add(&transforms,character,core.Transform{position={20,0,0},rotation=side,scale=1})
    core.add(&transforms,rig,core.Transform{rotation=mm.quat_axis_angle({0,0,1},0.4),scale=1})
    core.add(&transforms,statue,core.Transform{rotation=side,scale=1})
    core.add(&parents,rig,core.Parent{entity=character})
    core.add(&verticals,character,core.Vertical{side})
    core.table_settle(&transforms,&es);core.table_settle(&parents,&es);core.table_settle(&verticals,&es)
    inputs:=Grounding_Inputs{transforms=core.read(&transforms),parents=core.read(&parents),verticals=core.read(&verticals)}
    basis,_:=core.world_of(core.read(&transforms),core.read(&parents),character)
    up:=grounding_up(inputs,rig,basis,{0,1,0})
    testing.expectf(t,linalg.length(up-{1,0,0})<1e-4,"the up of the vertical of the character, not of the rig: %v",up)
    up=grounding_up(inputs,statue,mm.TRANSFORM_IDENTITY,{0,1,0})
    testing.expectf(t,linalg.length(up-{1,0,0})<1e-4,"without a character, the up of the rig as placed: %v",up)
}
