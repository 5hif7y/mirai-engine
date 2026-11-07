package editor

import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// asset.reload: the editor reads again asset files that something else
// changed on disk (a tool, a script, an import from the command line, another
// session), as it does after its own imports. The registry looks at them
// again and what is loaded from them is read again where it is: meshes,
// textures, materials, the prefabs and scenes Play spawns from, the documents
// of plugins, sounds, texts and interfaces. An asset with unsaved changes
// keeps them (asset.discard takes the file). The instances of a prefab placed
// in the document follow its file with prefab.refresh, which is an edit.

API_RELOAD :: 64

@(private)
RELOAD_SCHEMA :: `{"type":"object","properties":{"assets":{"type":"array","maxItems":64,"items":{"type":"string"},"description":"The files changed on disk, by their path under the asset folder (also one that is new or gone) or their id: each is read again; none looks at the whole asset folder again and reads what changed since the editor last looked"}},"additionalProperties":false}`

@(private)
Api_Reload_Params :: struct {
    assets:[API_RELOAD][API_PATH_BYTES]u8,
    count:int,
}

Api_Reload_Result :: struct {
    reloaded:[1]Api_Reload_Entry `mirai:"list,label=The files read again: what the editor had loaded from them now holds what they hold"`,
    removed:[1][API_PATH_BYTES]u8 `mirai:"text,list,label=Files that are gone: what uses them shows them missing"`,
    unsaved:[1][API_PATH_BYTES]u8 `mirai:"text,list,label=Of those named or with none of all: files with unsaved changes in the editor; they keep them and are not read again; asset.discard takes the file"`,
    stale:[1][API_PATH_BYTES]u8 `mirai:"text,list,label=Prefabs placed in the document whose instances are behind their file; prefab.refresh brings them up as an edit"`,
}
Api_Reload_Entry :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=Under the asset folder"`,
    asset:base.Asset_Id,
    kind:[32]u8 `mirai:"text"`,
}

// What assets_reload_disk did, in the temp allocator.
Reload_Report :: struct {
    reloaded:[dynamic]Reload_File,
    removed,unsaved,stale:[dynamic]string,
}
Reload_File :: struct {
    path:string,
    id:base.Asset_Id,
    kind:asset.Fourcc,
}

// Reads again what changed on disk: the files named (paths under the asset
// folder, each read again even when the registry already saw it change), or
// with none every file whose size or time is not what the registry last saw.
// refusal says why nothing was done.
assets_reload_disk :: proc(s:^Session,named:[]string) -> (report:Reload_Report,refusal:string) {
    a:=s.app.assets if s.app!=nil else nil
    if a==nil || a.indexed {return {},"The editor has no asset folder it can read again"}
    if watching(s) {return {},"A watcher reads the files of the host"}
    if s.mode!=.Edit {return {},"Stop Play or Simulate first"}
    if busy:=import_busy(s);busy!="" {return {},busy}
    r:=&a.registry
    report.reloaded=make([dynamic]Reload_File,context.temp_allocator)
    report.removed=make([dynamic]string,context.temp_allocator)
    report.unsaved=make([dynamic]string,context.temp_allocator)
    report.stale=make([dynamic]string,context.temp_allocator)

    Stamp :: struct {path:string,size,time:i64}
    before:=make(map[base.Asset_Id]Stamp,context.temp_allocator)
    for &file in r.files {
        if file.state==.Asset {before[file.id]={strings.clone(file.path,context.temp_allocator),file.size,file.time}}
    }
    wanted:=make(map[string]bool,context.temp_allocator)
    for path in named {wanted[strings.to_lower(path,context.temp_allocator)]=true}
    if len(named)==0 {host.assets_scan(a)} else {host.assets_refresh(a,named)}

    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for &file in r.files {
        if file.state!=.Asset {continue}
        seen[file.id]=true
        asked:=wanted[strings.to_lower(file.path,context.temp_allocator)]
        path:=strings.clone(file.path,context.temp_allocator)
        // The registry answers for it with what memory holds, whatever the disk has now.
        if _,unsaved:=asset.registry_memory_find(r,file.path);unsaved {
            if asked || len(named)==0 {append(&report.unsaved,path)}
            continue
        }
        old,had:=before[file.id]
        if !asked && had && old.size==file.size && old.time==file.time {continue}
        _=host.assets_reload(a,file.id)
        append(&report.reloaded,Reload_File{path,file.id,file.kind})
        if file.kind==asset.KIND_PREFAB && s.editor_world!=nil && prefabs_of(s)!=nil && prefab_stale(s,file.id) {append(&report.stale,path)}
    }
    for id,old in before {
        if seen[id] {continue}
        // What was loaded from it shows it missing.
        _=host.assets_reload(a,id)
        append(&report.removed,old.path)
    }
    if len(report.reloaded)+len(report.removed)>0 {
        host.content_refresh(s.app)
        if s.content!=nil {s.content.revision+=1}
    }
    return
}

@(private)
asset_reload_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="asset.reload",params_schema=RELOAD_SCHEMA,summary="Reads again asset files changed on disk outside the editor (a prefab or texture another tool wrote) so the scene and Play use what they hold now; unsaved changes stay.",result=Api_Reload_Result,writes_result=true,run=api_asset_reload})
}

@(private)
api_asset_reload :: proc(s:^Session,call:^api.Call) {
    p:Api_Reload_Params
    {
        args:Rpc_Args
        rpc_init(&args,call,call.raw)
        o:Rpc_Object
        if !rpc_object_begin(&args,"params") {return}
        for key in rpc_next(&args,&o) {
            switch key {
            case "assets":
                if !serial.text_accept(&args.r,'[') {rpc_fail(&args,"assets must be an array of paths or ids");return}
                for i:=0;!serial.text_accept(&args.r,']');i+=1 {
                    if i>0 && !serial.text_accept(&args.r,',') {rpc_fail(&args,"assets must be an array of paths or ids");return}
                    if p.count>=len(p.assets) {rpc_fail(&args,"assets takes at most %d entries; none looks at the whole asset folder",len(p.assets));return}
                    rpc_text(&args,"a path or an id",p.assets[p.count][:len(p.assets[0])-1])
                    p.count+=1
                }
            case: rpc_fail(&args,"%s is not a parameter: assets",key);return
            }
        }
        if args.failed {return}
    }
    a:=s.app.assets if s.app!=nil else nil
    if a==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no asset folder it can read again")
        return
    }
    r:=&a.registry
    named:=make([dynamic]string,context.temp_allocator)
    for &entry in p.assets[:p.count] {
        name:=base.text_get(entry[:])
        if name=="" {continue}
        path:=name
        if id,is_id:=serial.text_parse_asset_id(name);is_id {
            file,found:=asset.registry_find(r,id)
            if !found {
                api.call_failf(call,api.INVALID_PARAMS,"No asset has the id %s: name a file that is new by its path",name)
                return
            }
            path=file.path
        } else if filepath.is_abs(name) {
            relative,inside:=asset.registry_relative(r,name)
            if !inside {
                api.call_failf(call,api.INVALID_PARAMS,"%q is not under the asset folder",name)
                return
            }
            path=relative
        }
        append(&named,strings.clone(strings.trim_prefix(path,"/"),context.temp_allocator))
    }
    report,refusal:=assets_reload_disk(s,named[:])
    if refusal!="" {
        api.call_fail(call,api.INVALID_PARAMS,refusal)
        return
    }
    w:=call.out
    serial.text_write_raw(w,`{"reloaded":[`)
    buffer:[base.ASSET_ID_TEXT]u8
    for file,i in report.reloaded {
        if i>0 {serial.write_u8(w,',')}
        serial.text_write_raw(w,`{"path":`);serial.text_write_string(w,file.path)
        api.write_key(w,"asset");serial.text_write_string(w,base.asset_id_format(file.id,buffer[:]))
        kind:="other"
        if info,known:=asset.kind_info(file.kind);known {kind=info.name}
        api.write_key(w,"kind");serial.text_write_string(w,kind)
        serial.write_u8(w,'}')
    }
    lists:=[3]struct{key:string,paths:[]string}{{"removed",report.removed[:]},{"unsaved",report.unsaved[:]},{"stale",report.stale[:]}}
    for list in lists {
        serial.text_write_raw(w,`],"`);serial.text_write_raw(w,list.key);serial.text_write_raw(w,`":[`)
        for path,i in list.paths {
            if i>0 {serial.write_u8(w,',')}
            serial.text_write_string(w,path)
        }
    }
    serial.text_write_raw(w,`]}`)
}
