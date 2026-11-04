package editor

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// What the methods that edit an asset by code share, those of the editor and
// those of plugins: the asset the params name, the values of its info as
// their text, and the result that names it.

ASSET_PARAMS_EXTRA :: 4

// The params of a method that edits an asset by code: the asset under `key`
// (its path under the assets folder, or its id), the path of a new one, its
// values and the text of the other keys the method takes.
Asset_Params :: struct {
    named,path:string,
    values:string,                    // the text of the object
    extra:[ASSET_PARAMS_EXTRA]string, // the text of each key of extra given; empty: not given
}

asset_params :: proc(call:^api.Call,key:string,extra:[]string={}) -> (p:Asset_Params,ok:bool) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,call.raw,context.temp_allocator)
    failed :: proc(call:^api.Call,r:^serial.Text_Reader) -> bool {
        line,column:=serial.text_position(call.raw,r.error.offset)
        api.call_failf(call,api.INVALID_PARAMS,"%s at line %d, column %d",serial.text_error_message(r,allocator=context.temp_allocator),line,column)
        return false
    }
    if !serial.text_accept(&r,'{') {
        serial.text_fail(&r,.Expected_Object)
        return p,failed(call,&r)
    }
    if serial.text_accept(&r,'}') {return p,true}
    for {
        serial.text_space(&r)
        name,named:=serial.text_string(&r)
        if !named || !serial.text_expect(&r,':') {return p,failed(call,&r)}
        name=strings.clone(name,context.temp_allocator)
        serial.text_space(&r)
        other:=-1
        for each,i in extra[:min(len(extra),ASSET_PARAMS_EXTRA)] {
            if each==name {other=i;break}
        }
        switch {
        case name==key || name=="path":
            text,read:=serial.text_string(&r)
            if !read {return p,failed(call,&r)}
            if name=="path" {p.path=strings.clone(text,context.temp_allocator)} else {p.named=strings.clone(text,context.temp_allocator)}
        case name=="values" || other>=0:
            start:=r.offset
            if !serial.text_skip(&r) {return p,failed(call,&r)}
            if other>=0 {p.extra[other]=call.raw[start:r.offset]} else {p.values=call.raw[start:r.offset]}
        case:
            more:=strings.builder_make(context.temp_allocator)
            for each in extra {fmt.sbprintf(&more,", %s",each)}
            api.call_failf(call,api.INVALID_PARAMS,"%s is not a parameter: %s, path, values%s",name,key,strings.to_string(more))
            return
        }
        if serial.text_accept(&r,',') {continue}
        if !serial.text_expect(&r,'}') {return p,failed(call,&r)}
        return p,true
    }
}

// Puts the values of the params, the text of the values of an asset, over info.
asset_values_read :: proc(call:^api.Call,text:string,info:^$T) -> bool {
    if text=="" {return true}
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add_type_info(&schema,type_info_of(T))
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    if !serial.text_read(&r,&schema,type,mem.ptr_to_bytes(info)) {
        line,column:=serial.text_position(text,r.error.offset)
        api.call_failf(call,api.INVALID_PARAMS,"%s at line %d, column %d",serial.text_error_message(&r,"values",context.temp_allocator),line,column)
        return false
    }
    return true
}

// Opens the result of an asset: its id under `key` and its path.
asset_named_write :: proc(s:^Session,out:^serial.Writer,key:string,id:base.Asset_Id) {
    serial.write_u8(out,'{')
    serial.text_write_string(out,key)
    serial.write_u8(out,':')
    serial.write_u8(out,'"')
    serial.text_write_asset_id(out,id)
    serial.write_u8(out,'"')
    if file,found:=asset.registry_find(&s.app.assets.registry,id);found {
        api.write_key(out,"path")
        serial.text_write_string(out,file.path)
    }
}

// The values of an asset as their text, under `key` of the result.
asset_values_write :: proc(out:^serial.Writer,key:string,info:^$T) {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add_type_info(&schema,type_info_of(T))
    api.write_key(out,key)
    serial.text_write(out,&schema,type,mem.ptr_to_bytes(info),.Line)
}

// The asset of a kind the params name: its path under the assets folder, with
// or without the extension of the kind, or its id.
asset_named :: proc(s:^Session,call:^api.Call,name:string,kind:asset.Fourcc,extension,what:string) -> (id:base.Asset_Id,ok:bool) {
    a:=s.app.assets
    if a==nil {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no assets")
        return
    }
    host.assets_scan(a)
    if parsed,is_id:=serial.text_parse_asset_id(name);is_id {
        if file,found:=asset.registry_find(&a.registry,parsed);found && file.kind==kind {return parsed,true}
    }
    for candidate in ([2]string{name,fmt.tprintf("%s%s",name,extension)}) {
        if file,found:=asset.registry_find_path(&a.registry,candidate);found && file.kind==kind {return file.id,true}
    }
    api.call_failf(call,api.INVALID_PARAMS,"%q is not %s of the assets",name,what)
    return
}

// The asset a *.set writes: the one the params name under `key`, or a new one
// with a new id at path, whose file must not exist yet.
Asset_Target :: struct {
    id:base.Asset_Id,
    file:string, // its file in the project
    created:bool,
}

asset_target :: proc(s:^Session,call:^api.Call,p:^Asset_Params,key:string,kind:asset.Fourcc,extension,what:string) -> (t:Asset_Target,ok:bool) {
    if (p.named=="")==(p.path=="") {
        api.call_failf(call,api.INVALID_PARAMS,"Give exactly one of %s, %s to change by its path under the assets folder or its id, and path, where a new one goes",key,what)
        return
    }
    a:=s.app.assets
    if p.named!="" {
        t.id=asset_named(s,call,p.named,kind,extension,what) or_return
        record,_:=asset.registry_find(&a.registry,t.id)
        t.file=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
        return t,true
    }
    if a==nil || !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"The editor has no project")
        return
    }
    path:=strings.has_suffix(p.path,extension)?p.path:fmt.tprintf("%s%s",p.path,extension)
    if t.file=scene_file(s,path);t.file=="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",path,document_error_text(.Bad_Path))
        return
    }
    if file_exists(s,t.file) {
        api.call_failf(call,api.INVALID_PARAMS,"%s already exists: give it as %s to change it",path,key)
        return
    }
    t.id,t.created=asset_id_new(s),true
    return t,true
}
