package editor

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:project"
import "mirai:std/serial"
import "mirai:third_party/sqlite"

// The chats of a project live in .mirai/ai/chats: per conversation <id>.json
// holds its metadata, replaced whole, and <id>.log its messages, one JSON
// record per line that is only appended to. A later record of a sequence
// replaces the earlier one; a line cut by a crash is skipped. The search
// index of .mirai/ai/search.db is derived from the logs (ai_search.odin).
AI_STORE_VERSION :: 1
AI_STORE_LOG_BYTES :: 256<<20
AI_STORE_SEQUENCES :: 1<<24

Ai_Store :: struct {
    folder:string, // empty while closed
    conversations:[dynamic]Ai_Conversation, // by updated_at and id, the latest first
    next_id:u64,
    allocator:runtime.Allocator,
    error:[512]u8,
    error_len:int,
    index:^sqlite.Db, // nil while the search index is unavailable, with why in index_error
    index_path:string,
    index_error:[256]u8,
    index_error_len:int,
}

Ai_Conversation :: struct {
    id:u64,
    title:[256]u8,
    title_len:int,
    document:[1024]u8,
    document_len:int,
    provider:[32]u8,
    provider_len:int,
    model:[128]u8,
    model_len:int,
    effort:[32]u8,
    effort_len:int,
    native_session:[256]u8,
    native_session_len:int,
    last:[AI_LAST_BYTES]u8, // the start of the last answer of the agent, as History shows it
    last_len:int,
    created_at:i64,
    updated_at:i64,
    seconds:f32,    // its turns ran, all together
    usage:Ai_Usage,
}

// What a conversation spent, as its agent reports it over ACP: its tokens
// across the turns, with the end of each turn, and its context, as it changes.
Ai_Usage :: struct {
    input:i64 `json:"input,omitempty"`,
    output:i64 `json:"output,omitempty"`,
    cache_read:i64 `json:"cache_read,omitempty"`,
    cache_write:i64 `json:"cache_write,omitempty"`,
    total:i64 `json:"total,omitempty"`,
    context_used:i64 `json:"context_used,omitempty"`, // tokens in its context window
    context_size:i64 `json:"context_size,omitempty"`,
    cost:f64 `json:"cost,omitempty"`, // USD
}

Ai_Stored_Line :: struct {
    sequence:u64,
    kind:Ai_Line_Kind,
    text:string,
    role:string,
    event_type:string,
    tool:string,
    context_json:string,
}

@(private="file")
Ai_Store_Meta :: struct {
    version:int,
    id:u64,
    title,document,provider,model,effort,native_session:string,
    last:string `json:"last,omitempty"`,
    created_at,updated_at:i64,
    seconds:f32 `json:"seconds,omitempty"`,
    usage:Ai_Usage,
}

// A message line sets kind and text, and the role when the message is new; an
// annotation sets role, event type, tool and context of a message saved before.
@(private)
Ai_Store_Record :: struct {
    sequence:u64,
    annotation:bool `json:"annotation,omitempty"`,
    kind:int `json:"kind,omitempty"`,
    text:string `json:"text,omitempty"`,
    role:string `json:"role,omitempty"`,
    event_type:string `json:"event_type,omitempty"`,
    tool:string `json:"tool,omitempty"`,
    context_json:string `json:"context,omitempty"`,
}

@(private="file")
Ai_Store_Entry :: struct {
    line:Ai_Stored_Line,
    present:bool,
}

ai_conversation_set_text :: proc(buffer:[]u8,length:^int,text:string) -> bool {
    if len(text)>len(buffer) {return false}
    length^=copy(buffer,text)
    return true
}

@(private="file")
ai_store_error :: proc(s:^Ai_Store,message:string) -> string {
    s.error_len=copy(s.error[:],message)
    return string(s.error[:s.error_len])
}

@(private)
ai_store_path :: proc(s:^Ai_Store,id:u64,extension:string,allocator:=context.temp_allocator) -> string {
    return fmt.aprintf("%s/%d.%s",s.folder,id,extension,allocator=allocator)
}

@(private="file")
ai_store_from_meta :: proc(meta:Ai_Store_Meta) -> (c:Ai_Conversation,ok:bool) {
    c={id=meta.id,created_at=meta.created_at,updated_at=meta.updated_at,seconds=meta.seconds,usage=meta.usage}
    ok=ai_conversation_set_text(c.title[:],&c.title_len,meta.title) &&
        ai_conversation_set_text(c.document[:],&c.document_len,meta.document) &&
        ai_conversation_set_text(c.provider[:],&c.provider_len,meta.provider) &&
        ai_conversation_set_text(c.model[:],&c.model_len,meta.model) &&
        ai_conversation_set_text(c.effort[:],&c.effort_len,meta.effort) &&
        ai_conversation_set_text(c.native_session[:],&c.native_session_len,meta.native_session) &&
        ai_conversation_set_text(c.last[:],&c.last_len,meta.last)
    return
}

@(private="file")
ai_store_before :: proc(a,b:Ai_Conversation) -> bool {
    return a.updated_at>b.updated_at || a.updated_at==b.updated_at && a.id>b.id
}

// Puts c in its place of the order, replacing the conversation with its id.
@(private="file")
ai_store_place :: proc(s:^Ai_Store,c:^Ai_Conversation) -> bool {
    for &existing,index in s.conversations {
        if existing.id==c.id {ordered_remove(&s.conversations,index);break}
    }
    at:=len(s.conversations)
    for &existing,index in s.conversations {if ai_store_before(c^,existing) {at=index;break}}
    if _,error:=inject_at(&s.conversations,at,c^);error!=nil {return false}
    s.next_id=max(s.next_id,c.id+1)
    return true
}

// The number at the start of a file name of the folder: 0 for another file.
@(private="file")
ai_store_file_id :: proc(name:string) -> (id:u64,extension:string) {
    dot:=strings.index_byte(name,'.')
    if dot<=0 {return 0,""}
    value,ok:=strconv.parse_u64_of_base(name[:dot],10)
    if !ok {return 0,""}
    return value,name[dot+1:]
}

ai_store_open :: proc(s:^Ai_Store,root:string,allocator:=context.allocator) -> string {
    ai_store_close(s)
    folder:=project.path(root,".mirai/ai/chats",allocator=context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return ai_store_error(s,"Could not create the project chat folder")}
    scratch:vmem.Arena
    if vmem.arena_init_growing(&scratch)!=nil {return ai_store_error(s,"No memory to read the project chats")}
    defer vmem.arena_destroy(&scratch)
    scratch_allocator:=vmem.arena_allocator(&scratch)
    entries,error:=os.read_all_directory_by_path(folder,scratch_allocator)
    if error!=nil {return ai_store_error(s,"Could not read the project chat folder")}
    s.allocator=allocator
    s.folder=strings.clone(folder,allocator)
    s.conversations=make([dynamic]Ai_Conversation,0,len(entries)/2,allocator)
    s.next_id=1
    for entry in entries {
        id,extension:=ai_store_file_id(entry.name)
        if id==0 {continue}
        s.next_id=max(s.next_id,id+1)
        if extension!="json" || entry.size>64<<10 {continue}
        bytes,read_error:=os.read_entire_file(entry.fullpath,scratch_allocator)
        if read_error!=nil {continue}
        meta:Ai_Store_Meta
        if json.unmarshal(bytes,&meta,allocator=scratch_allocator)!=nil || meta.version!=AI_STORE_VERSION || meta.id!=id {continue}
        c,ok:=ai_store_from_meta(meta)
        if ok && !ai_store_place(s,&c) {ai_store_close(s);return ai_store_error(s,"No memory for the project chats")}
    }
    s.index_path=project.path(root,".mirai/ai/search.db",allocator=allocator)
    ai_index_open(s)
    return ""
}

ai_store_close :: proc(s:^Ai_Store) {
    ai_index_close(s)
    if s.index_path!="" {delete(s.index_path,s.allocator);s.index_path=""}
    if s.folder=="" {return}
    delete(s.folder,s.allocator)
    delete(s.conversations)
    s.folder,s.conversations={},{}
}

// Reserves the next identifier by creating its message file, so that another
// editor of the same project does not take it.
ai_store_next_id :: proc(s:^Ai_Store) -> (id:u64,message:string) {
    if s.folder=="" {return 0,ai_store_error(s,"Chat history is not open")}
    for _ in 0..<1024 {
        if s.next_id==0 || s.next_id>=u64(max(i64)) {return 0,ai_store_error(s,"Chat identifiers are exhausted")}
        id=s.next_id;s.next_id+=1
        file,error:=os.open(ai_store_path(s,id,"log"),{.Write,.Create,.Excl},os.Permissions_Read_All+{.Write_User})
        if error==nil {os.close(file);return id,""}
        if os.exists(ai_store_path(s,id,"log")) {continue}
        return 0,ai_store_error(s,"Could not create a project chat file")
    }
    return 0,ai_store_error(s,"Could not reserve a chat identifier")
}

// Appends whole lines; a previous line cut by a crash is ended first, so that
// it stays a single invalid line.
@(private="file")
ai_store_append :: proc(s:^Ai_Store,id:u64,data:[]u8) -> string {
    if len(data)==0 {return ""}
    file,error:=os.open(ai_store_path(s,id,"log"),{.Read,.Write,.Create,.Append},os.Permissions_Read_All+{.Write_User})
    if error!=nil {return ai_store_error(s,"Could not open the project chat file")}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil {return ai_store_error(s,"Could not read the project chat file")}
    if size>0 {
        last:[1]u8
        if count,read_error:=os.read_at(file,last[:],size-1);read_error!=nil || count!=1 {return ai_store_error(s,"Could not read the project chat file")}
        if last[0]!='\n' {if _,write_error:=os.write(file,{'\n'});write_error!=nil {return ai_store_error(s,"Could not save the project chat")}}
    }
    if count,write_error:=os.write(file,data);write_error!=nil || count!=len(data) {return ai_store_error(s,"Could not save the project chat")}
    return ""
}

@(private="file")
ai_store_record :: proc(b:^strings.Builder,record:Ai_Store_Record) -> bool {
    if json.marshal_to_builder(b,record)!=nil {return false}
    strings.write_byte(b,'\n')
    return true
}

ai_store_save :: proc(s:^Ai_Store,c:^Ai_Conversation,t:^Ai_Transcript,first_sequence:int=-1) -> string {
    if s.folder=="" {return ai_store_error(s,"Chat history is not open")}
    if c.id==0 || c.id>=u64(max(i64)) {return ai_store_error(s,"Invalid chat identifier")}
    b:=strings.builder_make(context.temp_allocator)
    for index in 0..<t.count {
        if first_sequence>=0 && t.dropped+index<first_sequence {continue}
        text,kind:=ai_transcript_line(t,index)
        role:=kind==.Prompt?"user":kind==.Output?"assistant":"system"
        if !ai_store_record(&b,{sequence=u64(t.dropped+index),kind=int(kind),text=text,role=role}) {return ai_store_error(s,"Could not encode the project chat")}
    }
    if message:=ai_store_append(s,c.id,b.buf[:]);message!="" {return message}
    if last:=ai_transcript_last_answer(t);last!="" {
        plain:[AI_LAST_BYTES*2]u8
        c.last_len=copy(c.last[:],ai_utf8_cut(ai_entity_marks_plain(last,plain[:]),AI_LAST_BYTES))
    }
    meta:=Ai_Store_Meta{version=AI_STORE_VERSION,id=c.id,title=string(c.title[:c.title_len]),document=string(c.document[:c.document_len]),
        provider=string(c.provider[:c.provider_len]),model=string(c.model[:c.model_len]),effort=string(c.effort[:c.effort_len]),
        native_session=string(c.native_session[:c.native_session_len]),last=string(c.last[:c.last_len]),created_at=c.created_at,updated_at=c.updated_at,
        seconds=c.seconds,usage=c.usage}
    data,error:=json.marshal(meta,{},context.temp_allocator)
    if error!=nil {return ai_store_error(s,"Could not encode the project chat")}
    if serial.file_write_atomic(ai_store_path(s,c.id,"json"),data)!=.None {return ai_store_error(s,"Could not save the project chat")}
    if !ai_store_place(s,c) {return ai_store_error(s,"No memory for the project chats")}
    ai_index_update(s,c.id)
    return ""
}

ai_store_annotate :: proc(s:^Ai_Store,id,sequence:u64,role,event_type,tool,context_json:string) -> string {
    if s.folder=="" {return ai_store_error(s,"Chat history is not open")}
    b:=strings.builder_make(context.temp_allocator)
    if !ai_store_record(&b,{sequence=sequence,annotation=true,role=role,event_type=event_type,tool=tool,context_json=context_json}) {return ai_store_error(s,"Could not encode the project chat")}
    return ai_store_append(s,id,b.buf[:])
}

// The conversations whose titles have needle, or that found names.
ai_store_list :: proc(s:^Ai_Store,out:[]Ai_Conversation,document_path:string="",offset:int=0,needle:string="",found:[]u64={}) -> (count:int,message:string) {
    if s.folder=="" {return 0,ai_store_error(s,"Chat history is not open")}
    if offset<0 {return 0,ai_store_error(s,"Invalid chat history offset")}
    skipped:=0
    for &c in s.conversations {
        if count==len(out) {break}
        if document_path!="" && string(c.document[:c.document_len])!=document_path {continue}
        if !contains_fold(string(c.title[:c.title_len]),needle) && !slice.contains(found,c.id) {continue}
        if skipped<offset {skipped+=1;continue}
        out[count]=c;count+=1
    }
    return count,""
}

// A line of a message file, unless it is cut or invalid.
@(private)
ai_store_record_parse :: proc(line:string,allocator:runtime.Allocator) -> (record:Ai_Store_Record,ok:bool) {
    if line=="" {return}
    if json.unmarshal_string(line,&record,allocator=allocator)!=nil || record.sequence>=AI_STORE_SEQUENCES {return}
    if record.kind<0 || record.kind>int(Ai_Line_Kind.Note) {return}
    return record,true
}

ai_store_find :: proc(s:^Ai_Store,id:u64) -> ^Ai_Conversation {
    for &c in s.conversations {if c.id==id {return &c}}
    return nil
}

// The messages of a conversation by sequence, as the records of its file
// leave them, in the allocator.
@(private="file")
ai_store_read :: proc(s:^Ai_Store,id:u64,allocator:runtime.Allocator) -> (entries:[dynamic]Ai_Store_Entry,message:string) {
    if s.folder=="" {return nil,ai_store_error(s,"Chat history is not open")}
    path:=ai_store_path(s,id,"log",allocator)
    if !os.exists(path) {return nil,""}
    info,error:=os.stat(path,allocator)
    if error!=nil {return nil,ai_store_error(s,"Could not read the project chat file")}
    if info.size>AI_STORE_LOG_BYTES {return nil,ai_store_error(s,"The project chat file exceeds 256 MiB")}
    bytes,read_error:=os.read_entire_file(path,allocator)
    if read_error!=nil {return nil,ai_store_error(s,"Could not read the project chat file")}
    entries=make([dynamic]Ai_Store_Entry,allocator)
    rest:=string(bytes)
    for line in strings.split_lines_iterator(&rest) {
        record,valid:=ai_store_record_parse(line,allocator)
        if !valid {continue}
        sequence:=int(record.sequence)
        if record.annotation {
            if sequence>=len(entries) || !entries[sequence].present {continue}
            line:=&entries[sequence].line
            line.role,line.event_type,line.tool,line.context_json=record.role,record.event_type,record.tool,record.context_json
            continue
        }
        if sequence>=len(entries) {if resize(&entries,sequence+1)!=nil {return nil,ai_store_error(s,"No memory to read the project chat")}}
        entry:=&entries[sequence]
        if !entry.present {entry^={line={sequence=record.sequence,role=record.role,event_type="text"},present=true}}
        entry.line.kind,entry.line.text=Ai_Line_Kind(record.kind),record.text
    }
    return entries,""
}

ai_store_load :: proc(s:^Ai_Store,id:u64,t:^Ai_Transcript) -> string {
    scratch:vmem.Arena
    if vmem.arena_init_growing(&scratch)!=nil {return ai_store_error(s,"No memory to read the project chat")}
    defer vmem.arena_destroy(&scratch)
    entries,message:=ai_store_read(s,id,vmem.arena_allocator(&scratch))
    if message!="" {return message}
    t^={}
    first:=len(entries)
    for kept:=0;first>0 && kept<AI_TRANSCRIPT_LINES;first-=1 {if entries[first-1].present {kept+=1}}
    started:=false
    for &entry in entries[first:] {
        if !entry.present {continue}
        if !started {t.dropped=int(entry.line.sequence);started=true}
        ai_transcript_add(t,entry.line.text,entry.line.kind)
    }
    return ""
}

ai_store_page :: proc(s:^Ai_Store,id:u64,before_sequence:i64,out:[]Ai_Stored_Line,allocator:=context.temp_allocator) -> (count:int,message:string) {
    scratch:vmem.Arena
    if vmem.arena_init_growing(&scratch)!=nil {return 0,ai_store_error(s,"No memory to read the project chat")}
    defer vmem.arena_destroy(&scratch)
    entries:[dynamic]Ai_Store_Entry
    entries,message=ai_store_read(s,id,vmem.arena_allocator(&scratch))
    if message!="" {return 0,message}
    end:=before_sequence<0?len(entries):min(int(before_sequence),len(entries))
    for index:=end-1;index>=0 && count<len(out);index-=1 {
        entry:=entries[index]
        if !entry.present {continue}
        out[count]={sequence=entry.line.sequence,kind=entry.line.kind,text=strings.clone(entry.line.text,allocator),
            role=strings.clone(entry.line.role,allocator),event_type=strings.clone(entry.line.event_type,allocator),
            tool=strings.clone(entry.line.tool,allocator),context_json=strings.clone(entry.line.context_json,allocator)}
        count+=1
    }
    slice.reverse(out[:count])
    return count,""
}

// The sequence of the latest message marked as the turn of the user; -1 if none.
ai_store_latest_user_message :: proc(s:^Ai_Store,id:u64) -> i64 {
    scratch:vmem.Arena
    if vmem.arena_init_growing(&scratch)!=nil {return -1}
    defer vmem.arena_destroy(&scratch)
    entries,message:=ai_store_read(s,id,vmem.arena_allocator(&scratch))
    if message!="" {return -1}
    for index:=len(entries)-1;index>=0;index-=1 {
        if entries[index].present && entries[index].line.event_type=="user_message" {return i64(index)}
    }
    return -1
}
