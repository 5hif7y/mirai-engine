package fracture

import "core:mem"
import "mirai:std/geom"
import sim "plugins:physics/runtime/sim"

// What a destructible has become, as data small enough to send: the cuts by their plane, the body and the
// flags of every piece, and every connection. No geometry: whoever reads it made the same destructible
// from the same description and repeats the cuts. Pieces and connections are named by their place in the
// lists of the destructible, which is the same wherever the same events were applied.

@(private) State_Header :: struct {pieces,connections,original,revision:u32}
@(private) State_Piece :: struct {remaining:u64,parent:i32,group:u32,flags:Piece_Flags,front:u32,normal:Vec3,offset:f32,cluster:i32,_:u32}
@(private) State_Connection :: struct {a,b:i32,flags:Connection_Flags,area,strain:f32,center:Vec3,strength:f32,cluster:i32}
#assert(size_of(State_Header)==16 && size_of(State_Piece)==48 && size_of(State_Connection)==40)

@(private)
cluster_ordinal :: proc(f:^Fracture,d:^Destructible,slot:i32) -> i32 {
    ordinal:i32
    for at:=d.connection_list;at>=0;at=f.connections[at].next {
        if .Cluster not_in f.connections[at].flags {continue}
        if at==slot {return ordinal}
        ordinal+=1
    }
    return -1
}

// Counts every group that left, every cut and every piece removed: whoever mirrors the pieces of the
// destructible looks at them again when it changes. Zero while it is as created.
destructible_revision :: proc(f:^Fracture,h:Destructible_Handle) -> u32 {
    d,_:=destructible_get(f,h)
    return d!=nil?d.revision:0
}

// Cuts the hull of a piece by a plane of its frame into two new pieces, the one in front first, which
// are not in the list of the destructible nor on a body yet. False, with nothing made, when a side has no
// volume or a capacity runs out.
@(private)
piece_cut :: proc(f:^Fracture,w:^sim.World,index,current:i32,n:Vec3,offset:f32,slicer:^geom.Slicer,buffers:^[3]geom.Mesh_Buffer,counts,indices:^[dynamic]u8) -> (halves:[2]i32,ok:bool) {
    halves={-1,-1}
    hull:=sim.hull_get(w,f.pieces[current].hull)
    if hull==nil {return}
    hull_to_mesh(hull,&buffers[0])
    result,error:=geom.mesh_slice(slicer,geom.mesh_buffer_view(&buffers[0]),geom.Plane{n,offset},&buffers[1],&buffers[2])
    if error!=.None || result.front.triangles==0 || result.back.triangles==0 {return}
    halves[0]=piece_build(f,w,index,buffers[1].positions[:],counts,indices)
    if halves[0]<0 {return}
    halves[1]=piece_build(f,w,index,buffers[2].positions[:],counts,indices)
    if halves[1]<0 {
        piece_release(f,halves[0])
        halves[0]=-1
        return
    }
    for half,k in halves {
        f.piece_origins[half]={source=-1,parent=current,plane=n,offset=offset,front=k==0}
        f.pieces[half].group=f.pieces[current].group
        f.pieces[half].expire=f.pieces[current].expire
        f.pieces[half].cluster=f.pieces[current].cluster
    }
    return halves,true
}

// Place of each piece in the list of its destructible, into the scratch.
@(private)
piece_ordinals :: proc(f:^Fracture,d:^Destructible) -> []i32 {
    ordinals:=f.scratch.parent
    ordinal:i32
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        ordinals[slot]=ordinal
        ordinal+=1
    }
    return ordinals
}

// Hash of what the destructible has become: the body and the flags of every piece and which connections
// are broken. Two worlds that applied the same events to equal destructibles give the same; strains and
// poses are left out, and so is whether a piece of debris expired, which each world decides.
destructible_check :: proc(f:^Fracture,h:Destructible_Handle) -> u32 {
    d,_:=destructible_get(f,h)
    if d==nil {return 0}
    mix :: #force_inline proc "contextless" (hash:^u32,value:u32) {hash^ = (hash^~value)*16777619}
    ordinals:=piece_ordinals(f,d)
    hash:=u32(2166136261)
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        piece:=&f.pieces[slot]
        flags:=piece.flags
        if .Debris in flags {flags-={.Gone}}
        mix(&hash,piece.group)
        mix(&hash,transmute(u32)flags)
    }
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        mix(&hash,.Cluster in c.flags?u32(cluster_ordinal(f,d,slot)):u32(ordinals[c.a])<<16|u32(ordinals[c.b]))
        mix(&hash,transmute(u32)c.flags)
    }
    return hash
}

// Bytes destructible_state_write needs now.
destructible_state_size :: proc(f:^Fracture,h:Destructible_Handle) -> int {
    d,_:=destructible_get(f,h)
    if d==nil {return 0}
    return size_of(State_Header)+int(d.piece_count)*size_of(State_Piece)+int(d.connection_count)*size_of(State_Connection)
}

// Writes what the destructible has become since it was created: its cuts, the body and the flags of
// every piece and the strain of every connection. Debris is written as gone, since it is of each world.
// Returns the bytes written; zero when `out` is too small.
destructible_state_write :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,out:[]u8) -> int {
    d,_:=destructible_get(f,h)
    size:=destructible_state_size(f,h)
    if d==nil || len(out)<size {return 0}
    f.tick=sim.world_tick(w)
    ordinals:=piece_ordinals(f,d)
    header:=State_Header{pieces=u32(d.piece_count),connections=u32(d.connection_count),revision=d.revision}
    at:=size_of(State_Header)
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        piece:=&f.pieces[slot]
        origin:=f.piece_origins[slot]
        remaining:=piece.expire==max(u64)?max(u64):piece.expire>f.tick?piece.expire-f.tick:0
        record:=State_Piece{remaining=remaining,parent=-1,group=piece.group,flags=piece.flags,front=u32(origin.front),normal=origin.plane,offset=origin.offset,cluster=cluster_ordinal(f,d,piece.cluster)}
        if origin.parent>=0 {record.parent=ordinals[origin.parent]} else {header.original+=1}
        if !sim.shape_valid(w,piece.shape) || .Debris in piece.flags {record.flags+={.Gone}}
        mem.copy(&out[at],&record,size_of(State_Piece))
        at+=size_of(State_Piece)
    }
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {
        c:=&f.connections[slot]
        record:=State_Connection{a=c.a>=0?ordinals[c.a]:-1,b=c.b>=0 && .Cluster not_in c.flags?ordinals[c.b]:-1,flags=c.flags,area=c.area,strain=c.strain,center=c.center,strength=c.strength,cluster=cluster_ordinal(f,d,c.cluster)}
        mem.copy(&out[at],&record,size_of(State_Connection))
        at+=size_of(State_Connection)
    }
    mem.copy(&out[0],&header,size_of(State_Header))
    return at
}

// Makes a destructible that is still as created what destructible_state_write described of another one
// made from the same description: the same cuts, pieces gone, bodies and strains. Every body starts in
// the frame of the destructible, at rest: whoever sent the state says where they are. False when the
// state is not of such a destructible or a capacity runs out; the destructible may then be half changed
// and is only good for destructible_destroy. A transaction that allocates.
destructible_state_apply :: proc(f:^Fracture,w:^sim.World,h:Destructible_Handle,state:[]u8) -> bool {
    d,index:=destructible_get(f,h)
    if d==nil || d.revision!=0 || len(state)<size_of(State_Header) {return false}
    header:State_Header
    mem.copy(&header,raw_data(state),size_of(State_Header))
    pieces,original,connections:=int(header.pieces),int(header.original),int(header.connections)
    if original!=int(d.piece_count) || pieces<original || (pieces-original)%2!=0 {return false}
    if len(state)<size_of(State_Header)+pieces*size_of(State_Piece)+connections*size_of(State_Connection) {return false}
    if int(f.piece_count)+pieces-original>len(f.pieces) || int(f.connection_count)-int(d.connection_count)+connections>len(f.connections) {
        f.stats.capacity_exhausted+=1
        return false
    }
    piece_record :: proc(state:[]u8,at:int) -> (record:State_Piece) {
        mem.copy(&record,&state[size_of(State_Header)+at*size_of(State_Piece)],size_of(State_Piece))
        return
    }
    connection_record :: proc(state:[]u8,pieces,at:int) -> (record:State_Connection) {
        mem.copy(&record,&state[size_of(State_Header)+pieces*size_of(State_Piece)+at*size_of(State_Connection)],size_of(State_Connection))
        return
    }
    s:=&f.scratch
    f.tick=sim.world_tick(w)
    // The clusters are those it was made with, which keep their hulls, and come before what they hold.
    standing,clusters:=0,0
    for slot:=d.connection_list;slot>=0;slot=f.connections[slot].next {standing+=int(.Cluster in f.connections[slot].flags)}
    for at in 0..<connections {
        record:=connection_record(state,pieces,at)
        is_cluster:=.Cluster in record.flags
        if record.a<0 || int(record.a)>=pieces || !is_cluster && (record.b<0 || int(record.b)>=pieces) || is_cluster && record.b!=-1 ||
           record.cluster < -1 || int(record.cluster)>=clusters || !destruct_finite(record.area,record.strain,record.strength,record.center.x,record.center.y,record.center.z) ||
           record.area<0 || record.strain<0 || record.strength<0 || is_cluster && (at!=clusters || clusters>=len(s.ids)) {return false}
        clusters+=int(is_cluster)
    }
    if clusters!=standing {return false}
    defer destruct_settle(f,w)
    slots:=s.source // the slot of the piece at each place of the list
    count:=0
    for slot:=d.piece_list;slot>=0;slot=f.pieces[slot].next {
        slots[count]=slot
        count+=1
    }
    if pieces>original {
        // The cuts take the pieces out of their clusters.
        destruct_bodies(f,w,d)
        if !destruct_collide(f,w,index,false) {return false}
        slicer:geom.Slicer
        buffers:[3]geom.Mesh_Buffer
        geom.slicer_init(&slicer,f.allocator)
        for &buffer in buffers {geom.mesh_buffer_init(&buffer,f.allocator)}
        counts:=make([dynamic]u8,f.allocator)
        indices:=make([dynamic]u8,f.allocator)
        defer {
            geom.slicer_destroy(&slicer)
            for &buffer in buffers {geom.mesh_buffer_destroy(&buffer)}
            delete(counts)
            delete(indices)
        }
        for at:=original;at<pieces;at+=2 {
            front,back:=piece_record(state,at),piece_record(state,at+1)
            if front.parent<0 || int(front.parent)>=at || back.parent!=front.parent || front.front==0 || back.front!=0 {return false}
            parent:=slots[front.parent]
            if !sim.shape_valid(w,f.pieces[parent].shape) {return false}
            halves:=piece_cut(f,w,index,parent,front.normal,front.offset,&slicer,&buffers,&counts,&indices) or_return
            piece_detach(f,w,parent)
            f.pieces[parent].flags+={.Gone}
            for half,k in halves {
                piece_append(f,d,half)
                if !piece_attach(f,w,half,d.body) {return false}
                slots[at+k]=half
            }
        }
    }
    // What is gone leaves, and every other piece goes to the body of its group.
    ids,made:=s.ids,s.made
    groups:=0
    first:=d.body
    for at in 0..<pieces {
        record:=piece_record(state,at)
        slot:=slots[at]
        piece:=&f.pieces[slot]
        piece.group=record.group
        piece.expire=record.remaining==max(u64)?max(u64):f.tick+min(record.remaining,max(u64)-f.tick)
        if .Gone in record.flags {
            s.body[slot]={}
            piece.flags+=record.flags&{.Gone,.Debris}
            continue
        }
        if !sim.shape_valid(w,piece.shape) {return false}
        s.body[slot]=first
        if record.group==0 {continue}
        to:Body_Handle
        for id,k in ids[:groups] {
            if id==record.group {to=made[k]}
        }
        if to=={} {
            xf:=sim.body_transform(w,d.body)
            desc:=sim.BODY_DESC_DEFAULT
            desc.gravity_scale=d.gravity_scale
            desc.position,desc.rotation,desc.user_data=xf.p,xf.q,d.user_data
            to=sim.body_create(w,desc)
            if to=={} {
                f.stats.capacity_exhausted+=1
                s.refused[index]+={.Bodies}
                return false
            }
            ids[groups],made[groups]=record.group,to
            groups+=1
        }
        s.body[slot]=to
    }
    phantoms:=s.cluster_body // the slot of the hull of each cluster, in order
    clusters=0
    for slot:=d.connection_list;slot>=0; {
        next:=f.connections[slot].next
        if .Cluster in f.connections[slot].flags {
            phantoms[clusters]=f.connections[slot].b
            clusters+=1
        }
        f.connections[slot]={next=f.connection_free}
        f.connection_free=slot
        f.connection_count-=1
        slot=next
    }
    d.connection_list,d.connection_tail,d.connection_count=-1,-1,0
    clusters=0
    for at in 0..<connections {
        record:=connection_record(state,pieces,at)
        is_cluster:=.Cluster in record.flags
        parent:=record.cluster>=0?i32(s.ids[record.cluster]):-1
        connection_append(f,d,{a=slots[record.a],b=is_cluster?phantoms[clusters]:slots[record.b],flags=record.flags,area=record.area,strain=record.strain,center=record.center,strength=record.strength,cluster=parent})
        if is_cluster {s.ids[clusters]=u32(d.connection_tail);clusters+=1}
    }
    for at in 0..<pieces {
        record:=piece_record(state,at)
        if record.cluster < -1 || int(record.cluster)>=clusters {return false}
        f.pieces[slots[at]].cluster=record.cluster>=0?i32(s.ids[record.cluster]):-1
    }
    d.revision=header.revision
    return destruct_collide(f,w,index,true)
}
