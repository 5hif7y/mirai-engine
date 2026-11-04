package importer

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"

// The assets an import writes that are not the outputs of a model: the scene
// of a level, the sources of plugins. They keep the files and ids an earlier
// import of their source gave them as import_write keeps those of a model
// (earlier.odin): the root by output_root, each other one by kind and name
// (then index) among what the earlier import of the source wrote. A new one
// gets a random id and a file of its own. Outputs does not move while it is
// open: its search keeps memory of its own.
Outputs :: struct {
    w:Writer,
    report:Import_Report,
    source:string, // the source as imports name it
    size,hash:u64,
    version:u32,
    scratch:mem.Dynamic_Arena, // the temp memory of the search
}

// Starts the outputs of an import of the file at source, whose bytes have
// size and hash, read by a writer of version (import_version). folder is
// where new outputs go unless output_part names another.
outputs_begin :: proc(o:^Outputs,source,folder:string,size,hash:u64,version:u32,options:Import_Options,allocator:=context.allocator) -> Error {
    o^={size=size,hash=hash,version=version}
    caller:=context.temp_allocator
    mem.dynamic_arena_init(&o.scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    report_init(&o.report,allocator)
    o.source=source_path(options,source)
    if !writer_init(&o.w,folder,options,&o.report,allocator) {
        error:=outputs_error(o,caller)
        outputs_end(o,true)
        return error
    }
    o.w.named=o.source
    return {}
}

// The error of the writer, its message in allocator.
@(private="file")
outputs_error :: proc(o:^Outputs,allocator:mem.Allocator) -> Error {
    return writer_error(&o.w,allocator)
}

// The file (in the temp allocator) and id of the root of the import: the earlier one of kind that
// names the source (or into, or the same bytes moved), else a new one in
// the folder. Outputs of the source found after it are those of that import.
output_root :: proc(o:^Outputs,kind:asset.Fourcc,name,extension:string) -> (id:base.Asset_Id,path:string,error:Error) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    at,ok:=earlier_root(&o.w,kind,o.source,o.size,o.hash)
    if !ok {return {},"",outputs_error(o,caller)}
    if at>=0 {
        e:=&o.w.earlier[at]
        e.taken=true
        o.w.named=strings.clone(base.text_get(e.info.source[:]),context.temp_allocator)
        return e.id,strings.clone(e.path,caller),{}
    }
    seen:=make(map[string]bool,context.temp_allocator)
    return writer_id(&o.w),strings.clone(fresh_path(&o.w,default_path(&o.w,&seen,name,extension)),caller),{}
}

// The file and id of another output of kind: the one the earlier import of
// the source wrote with that name (the same index first), else with that
// index, else a new one in folder ("": that of outputs_begin).
output_part :: proc(o:^Outputs,kind:asset.Fourcc,name:string,index:int,extension:string,folder:="") -> (id:base.Asset_Id,path:string) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    parts:=[1]Part{{kind=kind,name=name,index=index,extension=extension,earlier=-1,shared=-1}}
    if folder!="" {
        kept:=o.w.folder
        o.w.folder=folder
        defer o.w.folder=kept
        parts_plan(&o.w,parts[:])
    } else {
        parts_plan(&o.w,parts[:])
    }
    if parts[0].shared>=0 {parts[0].path=o.w.earlier[parts[0].shared].path}
    return parts[0].id,strings.clone(parts[0].path,caller)
}

// What the earlier imports outputs_begin found keep instead of building.
outputs_known :: proc(o:^Outputs,allocator:=context.allocator) -> Known {
    return known_make(o.w.earlier[:],allocator)
}

// The files and ids of other outputs of kind, by name, as output_part gives
// each: every name is looked for before any is given an earlier output by
// index. In the temp allocator.
output_parts :: proc(o:^Outputs,kind:asset.Fourcc,names:[]string,index:int,extension:string,folder:="") -> (ids:[]base.Asset_Id,paths:[]string) {
    caller:=context.temp_allocator
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    parts:=make([]Part,len(names),context.temp_allocator)
    for name,i in names {parts[i]={kind=kind,name=name,index=index,extension=extension,earlier=-1,shared=-1}}
    kept:=o.w.folder
    if folder!="" {o.w.folder=folder}
    parts_plan(&o.w,parts)
    o.w.folder=kept
    ids=make([]base.Asset_Id,len(parts),caller)
    paths=make([]string,len(parts),caller)
    for &p,i in parts {
        if p.shared>=0 {p.path=o.w.earlier[p.shared].path}
        ids[i],paths[i]=p.id,strings.clone(p.path,caller)
    }
    return
}

// The Import_Info of an output: the source, what of it the output is and
// the settings it is made from.
output_info :: proc(o:^Outputs,name:string,index:int,settings:u64=0) -> asset.Import_Info {
    return import_info(o.source,name,index,o.size,o.hash,settings,o.version)
}

// Records an output written at path: the report lists it, and a failure of
// the import removes it when it is new.
output_written :: proc(o:^Outputs,id:base.Asset_Id,kind:asset.Fourcc,name,path:string,existed:bool,detail:="") {
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    record(&o.w,id,kind,name,path,o.source,existed,detail)
}

output_warn :: proc(o:^Outputs,format:string,args:..any) {
    append(&o.report.warnings,fmt.aprintf(format,..args,allocator=o.report.allocator))
}

// Ends the outputs: the report, with a warning for each output of the
// earlier import that none took, which stays as it is. failed removes the
// files the outputs created and gives no report.
outputs_end :: proc(o:^Outputs,failed:bool) -> (report:Import_Report) {
    context.temp_allocator=base.dynamic_arena_allocator(&o.scratch)
    if failed {
        writer_rollback(&o.w)
        report_destroy(&o.report)
    } else {
        earlier_left(&o.w)
        report=o.report
    }
    asset.types_destroy(&o.w.types)
    delete(o.w.error.message,o.w.allocator)
    mem.dynamic_arena_destroy(&o.scratch)
    o^={}
    return
}
