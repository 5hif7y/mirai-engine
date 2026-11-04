package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:editor/api"

MCP_MAX_LINE :: 16<<20
MCP_USAGE :: "mcp [--project P|--port N] [--timeout S] [--plugins A,B|*] [--client NAME]"

// stdout is written by the messages and by the watcher of the editor.
Mcp_Bridge :: struct {
    connection:Connection,
    lock:sync.Mutex,
    unlisted:bool, // the client holds an empty list of tools
    plugins:string, // whose tools the client is given besides those of the editor: names separated by commas, or *
    client:string,  // X-Mirai-Client: --client, the name its initialize gives, or that of the shell it runs in
    named:bool,     // by --client
}

// MCP over stdio, one JSON message per line, forwarded to the editor.
cmd_mcp :: proc(root:string,args:[]string) -> int {
    connection,ok:=connection_args(args,agent_environment())
    plugins:=""
    rest:=connection.rest[:]
    if ok && len(rest)==2 && rest[0]=="--plugins" && rest[1]!="" {plugins,rest=rest[1],rest[2:]}
    if !ok || len(rest)>0 {
        fmt.eprintfln("Usage: mirai %s",MCP_USAGE)
        return 2
    }
    bridge:=Mcp_Bridge{connection=connection,plugins=plugins,client=connection.client}
    bridge.named=bridge.client!=""
    if !bridge.named {bridge.client=client_environment()}
    thread.create_and_start_with_poly_data(&bridge,mcp_watch,self_cleanup=true)
    pending:[dynamic]u8
    chunk:[64*1024]u8
    for {
        n,error:=os.read(os.stdin,chunk[:])
        if n>0 {append(&pending,..chunk[:n])}
        for {
            end:=-1
            for c,i in pending {if c=='\n' {end=i;break}}
            if end<0 {break}
            mcp_message(&bridge,string(pending[:end]))
            remove_range(&pending,0,end+1)
        }
        if len(pending)>MCP_MAX_LINE {
            fmt.eprintln("mirai mcp: a message exceeds",MCP_MAX_LINE,"bytes")
            clear(&pending)
        }
        if error!=nil || n==0 {break}
    }
    if len(pending)>0 {mcp_message(&bridge,string(pending[:]))}
    return 0
}

mcp_message :: proc(bridge:^Mcp_Bridge,line:string) {
    defer free_all(context.temp_allocator)
    text:=line
    for len(text)>0 && (text[len(text)-1]=='\r' || text[len(text)-1]==' ') {text=text[:len(text)-1]}
    for len(text)>0 && (text[0]==' ' || text[0]=='\t') {text=text[1:]}
    if text=="" {return}
    if name:=api.bridge_client_name(context.temp_allocator,text);name!="" && !bridge.named {bridge.client=strings.clone(name)}
    c:=bridge.connection
    port:=connection_port(c)
    reply,answer,unlisted:=api.bridge_handle(port,c.timeout_ms,text,context.temp_allocator,connection_task(c,port),bridge.plugins,bridge.client)
    if !answer {return}
    sync.guard(&bridge.lock)
    if unlisted {bridge.unlisted=true}
    os.write_string(os.stdout,reply)
    os.write_string(os.stdout,"\n")
}

// While the client holds an empty list, tries the editor every
// BRIDGE_RETRY seconds and tells the client when it answers.
mcp_watch :: proc(bridge:^Mcp_Bridge) {
    for {
        time.sleep(api.BRIDGE_RETRY*time.Second)
        sync.lock(&bridge.lock)
        unlisted:=bridge.unlisted
        sync.unlock(&bridge.lock)
        reachable:=unlisted && api.bridge_reachable(connection_port(bridge.connection),context.temp_allocator)
        free_all(context.temp_allocator)
        if !reachable {continue}
        sync.guard(&bridge.lock)
        bridge.unlisted=false
        os.write_string(os.stdout,api.BRIDGE_LIST_CHANGED+"\n")
    }
}
