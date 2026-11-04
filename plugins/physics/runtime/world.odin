package physics

import "mirai:core"
import "mirai:host"

// Advances only physics, outside the loops: the functions of this library in
// the fixed phase of the editor loop, with the binding and the settle the
// generator gives them. Zero dt reconciles authoring poses.
step_world :: proc(w:core.World_Ref,app:^host.App,dt:f32) -> bool {
    if w.data==nil || w.info==nil || w.place!=.World || app==nil || app.shared==nil || !(dt>=0 && dt<=max(f32)) {return false}
    if !core.world_run(w,app.shared,nil,app,.Editor,.Fixed,{"physics"},{dt=dt,playing=dt>0}) {return false}
    state:=core.world_storage_of(w,Physics_State)
    return state!=nil && state.ready
}
