package game

import "mirai:core"
import inp "mirai:engine/input"
import mm "mirai:std/math"

// Turns its entity around the vertical axis, the other way while the action
// REVERSE is held, which ../input.mirai binds.
@(component)
Spinner :: struct {speed:f32 `mirai:"unit=rad/s"`}

REVERSE :: inp.Action(16)

@(step="fixed")
game_spin :: proc(spinners:core.Read(Spinner),transforms:^core.Table(core.Transform),actions:core.Ref(inp.Actions),time:core.Time) {
    turn:=f32(inp.action_down(actions.ptr,REVERSE)?-1:1)*time.dt
    for row in 0..<core.count(spinners) {
        local:=core.free(transforms,core.entity_at(spinners,row))
        if local==nil {continue}
        local.rotation=mm.quat_axis_angle({0,1,0},core.at(spinners,row).speed*turn)*local.rotation
    }
}
