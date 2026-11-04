package fracture

import "mirai:std/geom"
import sim "plugins:physics/runtime/sim"

Region :: struct {
    point:Vec3,
    radius:f32,
    half_extents:Vec3,
    rotation:Quat,
    falloff:Radial_Falloff,
}

@(private)
destruct_region_weight :: proc "contextless" (event:^Fracture_Event,point:Vec3) -> f32 {
    if event.half_extents!={} {return sim.box_weight(point,event.point,event.half_extents,event.rotation,event.falloff)}
    return sim.radial_weight(length(point-event.point),event.radius,event.falloff)
}

destructible_field_body :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,piece:i32,region:Region,amount:f32,impulse:Vec3={},weaken:=false) -> (event:Fracture_Event,broke,strained:bool) {
    d,index:=destructible_get(f,h)
    if d==nil || piece>=0 && piece_body(f,w,index,piece)=={} {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=piece,point=region.point,radius=region.radius,half_extents=region.half_extents,
        rotation=region.rotation,falloff=region.falloff,vector=impulse,strain=amount,kind=weaken?.Weaken:.Damage}
    broke,strained=fracture_damage(f,w,index,&event)
    return
}

@(private)
destruct_finite :: proc "contextless" (values:..f32) -> bool {
    for value in values {if value-value!=0 {return false}}
    return true
}

@(private)
destruct_source_valid :: proc(desc:Destructible_Desc,source:^geom.Fracture) -> bool {
    count:=len(source.pieces)
    if len(desc.piece_anchors)!=0 && len(desc.piece_anchors)!=count || len(desc.piece_clusters)!=0 && len(desc.piece_clusters)!=count ||
       len(desc.connection_strength)!=0 && len(desc.connection_strength)!=len(source.connections) ||
       len(desc.clusters)>0 && len(desc.piece_clusters)!=count {return false}
    for cluster,at in desc.clusters {
        if cluster.parent < -1 || int(cluster.parent)>=at || !(cluster.strength>0) || !destruct_finite(cluster.strength) {return false}
        if u64(cluster.first_point)+u64(cluster.point_count)>u64(len(desc.cluster_points)) || cluster.point_count>0 && cluster.point_count<4 {return false}
        represented:=false
        for parent in desc.piece_clusters {
            if parent < -1 || int(parent)>=len(desc.clusters) {return false}
            for ancestor:=parent;ancestor>=0;ancestor=desc.clusters[ancestor].parent {
                if ancestor==i32(at) {represented=true;break}
            }
        }
        if !represented {return false}
    }
    for cluster in desc.piece_clusters {if cluster < -1 || int(cluster)>=len(desc.clusters) {return false}}
    for point in desc.cluster_points {if !destruct_finite(point.x,point.y,point.z) {return false}}
    for piece in source.pieces {
        if u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.positions)) || u64(piece.first_index)+u64(piece.index_count)>u64(len(source.mesh.indices)) {return false}
        if u64(piece.first_index/3)+u64(piece.index_count/3)>u64(len(source.mesh.materials)) ||
           len(source.mesh.normals)>0 && u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.normals)) ||
           len(source.mesh.uvs)>0 && u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.uvs)) ||
           len(source.mesh.colors)>0 && u64(piece.first_vertex)+u64(piece.vertex_count)>u64(len(source.mesh.colors)) {return false}
        for point in source.mesh.positions[piece.first_vertex:][:piece.vertex_count] {if !destruct_finite(point.x,point.y,point.z) {return false}}
        for index in source.mesh.indices[piece.first_index:][:piece.index_count] {if index>=piece.vertex_count {return false}}
    }
    for connection in source.connections {if connection.a>=connection.b || int(connection.b)>=count || !(connection.area>0) || !destruct_finite(connection.area) {return false}}
    for strength in desc.connection_strength {if strength<0 || !destruct_finite(strength) {return false}}
    return true
}

@(private)
destruct_cluster_common :: proc "contextless" (clusters:[]Cluster_Desc,a,b:i32) -> i32 {
    left,right:=a,b
    for left>=0 && right>=0 && left!=right {
        if left>right {left=clusters[left].parent} else {right=clusters[right].parent}
    }
    return left==right?left:-1
}

destructible_strain :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,point:Vec3,radius,amount:f32,impulse:Vec3={}) -> (event:Fracture_Event,broke:bool) {
    d,index:=destructible_get(f,h)
    if d==nil {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=-1,point=point,vector=impulse,radius=radius,kind=.Damage,strain=amount,falloff=.Linear}
    broke,_=fracture_damage(f,w,index,&event)
    return
}

destructible_strain_body :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,piece:i32,point:Vec3,radius,amount:f32,impulse:Vec3={}) -> (event:Fracture_Event,broke,strained:bool) {
    d,index:=destructible_get(f,h)
    if d==nil || piece_body(f,w,index,piece)=={} {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=piece,point=point,vector=impulse,radius=radius,kind=.Damage,strain=amount,falloff=.Linear}
    broke,strained=fracture_damage(f,w,index,&event)
    return
}

destructible_weaken :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,point:Vec3,radius,amount:f32) -> (event:Fracture_Event,strained:bool) {
    d,index:=destructible_get(f,h)
    if d==nil {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=-1,point=point,radius=radius,kind=.Weaken,strain=amount,falloff=.Linear}
    _,strained=fracture_damage(f,w,index,&event)
    return
}

destructible_weaken_body :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,piece:i32,point:Vec3,radius,amount:f32) -> (event:Fracture_Event,strained:bool) {
    d,index:=destructible_get(f,h)
    if d==nil || piece_body(f,w,index,piece)=={} {return}
    f.tick=sim.world_tick(w)
    event={destructible=h,tick=u32(f.tick),piece=piece,point=point,radius=radius,kind=.Weaken,strain=amount,falloff=.Linear}
    _,strained=fracture_damage(f,w,index,&event)
    return
}

@(private)
destruct_clusters_damage :: proc(f:^Fracture,w:^sim.World,index:i32,event:^Fracture_Event,only:Body_Handle) -> (broke,strained:bool) {
    d:=&f.destructibles[index]
    count:=0
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        if .Cluster in f.connections[slot].flags {f.scratch.ids[count]=u32(slot);count+=1}
    }
    #reverse for encoded in f.scratch.ids[:count] {
        slot:=i32(encoded)
        c:=&f.connections[slot]
        if .Broken in c.flags || c.cluster>=0 && .Broken not_in f.connections[c.cluster].flags {continue}
        weight:f32
        for piece_slot:=d.piece_list;piece_slot>=0;piece_slot=f.pieces[piece_slot].next {
            piece:=&f.pieces[piece_slot]
            body:=sim.shape_body(w,piece.shape)
            if body=={} || event.piece>=0 && body!=only {continue}
            belongs:=false
            for ancestor:=piece.cluster;ancestor>=0;ancestor=f.connections[ancestor].cluster {
                if ancestor==slot {belongs=true;break}
            }
            if belongs {weight=max(weight,destruct_region_weight(event,xf_point(sim.body_transform(w,body),piece.center)))}
        }
        if weight<=0 {continue}
        c.strain=min(max(f32),c.strain+event.strain*weight)
        strained=true
        if event.kind==.Weaken || c.strain<c.strength {continue}
        c.flags+={.Broken}
        d.revision+=1
        broke=true
        for bond_slot:=d.connection_list;bond_slot>=0;bond_slot=f.connections[bond_slot].next {
            bond:=&f.connections[bond_slot]
            if .Cluster not_in bond.flags && bond.cluster==slot {bond.flags+={.Broken}}
        }
    }
    return
}

destructible_clusters :: proc(f:^Fracture,h:Destructible_Handle,out:[]Cluster_Info) -> int {
    d,_:=destructible_get(f,h)
    if d==nil {return 0}
    count:=0
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if .Cluster not_in c.flags {continue}
        if count<len(out) {
            parent,at:i32=-1,0
            for before:=d.connection_list;before>=0 && before!=slot;before=f.connections[before].next {
                if .Cluster not_in f.connections[before].flags {continue}
                if before==c.cluster {parent=at}
                at+=1
            }
            out[count]={parent,c.strength,c.strain,.Broken in c.flags}
        }
        count+=1
    }
    return count
}

@(private)
destruct_remove_body :: proc(f:^Fracture,w:^sim.World,index,piece_slot:i32) -> bool {
    body:=piece_body(f,w,index,piece_slot)
    if body=={} || f.pieces[piece_slot].group==0 {return false}
    cosmetic:=.Debris in f.pieces[piece_slot].flags
    d:=&f.destructibles[index]
    destruct_bodies(f,w,d)
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        if f.scratch.body[slot]==body {piece_remove(f,w,slot)}
    }
    if cosmetic {return true}
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        if .Cluster not_in c.flags && (f.pieces[c.a].shape=={} || f.pieces[c.b].shape=={}) {c.flags+={.Broken}}
    }
    return true
}
