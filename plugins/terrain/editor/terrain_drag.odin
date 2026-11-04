package terrain_editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import mm "mirai:std/math"
import terrain "plugins:terrain/runtime"

// Sub-steps of a grow stroke in one frame: a fast drag catches up over the
// next frames instead of stalling one.
GROW_STEPS_PER_FRAME :: 4

Drag_Axis :: enum {Free,X,Y,Z}
Terrain_Drag :: struct {
    active,started,released:bool,
    axis:Drag_Axis,
    anchor,plane,last,destination:[3]f32,
    follow:[3]f32,
    brush:terrain.Brush,
}

@(private)
stroke_drag_begin :: proc(tool:^Terrain_Tool,point:[3]f32,view:core.View) {
    stroke:=&tool.stroke
    stroke.drag={}
    if tool.brush!=.Grab && tool.brush!=.Grow {return}
    _,forward:=core.view_ray(view,view.size*0.5)
    plane:=linalg.normalize0((linalg.transpose(stroke.to_world)*[4]f32{forward.x,forward.y,forward.z,0}).xyz)
    stroke.drag={active=true,axis=tool.axis,anchor=point,last=point,follow=point,plane=plane,
        brush={kind=tool.brush,center=point,normal=stroke.normal,radius=brush_of(tool).radius/stroke.scale,amount=1,max_edge=tool.edge_length/stroke.scale}}
}

@(private)
terrain_drag_turn :: proc(drag:^Terrain_Drag,point:[3]f32) -> (rotation:mm.Quat,follow:[3]f32) {
    rotation=1;follow=drag.follow
    before,after:=drag.last-follow,point-follow
    a,b:=linalg.length(before),linalg.length(after)
    radius:=drag.brush.radius
    if !(radius>0) {return}
    distance:=radius*0.5
    if a>1e-6 && b>1e-6 {
        turn:=mm.quat_between(before/a,after/b)
        angle:=mm.quat_angle(1,turn)
        if angle>1e-6 {
            fade:=min(min(a,b)/distance,1)
            limit:=2*linalg.length(point-drag.last)/radius
            rotation=mm.quat_slerp(1,turn,min(fade,limit/angle))
        }
    }
    if b>distance {follow=point-after*(distance/b)}
    return
}

@(private)
terrain_drag_point :: proc(drag:^Terrain_Drag,origin,direction:[3]f32) -> (point:[3]f32,ok:bool) {
    if drag.axis==.Free {
        denominator:=linalg.dot(direction,drag.plane)
        if abs(denominator)<1e-5 {return}
        distance:=linalg.dot(drag.anchor-origin,drag.plane)/denominator
        if distance<0 {return}
        point=origin+direction*distance
    } else {
        axis:=[3]f32{};axis[int(drag.axis)-1]=1
        parallel:=linalg.dot(direction,axis)
        denominator:=1-parallel*parallel
        if denominator<1e-4 {return}
        offset:=origin-drag.anchor
        distance:=(linalg.dot(offset,axis)-parallel*linalg.dot(offset,direction))/denominator
        point=drag.anchor+axis*distance
        if linalg.dot(point-origin,direction)<0 {return}
    }
    for value in point {if value-value!=0 || abs(value)>terrain.HEIGHT_LIMIT {return {},false}}
    return point,true
}

@(private)
stroke_drag_apply :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,input:core.Input,view:core.View) {
    stroke:=&tool.stroke;drag:=&stroke.drag
    point,_,ok:=stroke_point(stroke,s.viewport,input.mouse_position)
    if !ok {return}
    if drag.started && linalg.length(point-drag.last)<1e-5 {return}
    brush:=drag.brush
    budget:=terrain_vertex_budget(world,stroke.id)
    if brush.kind==.Grab {
        baseline:=editor.revision_head(&tool.history,stroke.id,stroke.revision)
        if baseline==nil {return}
        brush.delta=point-drag.anchor
        change:=terrain.source_edit(&stroke.source,brush,budget,baseline)
        if change.error!=.None {edit_error(s,change.error);drag.destination=drag.last;return}
        stroke_changed(stroke,change)
        drag.last=point
    } else if stroke.source.kind==.Volume {
        brush.center=drag.last;brush.delta=point-drag.last
        change:=terrain.source_edit(&stroke.source,brush,budget)
        if change.error!=.None {edit_error(s,change.error);drag.destination=drag.last;return}
        stroke_changed(stroke,change)
        drag.last=point
    } else {
        distance:=linalg.length(point-drag.last)
        spacing:=max(min(brush.radius*0.15,brush.max_edge*0.5),0.001)
        steps:=min(int(math.ceil(distance/spacing)),GROW_STEPS_PER_FRAME)
        for _ in 0..<steps {
            delta:=point-drag.last;length:=linalg.length(delta)
            if length<1e-5 {break}
            brush.center=drag.last;brush.delta=delta*(min(length,spacing)/length)
            rotation,follow:=terrain_drag_turn(drag,drag.last+brush.delta)
            brush.rotation=rotation
            change:=terrain.source_edit(&stroke.source,brush,budget)
            if change.error!=.None {edit_error(s,change.error);drag.destination=drag.last;return}
            stroke_changed(stroke,change)
            drag.last+=brush.delta
            drag.follow=follow
        }
    }
    drag.started=true
}
