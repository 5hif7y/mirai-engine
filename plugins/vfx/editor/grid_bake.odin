package vfx_editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/gridfile"

// particle.grid.bake: the cells of the grid of an entity of the edited world
// as its steps leave them, written as a .grid at path (one there already
// takes the new state) in one undo step. A Particle_Grid that names the file
// in cached starts from it.
@(private)
Api_Grid_Bake_Params :: struct {
    id:base.Entity_Id,
    path:[editor.API_PATH_BYTES]u8 `mirai:"text"`,
}

// A bake asked by particle.grid.bake: the file it writes when the cells
// come back from the GPU, frames later, in an editor frame.
Grid_Bake_Request :: struct {
    path:[editor.API_PATH_BYTES]u8, // of the file, in the project
    id:base.Asset_Id,
    frames:int,                     // waited
    active:bool,
}

@(private)
GRID_BAKE_FRAMES_MAX :: 30 // waited for the cells before the bake is given up

@(private)
api_grid_bake :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Grid_Bake_Params)
    a:=s.app.assets
    v:=vfx_editor_of(s)
    if a==nil || v==nil || !s.has_project || s.app.renderer==nil {
        api.call_fail(call,api.SERVER_ERROR,"particle.grid.bake needs a project and a GPU")
        return
    }
    w:=editor.edited_world(s)
    e:=editor.api_entity(w,p.id)
    if !editor.entity_has(w,e,vfx.Particle_Grid) {
        api.call_failf(call,api.INVALID_PARAMS,"id 0x%016x is not an entity with a Particle_Grid in the edited world",u64(p.id))
        return
    }
    named:=base.text_get(p.path[:])
    if named=="" {
        api.call_fail(call,api.INVALID_PARAMS,"path is required")
        return
    }
    path:=named if strings.has_suffix(named,gridfile.EXTENSION) else fmt.tprintf("%s%s",named,gridfile.EXTENSION)
    target:=editor.scene_file(s,path)
    if target=="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",path,editor.document_error_text(.Bad_Path))
        return
    }
    sync:=host.app_world_storage(s.app,s.edit_world,vfx.Particle_Sync)
    if sync==nil || !vfx.grid_bake_ask(sync,e) {
        // What the grids of the world said of it, when they refused it.
        if problem:=core.problem_find(host.app_world_storage(s.app,w.data,core.Problems),e,"vfx.grid");problem!=nil {
            api.call_failf(call,api.INVALID_PARAMS,"The grid is not drawn: %s",core.problem_text(problem))
            return
        }
        api.call_fail(call,api.INVALID_PARAMS,"The grid is not drawn yet: give it a valid name and cells, and let a frame draw it")
        return
    }
    id:=editor.asset_id_new(s)
    if file,found:=asset.registry_find_path(&a.registry,path);found && file.kind==gridfile.KIND {id=file.id}
    v.bake={id=id,active=true}
    base.text_set(v.bake.path[:],target)
    out:=call.out
    serial.write_u8(out,'{')
    api.write_key(out,"path",true)
    serial.text_write_string(out,path)
    api.write_key(out,"grid")
    serial.write_u8(out,'"')
    serial.text_write_asset_id(out,id)
    serial.write_u8(out,'"')
    api.write_bool(out,"pending",true)
    serial.write_u8(out,'}')
}

// The bake asked, written once its cells come back: a step of its own of the
// history of the project, as an edit of an asset is.
@(step="frame",after="editor_tools")
vfx_grid_bake :: proc(s:^editor.Session,v:^Vfx_Editor,app:^host.App) {
    if !v.bake.active {return}
    sync:=host.app_world_storage(app,s.edit_world,vfx.Particle_Sync)
    v.bake.frames+=1
    if sync==nil || v.bake.frames>GRID_BAKE_FRAMES_MAX {
        if sync!=nil {vfx.grid_bake_cancel(sync)}
        v.bake={}
        editor.notify(s,"The cells of the grid did not come back from the GPU; bake it again")
        return
    }
    info,cells,taken:=vfx.grid_bake_take(sync,app,host.app_world_id(app,s.edit_world),context.temp_allocator)
    if !taken {return}
    bytes,error:=gridfile.grid_bytes(&app.assets.types,{id=v.bake.id,info=info,cells=cells},context.temp_allocator)
    if error!=.None || !editor.file_write(s,base.text_get(v.bake.path[:]),bytes,"Bake grid") {editor.notify(s,"The state of the grid could not be written")}
    v.bake={}
}
