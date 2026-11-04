package acp

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "mirai:platform"
import "mirai:std/base"
import "mirai:std/serial"

Error :: enum u8 {None,Out_Of_Memory,Invalid_State,Capacity,Invalid_Message,Unsupported,Start_Failed}
Phase :: enum u8 {Stopped,Initializing,Initialized,Authenticating,Opening,Configuring,Ready,Prompting,Stopping,Failed}
Event_Kind :: enum u8 {Initialized,Authenticated,Session_Ready,Config_Options,Update,Permission,Notice,Prompt_Done,Error,Stderr,Exited}
Event :: struct {
    kind:Event_Kind,
    value:json.Value, // borrowed until the callback returns
    text:string,
    request_id:string, // JSON representation, including quotes for string IDs
    code:int,
    replay:bool,
}
Event_Proc :: #type proc(user:rawptr,event:Event)
Session_Desc :: struct {
    cwd:string,
    session_id:string,
    mcp_servers_json:string, // ACP MCP server array, [] when empty
    model,effort:string,
    title:string,
    meta:string, // JSON object sent as _meta of session/new, load and resume; empty sends none
}
Content_Kind :: enum u8 {Text,Image,Resource_Link,Resource}
Content :: struct {
    kind:Content_Kind,
    text:string,
    data,mime_type,uri,name:string,
}

@(private)
Request :: enum u8 {None,Initialize,Authenticate,Close,New,Load,Resume,Model,Effort,Config,Rename,Prompt}

Client :: struct {
    allocator:runtime.Allocator,
    process:platform.Process,
    phase:Phase,
    rx,tx:[]u8,
    received,queued,sent:int,
    read:[16*1024]u8,
    next_id,pending_id:int,
    pending:Request,
    deadline:f64,
    load_session,resume_session,close_session,http_mcp,image,embedded_context:bool,
    session_titles,session_rename:bool,
    session:[256]u8,
    wanted_session:[256]u8,
    cwd:[1024]u8,
    mcp:[16*1024]u8,
    meta:[2048]u8,
    wanted_model:[128]u8,
    wanted_effort:[32]u8,
    wanted_title:[257]u8,
    model_option,effort_option:[128]u8,
    last_error:[1024]u8,
}

create :: proc(client:^Client,allocator:=context.allocator,receive_bytes:=2*1024*1024,send_bytes:=4*1024*1024) -> Error {
    if client==nil || client.process!=0 || len(client.rx)>0 || len(client.tx)>0 {return .Invalid_State}
    if receive_bytes<256 || send_bytes<256 {return .Capacity}
    rx,allocation_error:=make([]u8,receive_bytes,allocator)
    if allocation_error!=nil {return .Out_Of_Memory}
    tx,send_error:=make([]u8,send_bytes,allocator)
    if send_error!=nil {delete(rx,allocator);return .Out_Of_Memory}
    client^={allocator=allocator,rx=rx,tx=tx,next_id=1}
    return .None
}

destroy :: proc(c:^Client,p:^platform.Platform) {
    if c.process!=0 {platform.process_release(p,c.process)}
    delete(c.rx,c.allocator);delete(c.tx,c.allocator)
    c^={}
}

session_id :: proc(c:^Client) -> string {return base.text_get(c.session[:])}
error_text :: proc(c:^Client) -> string {return base.text_get(c.last_error[:])}

start :: proc(c:^Client,p:^platform.Platform,desc:platform.Process_Desc,session_titles:=false) -> Error {
    if c.process!=0 || len(c.rx)==0 || len(c.tx)==0 {return .Invalid_State}
    handle,error:=platform.process_start(p,desc)
    if error!=.None {return .Start_Failed}
    c.process=handle;c.received,c.queued,c.sent=0,0,0
    c.session,c.wanted_session={},{};c.last_error={}
    c.load_session,c.resume_session,c.close_session,c.http_mcp,c.image,c.embedded_context=false,false,false,false,false,false
    c.session_rename=false
    return initialize_request(c,session_titles)
}

authenticate :: proc(c:^Client,method_id:string) -> Error {
    if c.phase!=.Initialized {return .Invalid_State}
    params:=object_begin()
    member_string(&params,"methodId",method_id)
    error:=request(c,"authenticate",object_end(&params),.Authenticate)
    if error==.None {c.phase=.Authenticating}
    return error
}

open_session :: proc(c:^Client,desc:Session_Desc) -> Error {
    if c.phase!=.Initialized && c.phase!=.Ready {return .Invalid_State}
    if !filepath.is_abs(desc.cwd) {return .Invalid_Message}
    if len(desc.cwd)>=len(c.cwd) || len(desc.session_id)>=len(c.session) || len(desc.model)>=len(c.wanted_model) || len(desc.effort)>=len(c.wanted_effort) || len(desc.title)>=len(c.wanted_title) || len(desc.meta)>=len(c.meta) {return .Capacity}
    if desc.title!="" && strings.trim_space(desc.title)=="" {return .Invalid_Message}
    if desc.title!="" && !c.session_rename {return .Unsupported}
    servers:=desc.mcp_servers_json if desc.mcp_servers_json!="" else "[]"
    if len(servers)>=len(c.mcp) {return .Capacity}
    parsed,error:=json.parse_string(servers,parse_integers=true,allocator=context.temp_allocator)
    array,array_ok:=parsed.(json.Array)
    if error!=.None || !array_ok {return .Invalid_Message}
    for server in array {
        if text(at(server,"name"))=="" {return .Invalid_Message}
        if text(at(server,"type"))=="http" && !c.http_mcp {return .Unsupported}
    }
    if len(desc.meta)>=len(c.meta) {return .Capacity}
    if desc.meta!="" {
        meta,meta_error:=json.parse_string(desc.meta,allocator=context.temp_allocator)
        if _,is_object:=meta.(json.Object);meta_error!=.None || !is_object {return .Invalid_Message}
    }
    if desc.session_id!="" && !c.load_session && !c.resume_session {return .Unsupported}
    base.text_set(c.cwd[:],desc.cwd);base.text_set(c.mcp[:],servers);base.text_set(c.meta[:],desc.meta)
    base.text_set(c.wanted_session[:],desc.session_id)
    base.text_set(c.wanted_model[:],desc.model);base.text_set(c.wanted_effort[:],desc.effort)
    base.text_set(c.wanted_title[:],desc.title)
    c.model_option,c.effort_option={},{}
    if c.phase==.Ready && session_id(c)!="" && c.close_session {
        params:=object_begin()
        member_string(&params,"sessionId",session_id(c))
        result:=request(c,"session/close",object_end(&params),.Close)
        if result==.None {c.phase=.Opening}
        return result
    }
    return open_requested_session(c)
}

@(private)
open_requested_session :: proc(c:^Client) -> Error {
    method,kind:="session/new",Request.New
    params:=object_begin()
    member_string(&params,"cwd",base.text_get(c.cwd[:]))
    member_raw(&params,"mcpServers",base.text_get(c.mcp[:]))
    requested_session:=base.text_get(c.wanted_session[:])
    if requested_session!="" {
        method,kind="session/load",.Load
        if c.resume_session {method,kind="session/resume",.Resume}
        member_string(&params,"sessionId",requested_session)
    }
    if meta:=base.text_get(c.meta[:]);meta!="" {member_raw(&params,"_meta",meta)}
    result:=request(c,method,object_end(&params),kind)
    if result==.None {c.phase=.Opening}
    return result
}

set_config_option :: proc(c:^Client,config_id,value:string) -> Error {
    if c.phase!=.Ready {return .Invalid_State}
    error:=config_request(c,config_id,value,.Config)
    if error==.None {c.phase=.Configuring}
    return error
}

prompt :: proc(c:^Client,content:[]Content) -> Error {
    if c.phase!=.Ready || len(content)==0 {return .Invalid_State}
    for part in content {
        if part.kind==.Image && !c.image || part.kind==.Resource && !c.embedded_context {return .Unsupported}
        if part.kind==.Image && (part.data=="" || part.mime_type=="") {return .Invalid_Message}
        if (part.kind==.Resource || part.kind==.Resource_Link) && part.uri=="" {return .Invalid_Message}
    }
    // Written in place: the content can be as large as the queue.
    w:=message_begin(c)
    id:=c.next_id
    member(&w,"id");serial.text_write_int(&w,i64(id))
    member_string(&w,"method","session/prompt")
    member(&w,"params");serial.text_write_raw(&w,"{")
    member_string(&w,"sessionId",session_id(c))
    member(&w,"prompt");serial.text_write_raw(&w,"[")
    for part,i in content {
        if i>0 {serial.text_write_raw(&w,",")}
        serial.text_write_raw(&w,"{")
        switch part.kind {
        case .Text:
            member_string(&w,"type","text");member_string(&w,"text",part.text)
        case .Image:
            member_string(&w,"type","image");member_string(&w,"data",part.data)
            member_string(&w,"mimeType",part.mime_type)
        case .Resource_Link:
            member_string(&w,"type","resource_link");member_string(&w,"uri",part.uri)
            member_string(&w,"name",part.name)
            if part.mime_type!="" {member_string(&w,"mimeType",part.mime_type)}
        case .Resource:
            member_string(&w,"type","resource")
            member(&w,"resource");serial.text_write_raw(&w,"{")
            member_string(&w,"uri",part.uri);member_string(&w,"text",part.text)
            if part.mime_type!="" {member_string(&w,"mimeType",part.mime_type)}
            serial.text_write_raw(&w,"}")
        }
        serial.text_write_raw(&w,"}")
    }
    serial.text_write_raw(&w,"]}")
    if error:=message_end(c,&w);error!=.None {return error}
    c.next_id+=1;c.pending_id=id;c.pending=.Prompt;c.deadline=0
    c.phase=.Prompting
    return .None
}

cancel :: proc(c:^Client) -> Error {
    if c.phase!=.Prompting {return .Invalid_State}
    params:=object_begin()
    member_string(&params,"sessionId",session_id(c))
    return notification(c,"session/cancel",object_end(&params))
}

permission :: proc(c:^Client,request_id_json,option_id:string,cancelled:=false) -> Error {
    id,error:=json.parse_string(request_id_json,parse_integers=true,allocator=context.temp_allocator)
    if error!=.None {return .Invalid_Message}
    #partial switch typed_id in id {case json.Integer,json.String: case:return .Invalid_Message}
    w:=message_begin(c)
    member_raw(&w,"id",request_id_json)
    member(&w,"result");serial.text_write_raw(&w,"{")
    member(&w,"outcome");serial.text_write_raw(&w,"{")
    if cancelled {
        member_string(&w,"outcome","cancelled")
    } else {
        member_string(&w,"outcome","selected");member_string(&w,"optionId",option_id)
    }
    serial.text_write_raw(&w,"}}")
    return message_end(c,&w)
}

stop :: proc(c:^Client,p:^platform.Platform) {
    if c.process==0 {c.phase=.Stopped;return}
    platform.process_stdin_close(p,c.process)
    c.phase=.Stopping;c.deadline=platform.clock_seconds()+3
}

poll :: proc(c:^Client,p:^platform.Platform,emit:Event_Proc,user:rawptr) {
    if c.process==0 {return}
    if c.sent<c.queued {
        c.sent+=platform.process_write(p,c.process,c.tx[c.sent:c.queued])
        if c.sent==c.queued {c.sent,c.queued=0,0}
    }
    for _ in 0..<16 {
        count,_:=platform.process_read(p,c.process,.Stdout,c.read[:])
        if count==0 {break}
        feed(c,c.read[:count],emit,user)
    }
    for _ in 0..<4 {
        count,_:=platform.process_read(p,c.process,.Stderr,c.read[:])
        if count==0 {break}
        event(emit,user,{kind=.Stderr,text=string(c.read[:count])})
    }
    exited,code:=platform.process_poll(p,c.process)
    if c.phase==.Stopping && !exited && platform.clock_seconds()>=c.deadline {
        _=platform.process_terminate(p,c.process,true)
        exited,code=platform.process_poll(p,c.process)
    }
    if exited {
        was_stopping:=c.phase==.Stopping
        platform.process_release(p,c.process);c.process=0;c.pending=.None
        c.phase=.Stopped if was_stopping else .Failed
        if !was_stopping {fail(c,emit,user,"The AI agent process exited",code)}
        event(emit,user,{kind=.Exited,code=code})
    } else if c.deadline>0 && c.phase!=.Stopping && c.pending!=.None && platform.clock_seconds()>=c.deadline {
        c.pending=.None;c.phase=.Failed
        fail(c,emit,user,"The AI agent did not respond in time",0)
    }
}

@(private)
event :: proc(emit:Event_Proc,user:rawptr,value:Event) {if emit!=nil {emit(user,value)}}

@(private)
fail :: proc(c:^Client,emit:Event_Proc,user:rawptr,message:string,code:int) {
    base.text_set(c.last_error[:],message)
    event(emit,user,{kind=.Error,text=error_text(c),code=code})
}

@(private)
compact :: proc(c:^Client) {
    if c.sent>0 {c.queued=copy(c.tx,c.tx[c.sent:c.queued]);c.sent=0}
}

@(private)
request :: proc(c:^Client,method,params:string,kind:Request) -> Error {
    if c.pending!=.None {return .Invalid_State}
    w:=message_begin(c)
    member(&w,"id");serial.text_write_int(&w,i64(c.next_id))
    member_string(&w,"method",method)
    member_raw(&w,"params",params)
    if error:=message_end(c,&w);error!=.None {return error}
    c.pending_id=c.next_id;c.next_id+=1;c.pending=kind
    c.deadline=platform.clock_seconds()+120
    return .None
}

@(private)
initialize_request :: proc(c:^Client,session_titles:bool) -> Error {
    basic :: `{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"mirai","title":"Mirai","version":"1"}}`
    titles :: `{"protocolVersion":1,"clientCapabilities":{"_meta":{"jetbrains":{"air":{"version":1,"capabilities":["sessionIndex"]}}}},"clientInfo":{"name":"mirai","title":"Mirai","version":"1"}}`
    error:=request(c,"initialize",titles if session_titles else basic,.Initialize)
    if error==.None {c.session_titles=session_titles;c.phase=.Initializing}
    return error
}

@(private)
notification :: proc(c:^Client,method,params:string) -> Error {
    w:=message_begin(c)
    member_string(&w,"method",method)
    member_raw(&w,"params",params)
    return message_end(c,&w)
}

@(private)
config_request :: proc(c:^Client,id,value:string,kind:Request) -> Error {
    params:=object_begin()
    member_string(&params,"sessionId",session_id(c))
    member_string(&params,"configId",id)
    member_string(&params,"value",value)
    return request(c,"session/set_config_option",object_end(&params),kind)
}

@(private)
feed :: proc(c:^Client,bytes:[]u8,emit:Event_Proc,user:rawptr) {
    for byte in bytes {
        if byte=='\n' {
            line:=strings.trim_space(string(c.rx[:c.received]));c.received=0
            if line!="" {receive(c,line,emit,user)}
        } else if c.received<len(c.rx) {
            c.rx[c.received]=byte;c.received+=1
        } else {
            c.received=0;c.phase=.Failed;c.pending=.None
            fail(c,emit,user,"The AI agent exceeded the ACP message capacity",0)
            return
        }
    }
}

@(private)
receive :: proc(c:^Client,line:string,emit:Event_Proc,user:rawptr) {
    value,error:=json.parse_string(line,parse_integers=true,allocator=context.temp_allocator)
    object,ok:=value.(json.Object)
    if error!=.None || !ok || text(object["jsonrpc"])!="2.0" {
        c.phase=.Failed;c.pending=.None
        fail(c,emit,user,"The AI agent sent an invalid ACP message",0)
        return
    }
    method:=text(object["method"])
    if method!="" {
        params:=object["params"]
        request_id:=object["id"]
        if request_id!=nil {
            encoded,marshal_error:=json.marshal(request_id,{},context.temp_allocator)
            if marshal_error!=nil {fail(c,emit,user,"The ACP request ID could not be read",0);return}
            if method=="session/request_permission" {
                event(emit,user,{kind=.Permission,value=params,request_id=string(encoded)})
            } else {
                w:=message_begin(c)
                member_raw(&w,"id",string(encoded))
                member_raw(&w,"error",`{"code":-32601,"message":"Client method not supported"}`)
                if message_end(c,&w)!=.None {fail(c,emit,user,"The ACP response queue is full",0)}
            }
        } else if method=="session/update" {
            event(emit,user,{kind=.Update,value=params,replay=c.pending==.Load})
        } else {
            event(emit,user,{kind=.Notice,value=params,text=method})
        }
        return
    }
    id,id_ok:=object["id"].(json.Integer)
    if !id_ok || int(id)!=c.pending_id || c.pending==.None {return}
    pending:=c.pending;c.pending=.None;c.deadline=0
    if rpc_error,error_ok:=object["error"].(json.Object);error_ok {
        c.phase=.Initialized if session_id(c)=="" else .Ready
        message:=text(rpc_error["message"])
        detail:=text(rpc_error["data"])
        if detail=="" {detail=text(at(rpc_error["data"],"details"))}
        if detail!="" {message=fmt.aprintf("%s: %s",message,detail,allocator=context.temp_allocator)}
        code,_:=rpc_error["code"].(json.Integer)
        base.text_set(c.last_error[:],message)
        event(emit,user,{kind=.Error,value=object["error"],text=error_text(c),code=int(code)})
        return
    }
    result:=object["result"]
    if _,result_ok:=result.(json.Object);!result_ok {
        c.phase=.Failed
        fail(c,emit,user,"The AI agent sent an invalid ACP response",0)
        return
    }
    switch pending {
    case .Initialize:
        version,_:=at(result,"protocolVersion").(json.Integer)
        if version!=1 {c.phase=.Failed;fail(c,emit,user,fmt.tprintf("The AI agent speaks ACP version %d; Mirai speaks version 1",version),0);return}
        c.load_session=boolean(at(result,"agentCapabilities","loadSession"))
        c.resume_session=at(result,"agentCapabilities","sessionCapabilities","resume")!=nil
        c.close_session=at(result,"agentCapabilities","sessionCapabilities","close")!=nil
        c.http_mcp=boolean(at(result,"agentCapabilities","mcpCapabilities","http"))
        c.image=boolean(at(result,"agentCapabilities","promptCapabilities","image"))
        c.embedded_context=boolean(at(result,"agentCapabilities","promptCapabilities","embeddedContext"))
        c.session_rename=c.session_titles && air_capability(result,"sessionRename")
        c.phase=.Initialized
        event(emit,user,{kind=.Initialized,value=result})
    case .Authenticate:
        c.phase=.Initialized
        event(emit,user,{kind=.Authenticated,value=result})
    case .Close:
        c.session={};c.phase=.Initialized
        if error:=open_requested_session(c);error!=.None {fail(c,emit,user,"The next ACP session could not be opened",0)}
    case .New,.Load,.Resume:
        if pending==.New {
            id:=text(at(result,"sessionId"))
            if id=="" || len(id)>=len(c.session) {c.phase=.Failed;fail(c,emit,user,"The AI agent returned an invalid session ID",0);return}
            base.text_set(c.session[:],id)
        } else {
            base.text_set(c.session[:],base.text_get(c.wanted_session[:]))
        }
        c.phase=.Configuring
        options(c,result,emit,user)
        configure(c,result,emit,user,true)
    case .Model:
        options(c,result,emit,user)
        configure(c,result,emit,user,false)
    case .Effort,.Config:
        options(c,result,emit,user)
        session_ready(c,result,emit,user)
    case .Rename:
        c.wanted_title={}
        c.phase=.Ready
        event(emit,user,{kind=.Session_Ready,value=result})
    case .Prompt:
        c.phase=.Ready
        event(emit,user,{kind=.Prompt_Done,value=result,text=text(at(result,"stopReason"))})
    case .None:
    }
}

@(private)
options :: proc(c:^Client,result:json.Value,emit:Event_Proc,user:rawptr) {
    config,ok:=at(result,"configOptions").(json.Array)
    if !ok {return}
    for option in config {
        id,category:=text(at(option,"id")),text(at(option,"category"))
        if category=="model" {base.text_set(c.model_option[:],id)}
        if category=="thought_level" {base.text_set(c.effort_option[:],id)}
    }
    event(emit,user,{kind=.Config_Options,value=result})
}

@(private)
configure :: proc(c:^Client,result:json.Value,emit:Event_Proc,user:rawptr,model:bool) {
    id,wanted:=base.text_get(c.effort_option[:]),base.text_get(c.wanted_effort[:])
    kind:=Request.Effort
    if model {id,wanted=base.text_get(c.model_option[:]),base.text_get(c.wanted_model[:]);kind=.Model}
    if wanted!="" {
        if id=="" || !option_exists(result,id,wanted) {
            c.phase=.Ready
            label:="model" if model else "reasoning level"
            fail(c,emit,user,fmt.aprintf("The configured %s '%s' is unavailable",label,wanted,allocator=context.temp_allocator),0)
            return
        }
        if error:=config_request(c,id,wanted,kind);error!=.None {
            c.phase=.Ready;fail(c,emit,user,"The ACP configuration could not be sent",0)
        }
        return
    }
    if model {configure(c,result,emit,user,false);return}
    session_ready(c,result,emit,user)
}

@(private)
session_ready :: proc(c:^Client,result:json.Value,emit:Event_Proc,user:rawptr) {
    title:=base.text_get(c.wanted_title[:])
    if title!="" {
        params:=object_begin()
        member_string(&params,"sessionId",session_id(c))
        member_string(&params,"title",title)
        if error:=request(c,"_session/rename",object_end(&params),.Rename);error!=.None {
            c.phase=.Ready;fail(c,emit,user,"The ACP session title could not be sent",0)
        }
        return
    }
    c.phase=.Ready;event(emit,user,{kind=.Session_Ready,value=result})
}

@(private)
air_capability :: proc(result:json.Value,wanted:string) -> bool {
    air:=at(result,"_meta","jetbrains","air")
    version,valid:=at(air,"version").(json.Integer)
    if !valid || version<1 {return false}
    capabilities,_:=at(air,"capabilities").(json.Array)
    for capability in capabilities {if text(capability)==wanted {return true}}
    return false
}

@(private)
option_exists :: proc(result:json.Value,id,wanted:string) -> bool {
    options,_:=at(result,"configOptions").(json.Array)
    for option in options {
        if text(at(option,"id"))!=id {continue}
        choices,_:=at(option,"options").(json.Array)
        for choice in choices {
            if text(at(choice,"value"))==wanted {return true}
            grouped,_:=at(choice,"options").(json.Array)
            for child in grouped {if text(at(child,"value"))==wanted {return true}}
        }
    }
    return false
}

at :: proc(value:json.Value,keys:..string) -> json.Value {
    current:=value
    for key in keys {
        object,ok:=current.(json.Object)
        if !ok {return nil}
        current=object[key]
    }
    return current
}
text :: proc(value:json.Value) -> string {
    string_value,_:=value.(json.String)
    return string(string_value)
}
boolean :: proc(value:json.Value) -> bool {
    bool_value,_:=value.(json.Boolean)
    return bool(bool_value)
}
