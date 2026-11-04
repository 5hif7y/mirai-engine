package animation_editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

Authoring_Inspect_Params :: struct {
    asset:base.Asset_Id,
    offset:u32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=256"`,
}
Authoring_Create_Params :: struct {
    path:[1024]u8 `mirai:"text"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Authoring_File :: struct {file:asset.Asset,path:string}

@(private)
authoring_register :: proc(s:^editor.Session) {
    authoring_clip_register(s)
    authoring_skeleton_register(s)
    authoring_profile_register(s)
    authoring_bake_register(s)
    authoring_motion_register(s)
    authoring_actions_register(s)
    authoring_patch_register(s)
    body_register(s)
    clip_edit_register(s)
    request_register(s)
    setup_register(s)
    inspect_register(s)
}

@(private)
authoring_open :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,kind:asset.Fourcc,result:^Authoring_File) -> bool {
    if s.app==nil || s.app.assets==nil {authoring_failure(call,"asset","Unavailable","an initialized asset service","unavailable","Assets are unavailable",api.SERVER_ERROR);return false}
    a:=s.app.assets
    if !host.assets_scan(a) {authoring_failure(call,"asset","Registry_Error","a refreshed asset registry","scan failed","The asset registry could not be refreshed",api.SERVER_ERROR);return false}
    record,found:=asset.registry_find(&a.registry,id)
    if !found || record.kind!=kind {authoring_failure(call,"asset","Invalid_Asset",fmt.tprintf("kind %v",kind),fmt.tprintf("kind %v",record.kind) if found else "missing","The asset is missing or has a different kind");return false}
    result.path=asset.registry_file_path(&a.registry,record.path,call.allocator)
    if error:=host.assets_file(a,id,kind,&result.file);error!=.None {authoring_failure(call,"asset","Read_Error","a readable asset file",fmt.tprintf("%v",error),"The asset could not be read");return false}
    return true
}

@(private)
authoring_editable :: proc(s:^editor.Session,call:^api.Call) -> bool {
    if s.mode!=.Edit && !authoring_dry_run(call) {authoring_failure(call,"mode","Invalid_Mode","Edit",fmt.tprintf("%v",s.mode),"Asset authoring requires Edit mode",api.SERVER_ERROR);return false}
    if s.app==nil || s.app.assets==nil {authoring_failure(call,"asset","Unavailable","an initialized asset service","unavailable","Assets are unavailable",api.SERVER_ERROR);return false}
    return true
}

@(private)
authoring_create_target :: proc(s:^editor.Session,call:^api.Call,path,extension:string,exists_fix:="") -> (target:Authoring_File,id:base.Asset_Id,ok:bool) {
    if !authoring_editable(s,call) {return}
    if path=="" {authoring_failure(call,"path","Required","a nonempty asset path","empty","path must not be empty");return}
    if !strings.has_suffix(path,extension) {authoring_failure(call,"path","Extension",extension,path,"The asset path has a different extension");return}
    target.path=editor.scene_file(s,path,call.allocator)
    if editor.file_exists(s,target.path) {authoring_failure(call,"path","Already_Exists","a new asset path",path,"The destination already exists",fix=exists_fix);return}
    rng:=base.rng_make(s.id_state~platform.clock_ns())
    id=base.asset_id_random(&rng);s.id_state=rng.state
    return target,id,true
}

// The asset a set method writes: a new one at path, or the existing asset
// replaced whole. Exactly one of the two.
@(private)
authoring_set_target :: proc(s:^editor.Session,call:^api.Call,path:string,id:base.Asset_Id,kind:asset.Fourcc,extension:string,target:^Authoring_File) -> (base.Asset_Id,bool) {
    if (id!={})==(path!="") {
        authoring_failure(call,"path","Exclusive_Reference","exactly one of path or asset","both" if id!={} else "neither","Supply exactly one of path or asset",fix=fmt.tprintf("Pass path to create a new %s, or asset to replace an existing one",extension))
        return {},false
    }
    if id!={} {return id,authoring_open(s,call,id,kind,target)}
    created,new_id,ok:=authoring_create_target(s,call,path,extension,exists_fix="Choose another path, or pass its id from asset.list as asset to replace it")
    target^=created
    return new_id,ok
}

// Publishes an asset document: prepares the response and writes the file as
// a step of the editor's history (one undo with the rest of the call). The
// asset changes in memory, unsaved; a new one exists only there until it is
// saved. more writes fields of the result after asset and path. dry_run in
// the params validates and answers without writing.
@(private)
authoring_publish :: proc(s:^editor.Session,call:^api.Call,target:Authoring_File,doc:^asset.Document,more:proc(call:^api.Call,data:rawptr)=nil,data:rawptr=nil) -> bool {
    if target.file.file==nil && editor.file_exists(s,target.path) {
        authoring_failure(call,"path","Already_Exists","a new asset path","created while the asset was prepared","The destination was created while the asset was prepared")
        return false
    }
    bytes:serial.Writer;serial.writer_init(&bytes,4096,s.app.allocator);defer serial.writer_destroy(&bytes)
    if error:=asset.document_write(doc,&bytes);error!=.None {authoring_failure(call,"asset","Serialization","a valid asset document",fmt.tprintf("%v",error),"The asset could not be serialized",api.SERVER_ERROR);return false}
    dry_run:=authoring_dry_run(call)
    serial.text_write_raw(call.out,"{")
    authoring_result(call,doc.id,target.path)
    if dry_run {api.write_bool(call.out,"dry_run",true)}
    if more!=nil {more(call,data)}
    serial.text_write_raw(call.out,"}")
    if call.out.overflow!=0 {
        authoring_failure(call,"result","Capacity","space for the publication result","response buffer full","The asset result does not fit in the response buffer",api.SERVER_ERROR)
        return false
    }
    if dry_run {return true}
    if !authoring_write(s,call,target.path,serial.writer_bytes(&bytes)) {
        if !call.failed {authoring_failure(call,"path","Write_Error","an asset write","write failed","The asset could not be written",api.SERVER_ERROR)}
        return false
    }
    return true
}

// Writes a file of the project as a step of the editor's history, named
// after the method. Without a history (a session without edits) the file
// only changes.
@(private)
authoring_write :: proc(s:^editor.Session,call:^api.Call,path:string,bytes:[]u8) -> bool {
    label:=call.method.name if call.method!=nil else "Animation asset"
    if s.edits==nil {return editor.file_write(s,path,bytes,label)}
    if !editor.api_edit_begin(s,call,label) {return false}
    written:=editor.file_write(s,path,bytes,label)
    return editor.api_edit_end(s,call,written) && written
}

// Whether the params ask to validate without writing.
@(private)
authoring_dry_run :: proc(call:^api.Call) -> bool {
    value,found:=authoring_json_field(call.raw,"dry_run",call.allocator)
    return found && value=="true"
}

@(private)
authoring_result :: proc(call:^api.Call,id:base.Asset_Id,path:string,first:bool=true) {
    out:=call.out
    api.write_key(out,"asset",first);serial.write_u8(out,'"');serial.text_write_asset_id(out,id);serial.write_u8(out,'"')
    api.write_text(out,"path",path)
}

@(private)
authoring_write_value :: proc(call:^api.Call,value:^$T,info:^runtime.Type_Info) -> bool {
    schema:serial.Schema
    allocator:=call.server.allocator if call.server!=nil else context.allocator
    serial.schema_init(&schema,allocator)
    defer serial.schema_destroy(&schema)
    index,ok:=serial.schema_add_type_info(&schema,info)
    if !ok {authoring_failure(call,"result","Invalid_Schema","a registered result type","schema preparation failed","The value schema could not be prepared",api.INTERNAL_ERROR);return false}
    serial.text_write(call.out,&schema,index,mem.ptr_to_bytes(value),.Line)
    return call.out.overflow==0
}

@(private)
authoring_json_field :: proc(text,name:string,allocator:=context.temp_allocator) -> (value:string,found:bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,allocator);defer serial.text_reader_destroy(&r)
    if !serial.text_accept(&r,'{') {return}
    for !serial.text_accept(&r,'}') {
        key,ok:=serial.text_string(&r);if !ok || !serial.text_expect(&r,':') {return}
        start:=r.offset
        if !serial.text_skip(&r) {return}
        if key==name {return text[start:r.offset],true}
        if !serial.text_accept(&r,',') {break}
    }
    return
}

@(private)
authoring_json_element :: proc(text:string,index:int,allocator:=context.temp_allocator) -> (value:string,found:bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,allocator);defer serial.text_reader_destroy(&r)
    if !serial.text_accept(&r,'[') {return}
    at:=0
    for !serial.text_accept(&r,']') {
        start:=r.offset
        if !serial.text_skip(&r) {return}
        if at==index {return text[start:r.offset],true}
        at+=1
        if !serial.text_accept(&r,',') {break}
    }
    return
}

@(private)
authoring_field_present :: proc(call:^api.Call,field:string) -> bool {
    r:serial.Text_Reader
    serial.text_reader_init(&r,call.raw,call.allocator)
    defer serial.text_reader_destroy(&r)
    if !serial.text_accept(&r,'{') {return false}
    for !serial.text_accept(&r,'}') {
        name,ok:=serial.text_string(&r);if !ok || !serial.text_expect(&r,':') {return false}
        if name==field {return true}
        if !serial.text_skip(&r) || !serial.text_accept(&r,',') {break}
    }
    return false
}

@(private)
authoring_replace_row :: proc(rows:[]$T,index:int,value:T,remove:bool,maximum:int,allocator:=context.temp_allocator) -> (result:[]T,ok:bool) {
    if index<0 || index>len(rows) || remove && index==len(rows) || !remove && index==len(rows) && len(rows)>=maximum {return}
    count:=len(rows)
    if remove {count-=1} else if index==count {count+=1}
    error:runtime.Allocator_Error
    result,error=make([]T,count,allocator)
    if error!=nil {return nil,false}
    if remove {copy(result[:index],rows[:index]);copy(result[index:],rows[index+1:])}
    else {copy(result,rows);result[index]=value}
    return result,true
}
