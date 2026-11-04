package destruct

import "mirai:core"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"
import fr "plugins:destruct/runtime/fracture"
import "mirai:std/geom"

Group_Info :: struct {
    group:u32,
    entity:core.Entity,
    body:sim.Body_Handle,
    position:[3]f32,
    rotation:quaternion128,
    linear,angular:[3]f32,
    awake,debris:bool,
    remaining_ticks:u32,
    expires:bool,
}

// What the queries of the destructibles read, for a step to receive in one parameter.
@(params)
Destruct_View :: struct {
    physics:core.Ref(phys.Physics_State),
    fractures:core.Ref(Fracture_State),
    states:core.Read(Destructible_State),
    groups:core.Read(Destructible_Group),
}

// The destructible e is part of: itself, or the one a body that broke off it
// belongs to; none when it is neither.
owner :: proc(v:Destruct_View,e:core.Entity) -> core.Entity {
    if group,has:=core.get(v.groups,e);has {return group.owner}
    return core.has(v.states,e)?e:core.NONE
}

pieces :: proc(v:Destruct_View,e:core.Entity,out:[]fr.Piece_Info) -> int {
    state,has:=core.get(v.states,e)
    return has && v.physics.ready && v.fractures.ready?fr.destructible_pieces(&v.fractures.ptr.fracture,&v.physics.ptr.world,state.handle,out):0
}

clusters :: proc(v:Destruct_View,e:core.Entity,out:[]fr.Cluster_Info) -> int {
    state,has:=core.get(v.states,e)
    return has && v.fractures.ready?fr.destructible_clusters(&v.fractures.ptr.fracture,state.handle,out):0
}

groups :: proc(v:Destruct_View,e:core.Entity,out:[]Group_Info) -> int {
    state,has:=core.get(v.states,e)
    if !has || !v.physics.ready || !v.fractures.ready {return 0}
    fill :: proc(v:Destruct_View,handle:fr.Destructible_Handle,e:core.Entity,id:u32,body:sim.Body_Handle,debris:bool,out:[]Group_Info,at:int) -> bool {
        world:=&v.physics.ptr.world
        if !sim.body_valid(world,body) {return false}
        if at<len(out) {
            pose:=sim.body_transform(world,body)
            ticks,expires:=fr.destructible_body_remaining_ticks(&v.fractures.ptr.fracture,world,handle,body)
            out[at]={id,e,body,pose.p,pose.q,sim.body_linear_velocity(world,body),sim.body_angular_velocity(world,body),sim.body_is_awake(world,body),debris,ticks,expires}
        }
        return true
    }
    count:=int(fill(v,state.handle,e,0,state.body,false,out,0))
    for row in 0..<core.count(v.groups) {
        group:=core.at(v.groups,row)
        if group.owner!=e || group.group==0 {continue}
        entity:=core.entity_at(v.groups,row)
        if fill(v,state.handle,entity,group.group,phys.body_of(v.physics,entity),group.debris,out,count) {count+=1}
    }
    return count
}

piece_geometry :: proc(cache:core.Ref(Destruct_Cache),e:core.Entity,id:i32,out:^geom.Mesh_Buffer) -> bool {
    if out==nil {return false}
    entry:=entry_find(cache.ptr,e)
    if entry==nil {return false}
    visual:=visual_find(entry,id)
    if visual==nil {return false}
    mesh:=visual_mesh(entry,visual)
    if !geom.mesh_is_valid(mesh) || len(mesh.indices)==0 {return false}
    if reserve(&out.positions,len(mesh.positions))!=nil || reserve(&out.normals,len(mesh.normals))!=nil ||
       reserve(&out.uvs,len(mesh.uvs))!=nil || reserve(&out.colors,len(mesh.colors))!=nil ||
       reserve(&out.indices,len(mesh.indices))!=nil || reserve(&out.materials,len(mesh.materials))!=nil {return false}
    geom.mesh_buffer_clear(out)
    append(&out.positions,..mesh.positions);append(&out.normals,..mesh.normals)
    append(&out.uvs,..mesh.uvs);append(&out.colors,..mesh.colors)
    append(&out.indices,..mesh.indices);append(&out.materials,..mesh.materials)
    return true
}
