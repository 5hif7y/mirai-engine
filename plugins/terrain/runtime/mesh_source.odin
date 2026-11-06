package terrain

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

MESH_TRIANGLES_MAX :: 2*1024*1024

source_cost :: proc(s:^Source) -> int {
    if s.kind==.Heightfield {return grid_dense(&s.heights)+grid_dense(&s.coarse.heights)}
    if s.kind==.Volume {return grid_dense(&s.distances)+grid_dense(&s.weights)}
    result:=0
    for &chunk in s.mesh_chunks {result+=len(chunk.geometry.positions)}
    return result
}

// A section of a Mesh source. Its geometry is shared with the copies of the
// source (mesh_chunk_share) and never written while it is: an edit puts new
// geometry in its place.
Mesh_Chunk :: struct {
    geometry:geom.Mesh_Buffer,
    hold:^Mesh_Hold, // of the geometry while copies may share it; nil: one holds it
    low,high:[3]f32,
    revision:u32,
    altered:bool, // as a page of a grid (Page.altered)
}

// How many sections hold one geometry, atomic as the pages of a grid
// (Shared), and the allocator of the hold.
@(private)
Mesh_Hold :: struct {
    holders:i32,
    allocator:runtime.Allocator,
}

// dst holds the geometry of src, letting go of its own. False without memory
// for the hold, dst as it was.
@(private)
mesh_chunk_share :: proc(dst,src:^Mesh_Chunk,allocator:runtime.Allocator) -> bool {
    if dst.hold==nil || dst.hold!=src.hold {
        if src.hold==nil {
            hold,error:=new(Mesh_Hold,allocator)
            if error!=nil {return false}
            hold^={holders=1,allocator=allocator}
            src.hold=hold
        }
        intrinsics.atomic_add(&src.hold.holders,1)
        mesh_chunk_release(dst)
        dst.geometry,dst.hold=src.geometry,src.hold
    }
    dst.low,dst.high,dst.revision,dst.altered=src.low,src.high,src.revision,src.altered
    return true
}

// A section lets go of its geometry: the last holder frees it.
@(private)
mesh_chunk_release :: proc(chunk:^Mesh_Chunk) {
    if chunk.hold!=nil {
        last:=intrinsics.atomic_sub(&chunk.hold.holders,1)==1
        if last {free(chunk.hold,chunk.hold.allocator)}
        chunk.hold=nil
        if !last {chunk.geometry={};return}
    }
    geom.mesh_buffer_destroy(&chunk.geometry)
}

// Gives a section geometry no copy holds, so it can be written: its own when
// it holds it alone, otherwise an empty one.
@(private)
mesh_chunk_alone :: proc(chunk:^Mesh_Chunk,allocator:runtime.Allocator) {
    if chunk.hold==nil || intrinsics.atomic_load(&chunk.hold.holders)==1 {return}
    mesh_chunk_release(chunk)
    geom.mesh_buffer_init(&chunk.geometry,allocator)
}

Mesh_Work :: struct {
    input,output,cutter:geom.Mesh_Buffer,
    surface:geom.Mesh_Surface_Workspace,
    partition:[]Mesh_Chunk,
    maps:[]map[u32]u32,
    selected:[]bool,
    ready:bool,
}

@(private)
Mesh_Chunk_Record :: struct {first_vertex,vertices,first_index,indices,revision:u32}

@(private)
source_mesh_destroy :: proc(s:^Source) {
    for &chunk in s.mesh_chunks {mesh_chunk_release(&chunk)}
    delete(s.mesh_chunks,s.allocator);delete(s.mesh_changed,s.allocator);delete(s.slots,s.allocator)
    geom.mesh_buffer_destroy(&s.mesh_work.input);geom.mesh_buffer_destroy(&s.mesh_work.output);geom.mesh_buffer_destroy(&s.mesh_work.cutter)
    geom.mesh_surface_workspace_destroy(&s.mesh_work.surface)
    for &chunk in s.mesh_work.partition {mesh_chunk_release(&chunk)}
    for &mapping in s.mesh_work.maps {delete(mapping)}
    delete(s.mesh_work.partition,s.allocator);delete(s.mesh_work.maps,s.allocator);delete(s.mesh_work.selected,s.allocator)
}

@(private)
mesh_copy :: proc(dst:^geom.Mesh_Buffer,src:geom.Mesh) -> bool {
    if resize(&dst.positions,len(src.positions))!=nil || resize(&dst.normals,len(src.normals))!=nil || resize(&dst.uvs,len(src.uvs))!=nil || resize(&dst.colors,len(src.colors))!=nil || resize(&dst.indices,len(src.indices))!=nil || resize(&dst.materials,len(src.materials))!=nil {return false}
    copy(dst.positions[:],src.positions);copy(dst.normals[:],src.normals);copy(dst.uvs[:],src.uvs);copy(dst.colors[:],src.colors);copy(dst.indices[:],src.indices);copy(dst.materials[:],src.materials)
    return true
}

@(private)
mesh_equal :: proc(a,b:^geom.Mesh_Buffer) -> bool {
    if len(a.positions)!=len(b.positions) || len(a.indices)!=len(b.indices) {return false}
    for value,i in a.positions {if value!=b.positions[i] || a.normals[i]!=b.normals[i] || a.uvs[i]!=b.uvs[i] || a.colors[i]!=b.colors[i] {return false}}
    for value,i in a.indices {if value!=b.indices[i] {return false}}
    for value,i in a.materials {if value!=b.materials[i] {return false}}
    return true
}

@(private)
source_mesh_allocate :: proc(s:^Source,info:Source_Info,allocator:runtime.Allocator) -> bool {
    if info.kind!=.Mesh || !source_valid(info) {return false}
    s.allocator,s.info=allocator,info
    counts:=chunk_counts(s);count:=counts.x*counts.y*counts.z
    error:runtime.Allocator_Error
    s.mesh_chunks,error=make([]Mesh_Chunk,count,allocator)
    if error!=nil {return false}
    s.mesh_changed,error=make([]bool,count,allocator)
    if error!=nil {return false}
    for &chunk in s.mesh_chunks {geom.mesh_buffer_init(&chunk.geometry,allocator)}
    return weights_init(s)
}

@(private)
source_mesh_clone :: proc(dst,src:^Source,allocator:runtime.Allocator) -> bool {
    temporary:Source
    defer source_destroy(&temporary)
    if !source_mesh_allocate(&temporary,src.info,allocator) || len(src.mesh_chunks)!=len(temporary.mesh_chunks) {return false}
    for &chunk,i in src.mesh_chunks {if !mesh_chunk_share(&temporary.mesh_chunks[i],&chunk,src.allocator) {return false}}
    error:runtime.Allocator_Error
    temporary.slots,error=make([]base.Asset_Id,len(src.slots),allocator)
    if error!=nil {return false}
    copy(temporary.slots,src.slots)
    if !grid_clone(&temporary.weights,&src.weights,allocator) {return false}
    temporary.origin=src.origin
    source_destroy(dst);dst^=temporary;temporary={}
    return true
}

@(private)
mesh_input_valid :: proc(mesh:geom.Mesh) -> bool {
    if !geom.mesh_is_valid(mesh) || len(mesh.indices)/3>MESH_TRIANGLES_MAX || len(mesh.positions)>MESH_TRIANGLES_MAX*3 {return false}
    for p in mesh.positions {for value in p {if value-value!=0 || abs(value)>HEIGHT_LIMIT {return false}}}
    for n in mesh.normals {for value in n {if value-value!=0 {return false}}}
    for uv in mesh.uvs {for value in uv {if value-value!=0 {return false}}}
    for color in mesh.colors {for value in color {if value-value!=0 {return false}}}
    return true
}

@(private)
mesh_append :: proc(dst:^geom.Mesh_Buffer,src:geom.Mesh) -> bool {
    first:=u32(len(dst.positions))
    if append(&dst.positions,..src.positions)!=len(src.positions) || append(&dst.normals,..src.normals)!=len(src.normals) || append(&dst.uvs,..src.uvs)!=len(src.uvs) || append(&dst.colors,..src.colors)!=len(src.colors) || append(&dst.materials,..src.materials)!=len(src.materials) {return false}
    start:=len(dst.indices)
    if resize(&dst.indices,start+len(src.indices))!=nil {return false}
    for index,i in src.indices {dst.indices[start+i]=index+first}
    return true
}

@(private)
mesh_slot :: proc(s:^Source,p:[3]f32) -> int {
    counts:=chunk_counts(s)
    size:=s.cell*f32(s.chunk_cells)
    x:=int(clamp(math.floor((p.x-s.mesh_origin.x)/size),0,f32(counts.x-1)))
    z:=int(clamp(math.floor((p.z-s.mesh_origin.z)/size),0,f32(counts.z-1)))
    return x+counts.x*z
}

@(private)
mesh_partition :: proc(s:^Source,mesh:geom.Mesh,out:[]Mesh_Chunk) -> bool {
    if !mesh_input_valid(mesh) {return false}
    if len(s.mesh_work.maps)!=len(out) {
        maps,error:=make([]map[u32]u32,len(out),s.allocator)
        if error!=nil {return false}
        for &mapping in s.mesh_work.maps {delete(mapping)}
        delete(s.mesh_work.maps,s.allocator)
        s.mesh_work.maps=maps
        for &mapping in s.mesh_work.maps {mapping=make(map[u32]u32,s.allocator)}
    }
    maps:=s.mesh_work.maps
    for &mapping in maps {clear(&mapping)}
    for &chunk in out {geom.mesh_buffer_clear(&chunk.geometry)}
    for t:=0;t<len(mesh.indices);t+=3 {
        center:=(mesh.positions[mesh.indices[t]]+mesh.positions[mesh.indices[t+1]]+mesh.positions[mesh.indices[t+2]])/3
        slot:=mesh_slot(s,center)
        origin:=chunk_origin(s,chunk_coord(s,slot))
        dst:=&out[slot].geometry
        if reserve(&maps[slot],len(maps[slot])+3)!=nil || reserve(&dst.positions,len(dst.positions)+3)!=nil || reserve(&dst.normals,len(dst.normals)+3)!=nil || reserve(&dst.uvs,len(dst.uvs)+3)!=nil || reserve(&dst.colors,len(dst.colors)+3)!=nil || reserve(&dst.indices,len(dst.indices)+3)!=nil || reserve(&dst.materials,len(dst.materials)+1)!=nil {return false}
        for corner in 0..<3 {
            index:=mesh.indices[t+corner]
            target,exists:=maps[slot][index]
            if !exists {
                target=u32(len(dst.positions));maps[slot][index]=target
                p:=mesh.positions[index]
                append(&dst.positions,p)
                append(&dst.normals,len(mesh.normals)>0?mesh.normals[index]:[3]f32{})
                append(&dst.uvs,len(mesh.uvs)>0?mesh.uvs[index]:chunk_turns(origin)+[2]f32{p.x-origin.x,p.z-origin.z}/UV_METERS)
                append(&dst.colors,len(mesh.colors)>0?mesh.colors[index]:[4]f32{1,1,1,1})
            }
            append(&dst.indices,target)
        }
        append(&dst.materials,len(mesh.materials)>0?mesh.materials[t/3]:0)
    }
    for &chunk in out {
        chunk.low,chunk.high=geom.mesh_bounds(chunk.geometry.positions[:])
        if len(mesh.normals)==0 {geom.mesh_compute_normals(chunk.geometry.positions[:],chunk.geometry.indices[:],chunk.geometry.normals[:])}
    }
    return true
}

// A Mesh source of a mesh and the materials of its slots, that of slot 0 its
// first layer.
source_from_mesh :: proc(dst:^Source,mesh:geom.Mesh,cell:f32,chunk_cells:int,materials:[]base.Asset_Id=nil,allocator:=context.allocator) -> bool {
    if !mesh_input_valid(mesh) || len(mesh.positions)==0 || !(cell>0) || cell-cell!=0 || chunk_cells<CHUNK_CELLS_MIN || chunk_cells>CHUNK_CELLS_MAX || len(materials)>asset.MESH_MAX_SLOTS {return false}
    low,high:=geom.mesh_bounds(mesh.positions)
    extent:=(high-low)/cell
    if extent.x>MESH_SAMPLES_MAX-1 || extent.z>MESH_SAMPLES_MAX-1 {return false}
    first:=LAYER_DEFAULT
    if len(materials)>0 {first.material=materials[0]}
    info:=Source_Info{kind=.Mesh,samples={u32(max(int(math.ceil(extent.x))+1,2)),1,u32(max(int(math.ceil(extent.z))+1,2))},cell=cell,chunk_cells=u32(chunk_cells),mesh_origin=low,layer_count=1,layers={0=first}}
    temporary:Source
    defer source_destroy(&temporary)
    if !source_mesh_allocate(&temporary,info,allocator) {return false}
    canonical:=mesh
    normals:[][3]f32
    defer delete(normals,allocator)
    if len(mesh.normals)==0 {
        allocation:runtime.Allocator_Error
        normals,allocation=make([][3]f32,len(mesh.positions),allocator)
        if allocation!=nil {return false}
        geom.mesh_compute_normals(mesh.positions,mesh.indices,normals)
        canonical.normals=normals
    }
    if !mesh_partition(&temporary,canonical,temporary.mesh_chunks) {return false}
    error:runtime.Allocator_Error
    temporary.slots,error=make([]base.Asset_Id,max(len(materials)-1,0),allocator)
    if error!=nil {return false}
    if len(materials)>1 {copy(temporary.slots,materials[1:])}
    for &chunk in temporary.mesh_chunks {for material in chunk.geometry.materials {if int(material)>len(temporary.slots) {return false}}}
    source_destroy(dst);dst^=temporary;temporary={}
    return true
}

source_mesh_collect :: proc(s:^Source,out:^geom.Mesh_Buffer) -> bool {
    geom.mesh_buffer_clear(out)
    for &chunk in s.mesh_chunks {if !mesh_append(out,geom.mesh_buffer_view(&chunk.geometry)) {return false}}
    return true
}

source_convert_heightfield :: proc(dst,src:^Source,depth:f32=0,allocator:=context.allocator) -> bool {
    if src.kind!=.Heightfield || !source_valid(src.info) || !source_samples_held(src) || depth<0 || depth-depth!=0 {return false}
    if src.samples.x>MESH_SAMPLES_MAX || src.samples.z>MESH_SAMPLES_MAX {return false}
    // A hole would open the solid: only an open surface keeps it.
    if depth>0 {for page in src.holes.pages {
        if page.fill!=0 {return false}
        for hole in page.values {if hole!=0 {return false}}
    }}
    mesh:geom.Mesh_Buffer;geom.mesh_buffer_init(&mesh,allocator);defer geom.mesh_buffer_destroy(&mesh)
    nx,nz:=int(src.samples.x),int(src.samples.z)
    vertices:=nx*nz
    sides:=2*(nx+nz)-4
    counts:=chunk_counts(src)
    bottom_faces:=2*((nx-1)*counts.z+(nz-1)*counts.x)
    triangles:=2*(nx-1)*(nz-1)+(depth>0?bottom_faces+sides*2:0)
    if triangles>MESH_TRIANGLES_MAX {return false}
    if resize(&mesh.positions,depth>0?vertices*2+counts.x*counts.z:vertices)!=nil || resize(&mesh.normals,len(mesh.positions))!=nil || reserve(&mesh.indices,triangles*3)!=nil {return false}
    minimum:=f32(HEIGHT_LIMIT)
    for z in 0..<nz {for x in 0..<nx {p:=source_point(src,{x,0,z});mesh.positions[x+nx*z]=p;minimum=min(minimum,p.y)}}
    for z in 0..<nz-1 {for x in 0..<nx-1 {if !source_hole(src,x,z) {a:=u32(x+nx*z);b:=a+u32(nx);append(&mesh.indices,a,b,a+1,a+1,b,b+1)}}}
    if depth>0 {
        bottom:=minimum-depth
        if bottom< -HEIGHT_LIMIT {return false}
        perimeter,error:=make([]u32,sides,allocator);if error!=nil {return false};defer delete(perimeter,allocator)
        at:=0
        for z in 0..<nz-1 {perimeter[at]=u32(z*nx);at+=1}
        for x in 0..<nx-1 {perimeter[at]=u32(x+(nz-1)*nx);at+=1}
        for z:=nz-1;z>0;z-=1 {perimeter[at]=u32(nx-1+z*nx);at+=1}
        for x:=nx-1;x>0;x-=1 {perimeter[at]=u32(x);at+=1}
        for i in 0..<vertices {p:=mesh.positions[i];p.y=bottom;mesh.positions[vertices+i]=p}
        for cz in 0..<counts.z {for cx in 0..<counts.x {
            x0,z0:=cx*int(src.chunk_cells),cz*int(src.chunk_cells)
            x1,z1:=min(x0+int(src.chunk_cells),nx-1),min(z0+int(src.chunk_cells),nz-1)
            center:=u32(vertices*2+cx+counts.x*cz)
            point:=(mesh.positions[x0+nx*z0]+mesh.positions[x1+nx*z1])*0.5
            point.y=bottom;mesh.positions[center]=point
            for z in z0..<z1 {a:=u32(vertices+x0+nx*z);append(&mesh.indices,center,a+u32(nx),a)}
            for x in x0..<x1 {a:=u32(vertices+x+nx*z1);append(&mesh.indices,center,a+1,a)}
            for z:=z1;z>z0;z-=1 {a:=u32(vertices+x1+nx*z);append(&mesh.indices,center,a-u32(nx),a)}
            for x:=x1;x>x0;x-=1 {a:=u32(vertices+x+nx*z0);append(&mesh.indices,center,a-1,a)}
        }}
        for a,i in perimeter {
            next:=(i+1)%sides;b:=perimeter[next];c,d:=a+u32(vertices),b+u32(vertices)
            append(&mesh.indices,b,a,c,b,c,d)
        }
    }
    geom.mesh_compute_normals(mesh.positions[:],mesh.indices[:],mesh.normals[:])
    revision:=src.revision
    layers:=src.info
    weights:Grid(Weights)
    if !grid_clone(&weights,&src.weights,allocator) {return false}
    first:=[1]base.Asset_Id{src.layers[0].material}
    if !source_from_mesh(dst,geom.mesh_buffer_view(&mesh),src.cell,int(src.chunk_cells),first[:],allocator) {grid_destroy(&weights,allocator);return false}
    dst.revision=revision
    // The grid of the mesh spans the same samples: it keeps the weights.
    if weights.size=={int(dst.samples.x),1,int(dst.samples.z)} {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        dst.layers=layers.layers
        dst.layer_count=layers.layer_count
        grid_destroy(&dst.weights,allocator)
        dst.weights=weights
    } else {grid_destroy(&weights,allocator)}
    return true
}

@(private)
mesh_box_sphere :: proc(low,high,center:[3]f32,radius:f32) -> bool {
    distance:=f32(0)
    for axis in 0..<3 {delta:=center[axis]-clamp(center[axis],low[axis],high[axis]);distance+=delta*delta}
    return distance<=radius*radius
}

@(private)
source_mesh_ray :: proc(s:^Source,origin,direction:[3]f32) -> (point,normal:[3]f32,ok:bool) {
    for value in origin {if value-value!=0 {return}}
    for value in direction {if value-value!=0 {return}}
    d:=linalg.normalize0(direction);if d=={} {return}
    best:=f32(1e30)
    for &chunk in s.mesh_chunks {
        if len(chunk.geometry.indices)==0 {continue}
        near,far:=f32(0),best
        for axis in 0..<3 {
            if abs(d[axis])<1e-9 {if origin[axis]<chunk.low[axis] || origin[axis]>chunk.high[axis] {far= -1;break}} else {
                a,b:=(chunk.low[axis]-origin[axis])/d[axis],(chunk.high[axis]-origin[axis])/d[axis]
                if a>b {a,b=b,a};near,far=max(near,a),min(far,b)
            }
        }
        if near>far {continue}
        m:=&chunk.geometry
        for t:=0;t<len(m.indices);t+=3 {
            face:=mm.Triangle{m.positions[m.indices[t]],m.positions[m.indices[t+1]],m.positions[m.indices[t+2]]}
            distance,_,hit:=mm.ray_triangle({origin,d},face)
            if hit && distance>=0 && distance<best {best=distance;normal=mm.triangle_normal(face);ok=true}
        }
    }
    if ok {point=origin+d*best}
    return
}

@(private)
source_mesh_load :: proc(s:^Source,file:^asset.Asset,info:Source_Info,types:^asset.Types,allocator:runtime.Allocator) -> (id:base.Asset_Id,ok:bool) {
    records,e0:=asset.asset_rows(file,types,"chunks","",Mesh_Chunk_Record)
    positions,e1:=asset.asset_rows(file,types,"positions","",[3]f32)
    normals,e2:=asset.asset_rows(file,types,"normals","",[3]f32)
    uvs,e3:=asset.asset_rows(file,types,"uvs","",[2]f32)
    colors,e4:=asset.asset_rows(file,types,"colors","",[4]f32)
    indices,e5:=asset.asset_rows(file,types,"indices","",u32)
    materials,e6:=asset.asset_rows(file,types,"face_materials","",u32)
    slots,e7:=asset.asset_rows(file,types,"slots","",base.Asset_Id)
    if e0!=.None || e1!=.None || e2!=.None || e3!=.None || e4!=.None || e5!=.None || e6!=.None || e7!=.None || !source_valid(info) || len(positions)!=len(normals) || len(positions)!=len(uvs) || len(positions)!=len(colors) || len(indices)%3!=0 || len(materials)!=len(indices)/3 || len(indices)/3>MESH_TRIANGLES_MAX || len(positions)>MESH_TRIANGLES_MAX*3 || len(slots)>=asset.MESH_MAX_SLOTS {return}
    temporary:Source;defer source_destroy(&temporary)
    if !source_mesh_allocate(&temporary,info,allocator) || len(records)!=len(temporary.mesh_chunks) {return}
    vertex,index:=0,0
    for record,i in records {
        if int(record.first_vertex)!=vertex || int(record.first_index)!=index || int(record.vertices)>len(positions)-vertex || int(record.indices)>len(indices)-index || record.indices%3!=0 {return}
        end_vertex,end_index:=vertex+int(record.vertices),index+int(record.indices)
        mesh:=geom.Mesh{positions=positions[vertex:end_vertex],normals=normals[vertex:end_vertex],uvs=uvs[vertex:end_vertex],colors=colors[vertex:end_vertex],indices=indices[index:end_index],materials=materials[index/3:end_index/3]}
        if !mesh_input_valid(mesh) {return}
        for material in mesh.materials {if int(material)>len(slots) {return}}
        chunk:=&temporary.mesh_chunks[i]
        if !mesh_copy(&chunk.geometry,mesh) {return}
        chunk.low,chunk.high=geom.mesh_bounds(mesh.positions);chunk.revision=record.revision
        vertex,index=end_vertex,end_index
    }
    if vertex!=len(positions) || index!=len(indices) {return}
    error:runtime.Allocator_Error
    temporary.slots,error=make([]base.Asset_Id,len(slots),allocator)
    if error!=nil {return}
    copy(temporary.slots,slots)
    if !source_weights_read(&temporary,file,types,allocator) {return}
    temporary.origin=file.blob.header.content_hash
    source_destroy(s);s^=temporary;temporary={}
    return file.blob.header.id,true
}

@(private)
source_mesh_bytes :: proc(s:^Source,id:base.Asset_Id,types:^asset.Types,allocator:runtime.Allocator,import_info:^asset.Import_Info=nil) -> (data:[]u8,error:asset.Error) {
    if !source_valid(s.info) || len(s.slots)>=asset.MESH_MAX_SLOTS {return nil,.Invalid}
    counts:=chunk_counts(s)
    if len(s.mesh_chunks)!=counts.x*counts.y*counts.z {return nil,.Invalid}
    mesh:geom.Mesh_Buffer;geom.mesh_buffer_init(&mesh,s.allocator);defer geom.mesh_buffer_destroy(&mesh)
    records,records_error:=make([]Mesh_Chunk_Record,len(s.mesh_chunks),s.allocator)
    if records_error!=nil {return nil,.Out_Of_Memory}
    defer delete(records,s.allocator)
    for &chunk,i in s.mesh_chunks {
        view:=geom.mesh_buffer_view(&chunk.geometry)
        if !mesh_input_valid(view) || len(view.normals)!=len(view.positions) || len(view.uvs)!=len(view.positions) || len(view.colors)!=len(view.positions) || len(view.materials)!=len(view.indices)/3 {return nil,.Invalid}
        for material in view.materials {if int(material)>len(s.slots) {return nil,.Invalid}}
        records[i]={u32(len(mesh.positions)),u32(len(view.positions)),u32(len(mesh.indices)),u32(len(view.indices)),chunk.revision}
        first:=len(mesh.indices)
        if !mesh_append(&mesh,view) {return nil,.Out_Of_Memory}
        if len(mesh.indices)/3>MESH_TRIANGLES_MAX || len(mesh.positions)>MESH_TRIANGLES_MAX*3 {return nil,.Invalid}
        copy(mesh.indices[first:],view.indices)
    }
    document:asset.Document;asset.document_init(&document,KIND,id,s.allocator);defer asset.document_destroy(&document)
    document.kind_version=VERSION
    info:=s.info
    asset.document_put_row(&document,types,"terrain",&info) or_return
    asset.document_put(&document,types,"chunks",records) or_return
    asset.document_put(&document,types,"positions",mesh.positions[:],{.Bulk},.LZ,asset.MESH_BULK_ALIGNMENT) or_return
    asset.document_put(&document,types,"normals",mesh.normals[:],{.Bulk},.LZ,asset.MESH_BULK_ALIGNMENT) or_return
    asset.document_put(&document,types,"uvs",mesh.uvs[:],{.Bulk},.LZ,asset.MESH_BULK_ALIGNMENT) or_return
    asset.document_put(&document,types,"colors",mesh.colors[:],{.Bulk},.LZ,asset.MESH_BULK_ALIGNMENT) or_return
    asset.document_put(&document,types,"indices",mesh.indices[:],{.Bulk},.LZ,asset.MESH_BULK_ALIGNMENT) or_return
    asset.document_put(&document,types,"face_materials",mesh.materials[:],{.Bulk},.LZ,asset.MESH_BULK_ALIGNMENT) or_return
    asset.document_put(&document,types,"slots",s.slots) or_return
    source_weights_put(&document,types,s) or_return
    asset.import_put(&document,types,import_info) or_return
    return asset.document_bytes(&document,allocator)
}
