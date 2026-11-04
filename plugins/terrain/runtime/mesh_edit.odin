package terrain

import "core:math/linalg"
import "mirai:std/geom"
import mm "mirai:std/math"

@(private)
mesh_work_ready :: proc(s:^Source) {
    if s.mesh_work.ready {return}
    geom.mesh_buffer_init(&s.mesh_work.input,s.allocator)
    geom.mesh_buffer_init(&s.mesh_work.output,s.allocator)
    geom.mesh_buffer_init(&s.mesh_work.cutter,s.allocator)
    geom.mesh_surface_workspace_init(&s.mesh_work.surface,s.allocator)
    s.mesh_work.ready=true
}

@(private)
mesh_selection :: proc(s:^Source) -> (selected:[]bool,ok:bool) {
    if len(s.mesh_work.selected)!=len(s.mesh_chunks) {
        values,error:=make([]bool,len(s.mesh_chunks),s.allocator)
        if error!=nil {return}
        delete(s.mesh_work.selected,s.allocator);s.mesh_work.selected=values
    }
    for &value in s.mesh_work.selected {value=false}
    return s.mesh_work.selected,true
}

@(private)
mesh_box_overlap :: proc(a_low,a_high,b_low,b_high:[3]f32) -> bool {
    for axis in 0..<3 {if a_low[axis]>b_high[axis] || a_high[axis]<b_low[axis] {return false}}
    return true
}

@(private)
mesh_mark_halo :: proc(s:^Source,previous:[]Mesh_Chunk,changed:[]bool) {
    for dirty,i in changed {
        if !dirty {continue}
        low,high:=s.mesh_chunks[i].low,s.mesh_chunks[i].high
        for axis in 0..<3 {low[axis]=min(low[axis],previous[i].low[axis]);high[axis]=max(high[axis],previous[i].high[axis])}
        for &neighbor,j in s.mesh_chunks {if len(neighbor.geometry.indices)>0 && mesh_box_overlap(low,high,neighbor.low,neighbor.high) {s.mesh_changed[j]=true}}
    }
}

@(private)
mesh_repartition :: proc(s:^Source,output:geom.Mesh,selected:[]bool,vertex_budget:int,baseline:^Source=nil) -> (change:Change) {
    change.mesh=true
    total:=len(output.indices)/3
    for &chunk,i in s.mesh_chunks {if !selected[i] {total+=len(chunk.geometry.indices)/3}}
    if total>MESH_TRIANGLES_MAX {change.error=.Budget;return}
    if len(s.mesh_work.partition)!=len(s.mesh_chunks) {
        next,error:=make([]Mesh_Chunk,len(s.mesh_chunks),s.allocator)
        if error!=nil {change.error=.Out_Of_Memory;return}
        for &chunk in s.mesh_work.partition {mesh_chunk_release(&chunk)}
        delete(s.mesh_work.partition,s.allocator);s.mesh_work.partition=next
        for &chunk in s.mesh_work.partition {geom.mesh_buffer_init(&chunk.geometry,s.allocator)}
    }
    next:=s.mesh_work.partition
    for &chunk,i in next {chunk.revision=s.mesh_chunks[i].revision}
    if !mesh_partition(s,output,next) {change.error=.Out_Of_Memory;return}
    for &chunk,i in next {
        if !selected[i] && len(chunk.geometry.indices)>0 {
            original:=baseline!=nil?&baseline.mesh_chunks[i]:&s.mesh_chunks[i]
            if !mesh_append(&chunk.geometry,geom.mesh_buffer_view(&original.geometry)) {change.error=.Out_Of_Memory;return}
            chunk.low,chunk.high=geom.mesh_bounds(chunk.geometry.positions[:])
        }
    }
    vertices:=0
    for &chunk,i in next {vertices+= !selected[i] && len(chunk.geometry.indices)==0?len(s.mesh_chunks[i].geometry.positions):len(chunk.geometry.positions)}
    if vertices>vertex_budget {change.error=.Budget;return}
    for &chunk,i in next {
        old:=&s.mesh_chunks[i]
        if !selected[i] && len(chunk.geometry.indices)==0 || mesh_equal(&chunk.geometry,&old.geometry) {continue}
        chunk.revision,chunk.altered=old.revision+1,true
        old^,chunk=chunk,old^
        // The geometry it had, shared with a copy, stays the copy's.
        mesh_chunk_alone(&chunk,s.allocator)
        s.mesh_changed[i]=true
        change.changed=true
    }
    copy(selected,s.mesh_changed)
    mesh_mark_halo(s,next,selected)
    return
}

source_mesh_boolean :: proc(s:^Source,operand:geom.Mesh,op:geom.Boolean_Op,vertex_budget:int=MESH_TRIANGLES_MAX*3) -> (change:Change) {
    change.mesh=true
    if s.kind!=.Mesh || !source_valid(s.info) || !mesh_input_valid(operand) {change.error=.Invalid;return}
    for material in operand.materials {if int(material)>len(s.slots) {change.error=.Invalid;return}}
    for &dirty in s.mesh_changed {dirty=false}
    mesh_work_ready(s)
    if !source_mesh_collect(s,&s.mesh_work.input) {change.error=.Out_Of_Memory;return}
    error:=geom.mesh_boolean(geom.mesh_buffer_view(&s.mesh_work.input),operand,op,&s.mesh_work.output)
    switch error {
    case .None:
    case .Not_Closed,.No_Volume:change.error=.Not_Closed;return
    case .Out_Of_Memory:change.error=.Out_Of_Memory;return
    case .Capacity:change.error=.Budget;return
    case .Topology:change.error=.Topology;return
    case .Invalid_Mesh,.Invalid_Settings:change.error=.Invalid;return
    }
    selected,allocated:=mesh_selection(s)
    if !allocated {change.error=.Out_Of_Memory;return}
    for &value in selected {value=true}
    return mesh_repartition(s,geom.mesh_buffer_view(&s.mesh_work.output),selected,vertex_budget)
}

@(private)
source_mesh_edit :: proc(s:^Source,brush:Brush,vertex_budget:int,baseline:^Source) -> (change:Change) {
    change.mesh=true
    box:=(brush.kind==.Union || brush.kind==.Subtract) && brush.shape==.Box
    if !source_valid(s.info) || len(s.mesh_changed)!=len(s.mesh_chunks) || !(brush.radius>0 || box) || !(brush.amount>0) || brush.radius-brush.radius!=0 || brush.amount-brush.amount!=0 || brush.target-brush.target!=0 {change.error=.Invalid;return}
    for value in brush.center {if value-value!=0 {change.error=.Invalid;return}}
    for value in brush.normal {if value-value!=0 {change.error=.Invalid;return}}
    for value in brush.delta {if value-value!=0 || abs(value)>HEIGHT_LIMIT*2 {change.error=.Invalid;return}}
    for value in ([4]f32{brush.rotation.x,brush.rotation.y,brush.rotation.z,brush.rotation.w}) {if value-value!=0 || abs(value)>1 {change.error=.Invalid;return}}
    original:=s
    if brush.kind==.Grab {
        if baseline==nil || baseline==s || baseline.info!=s.info || len(baseline.mesh_chunks)!=len(s.mesh_chunks) {change.error=.Invalid;return}
        original=baseline
    }
    if brush.kind==.Grow && (!(brush.max_edge>0) || brush.max_edge-brush.max_edge!=0) {change.error=.Invalid;return}
    for &dirty in s.mesh_changed {dirty=false}
    mesh_work_ready(s)
    if brush.kind==.Union || brush.kind==.Subtract {
        cutter:=&s.mesh_work.cutter
        geom.mesh_buffer_clear(cutter)
        if reserve(&cutter.positions,256)!=nil || reserve(&cutter.normals,256)!=nil || reserve(&cutter.uvs,256)!=nil || reserve(&cutter.indices,1024)!=nil {change.error=.Out_Of_Memory;return}
        length:=linalg.length(brush.delta)
        turn,middle:=quaternion128(1),brush.center
        switch brush.shape {
        case .Sphere: geom.sphere_build(cutter,brush.radius,16,8)
        case .Capsule:
            if length>0 {geom.capsule_build(cutter,brush.radius,length+2*brush.radius,16,4);turn=mm.quat_between([3]f32{0,1,0},brush.delta/length);middle+=brush.delta*0.5} else {geom.sphere_build(cutter,brush.radius,16,8)}
        case .Box:
            if !(brush.extent.x>0 && brush.extent.y>0 && brush.extent.z>0) {change.error=.Invalid;return}
            geom.cube_build(cutter,brush.extent*2)
            if brush.rotation!=0 {turn=brush.rotation}
        }
        for &p in cutter.positions {p=mm.quat_rotate(turn,p)+middle}
        for &n in cutter.normals {n=mm.quat_rotate(turn,n)}
        return source_mesh_boolean(s,geom.mesh_buffer_view(cutter),brush.kind==.Union?geom.Boolean_Op.Union:geom.Boolean_Op.Subtract,vertex_budget)
    }
    if brush.kind==.Add || brush.kind==.Remove || brush.kind==.Ramp || brush.kind==.Terrace || brush.kind==.Noise || brush.kind==.Erode {change.error=.Invalid;return}
    selected,allocated:=mesh_selection(s)
    if !allocated {change.error=.Out_Of_Memory;return}
    low,high:[3]f32
    found:=false
    for &chunk,i in original.mesh_chunks {
        if len(chunk.geometry.indices)==0 || !mesh_box_sphere(chunk.low,chunk.high,brush.center,brush.radius) {continue}
        selected[i]=true
        if !found {low,high=chunk.low,chunk.high;found=true} else {for axis in 0..<3 {low[axis]=min(low[axis],chunk.low[axis]);high[axis]=max(high[axis],chunk.high[axis])}}
    }
    if !found {return}
    for &chunk,i in original.mesh_chunks {
        if len(chunk.geometry.indices)>0 && mesh_box_overlap(low,high,chunk.low,chunk.high) {selected[i]=true}
        if brush.kind==.Grab && s.mesh_chunks[i].revision!=chunk.revision {selected[i]=true}
    }
    geom.mesh_buffer_clear(&s.mesh_work.input)
    for &chunk,i in original.mesh_chunks {if selected[i] && !mesh_append(&s.mesh_work.input,geom.mesh_buffer_view(&chunk.geometry)) {change.error=.Out_Of_Memory;return}}
    result:geom.Mesh_Surface_Result
    operation_error:geom.Mesh_Surface_Error
    if brush.kind==.Grow {
        distance:=linalg.length(brush.delta)
        if distance==0 {return}
        refined:=false
        for phase in 0..<2 {
            for pass in 0..<16 {
                result,operation_error=geom.mesh_surface_refine(&s.mesh_work.surface,geom.mesh_buffer_view(&s.mesh_work.input),{center=brush.center+brush.delta*0.5,radius=brush.radius+distance*0.5,max_edge_length=brush.max_edge,max_triangles=min(MESH_TRIANGLES_MAX,clamp(vertex_budget,0,MESH_TRIANGLES_MAX)*2)},&s.mesh_work.output)
                if operation_error!=.None {break}
                s.mesh_work.input,s.mesh_work.output=s.mesh_work.output,s.mesh_work.input
                if !result.changed {break}
                refined=true
                if pass==15 {operation_error=.Budget_Exceeded}
            }
            if operation_error!=.None {break}
            if phase==0 {
                result,operation_error=geom.mesh_surface_edit(&s.mesh_work.surface,geom.mesh_buffer_view(&s.mesh_work.input),{kind=.Drag,center=brush.center,rotation=brush.rotation,delta=brush.delta,radius=brush.radius,amount=1,hardness=0.5},&s.mesh_work.output)
                if operation_error!=.None {break}
                refined=refined || result.changed
                s.mesh_work.input,s.mesh_work.output=s.mesh_work.output,s.mesh_work.input
            }
        }
        result.changed=refined
        s.mesh_work.input,s.mesh_work.output=s.mesh_work.output,s.mesh_work.input
    } else if brush.kind==.Smooth {
        // Each pass reaches one ring further: as many as the box of the Smooth of a grid.
        passes:=clamp(int(brush.radius/s.cell*SMOOTH_REACH),1,SMOOTH_SAMPLES_MAX)
        changed:=false
        for pass in 0..<passes {
            result,operation_error=geom.mesh_surface_edit(&s.mesh_work.surface,geom.mesh_buffer_view(&s.mesh_work.input),{kind=.Smooth,center=brush.center,normal={0,1,0},radius=brush.radius,amount=min(brush.amount,1),hardness=brush.hardness,falloff=brush.falloff},&s.mesh_work.output)
            if operation_error!=.None {break}
            changed||=result.changed
            if pass<passes-1 {s.mesh_work.input,s.mesh_work.output=s.mesh_work.output,s.mesh_work.input}
        }
        result.changed=changed
    } else if brush.kind==.Refine {
        length:=brush.max_edge>0?brush.max_edge:s.cell
        result,operation_error=geom.mesh_surface_refine(&s.mesh_work.surface,geom.mesh_buffer_view(&s.mesh_work.input),{center=brush.center,radius=brush.radius,max_edge_length=length,max_triangles=MESH_TRIANGLES_MAX},&s.mesh_work.output)
    } else {
        normal:=linalg.normalize0(brush.normal)
        if normal=={} {normal={0,1,0}}
        desc:=geom.Mesh_Surface_Brush{center=brush.center,normal=normal,radius=brush.radius,amount=brush.amount,hardness=brush.hardness,falloff=brush.falloff}
        switch brush.kind {
        case .Raise:desc.kind=.Sculpt
        case .Lower:desc.kind=.Sculpt;desc.amount= -desc.amount
        case .Flatten:desc.kind=.Flatten;desc.amount=min(desc.amount,1);desc.center+=normal*(brush.target-linalg.dot(normal,desc.center))
        case .Grab:desc.kind=.Sculpt;desc.amount=linalg.length(brush.delta);desc.normal=desc.amount>0?brush.delta/desc.amount:[3]f32{0,1,0}
        case .Smooth,.Add,.Remove,.Refine,.Union,.Subtract,.Grow,.Paint,.Erase,.Hole,.Fill,.Ramp,.Terrace,.Noise,.Erode:change.error=.Invalid;return
        }
        result,operation_error=geom.mesh_surface_edit(&s.mesh_work.surface,geom.mesh_buffer_view(&s.mesh_work.input),desc,&s.mesh_work.output)
    }
    switch operation_error {
    case .None:
    case .Out_Of_Memory:change.error=.Out_Of_Memory;return
    case .Budget_Exceeded:change.error=.Budget;return
    case .Invalid_Mesh,.Invalid_Brush,.Aliased_Output:change.error=.Invalid;return
    }
    if !result.changed && brush.kind!=.Grab {return}
    return mesh_repartition(s,geom.mesh_buffer_view(&s.mesh_work.output),selected,vertex_budget,brush.kind==.Grab?baseline:nil)
}

