package editor

import "core:c"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:unicode"
import "mirai:third_party/sqlite"

// The search index of the project chats: .mirai/ai/search.db, SQLite with
// FTS5, a cache of the message files that only the editor writes. Each chat
// keeps how many bytes of its log are indexed; a sync reads the rest, so the
// lines a save appends, or another editor of the project, come in on the next
// save or open. A database that is missing, corrupt or of another version is
// deleted and built again from the logs.
AI_INDEX_VERSION :: 1
AI_INDEX_BUSY_MS :: 1000 // what a write waits for another editor of the project
AI_SEARCH_HITS :: 50
AI_SEARCH_SNIPPET_WORDS :: 16
AI_HISTORY_HITS :: 256 // the lines a search of History reads, for the chats they are in
AI_SEARCH_NO_WORDS :: "The query has no words: pass words of the chats, an entity id or an asset path"

Ai_Search_Hit :: struct {
    conversation:u64,
    sequence:u64,
    kind:Ai_Line_Kind,
    snippet:string,
    score:f64, // BM25 as FTS5 gives it: the lower, the better
}

@(private="file")
AI_INDEX_SCHEMA :: `PRAGMA journal_mode=WAL;
BEGIN IMMEDIATE;
CREATE TABLE chat(id INTEGER PRIMARY KEY,log_bytes INTEGER NOT NULL);
CREATE TABLE line(id INTEGER PRIMARY KEY,chat INTEGER NOT NULL,sequence INTEGER NOT NULL,kind INTEGER NOT NULL,UNIQUE(chat,sequence));
CREATE VIRTUAL TABLE line_text USING fts5(text);
PRAGMA user_version=1;
COMMIT;`

#assert(AI_INDEX_VERSION==1,"AI_INDEX_SCHEMA sets the user_version")

@(private="file")
Ai_Index_Value :: union {i64,string}

@(private="file")
ai_index_fail :: proc(s:^Ai_Store,what:string) -> bool {
    reason:=string(sqlite.errmsg(s.index)) if s.index!=nil else "it could not be opened"
    message:=fmt.tprintf("%s: %s. Close the other editors of the project, or delete .mirai/ai/search.db: the editor builds it again from the chats",what,reason)
    s.index_error_len=copy(s.index_error[:],message)
    return false
}

@(private="file")
ai_index_exec :: proc(s:^Ai_Store,sql:cstring) -> bool {
    return sqlite.exec(s.index,sql,nil,nil,nil)==sqlite.OK
}

@(private="file")
ai_index_prepare :: proc(s:^Ai_Store,sql:string,values:..Ai_Index_Value) -> (statement:^sqlite.Stmt,ok:bool) {
    if sqlite.prepare_v2(s.index,raw_data(sql),c.int(len(sql)),&statement,nil)!=sqlite.OK {return nil,false}
    for value,index in values {
        code:c.int
        switch v in value {
        case i64:    code=sqlite.bind_int64(statement,c.int(index+1),v)
        case string: code=sqlite.bind_text(statement,c.int(index+1),raw_data(v) if v!="" else raw_data(string("\x00")),c.int(len(v)),sqlite.TRANSIENT)
        }
        if code!=sqlite.OK {sqlite.finalize(statement);return nil,false}
    }
    return statement,true
}

// Runs a statement that returns no rows, or whose rows are not read.
@(private="file")
ai_index_run :: proc(s:^Ai_Store,sql:string,values:..Ai_Index_Value) -> bool {
    statement,ok:=ai_index_prepare(s,sql,..values)
    if !ok {return false}
    defer sqlite.finalize(statement)
    for {
        switch sqlite.step(statement) {
        case sqlite.ROW:  continue
        case sqlite.DONE: return true
        case:             return false
        }
    }
}

@(private="file")
ai_index_text :: proc(statement:^sqlite.Stmt,column:c.int) -> string {
    bytes:=sqlite.column_bytes(statement,column)
    text:=sqlite.column_text(statement,column)
    return string(text[:bytes]) if text!=nil else ""
}

ai_index_close :: proc(s:^Ai_Store) {
    if s.index!=nil {sqlite.close_v2(s.index);s.index=nil}
}

// Whether the last failure says that the file is no database of this
// version, or a broken one: what is built again, unlike a busy lock.
@(private="file")
ai_index_broken :: proc(s:^Ai_Store) -> bool {
    code:=sqlite.errcode(s.index)&0xff
    return code==sqlite.CORRUPT || code==sqlite.NOTADB
}

// Opens the index of the chats of the project, building it again from the
// logs when it cannot be used as it is. Without it the store still works and
// a search says why it is unavailable.
ai_index_open :: proc(s:^Ai_Store) {
    ai_index_close(s)
    s.index_error_len=0
    for attempt in 0..<2 {
        state:=ai_index_connect(s)
        if state==.Ready && ai_index_sync_all(s) {return}
        if state==.Failed || state==.Ready && !ai_index_broken(s) || attempt==1 {
            ai_index_fail(s,"The chat search index could not be built")
            ai_index_close(s)
            return
        }
        ai_index_close(s)
        ai_index_remove(s)
    }
}

@(private="file")
ai_index_remove :: proc(s:^Ai_Store) {
    for suffix in ([]string{"","-wal","-shm","-journal"}) {
        path:=fmt.tprintf("%s%s",s.index_path,suffix)
        if os.exists(path) {os.remove(path)}
    }
}

@(private="file")
Ai_Index_State :: enum {Ready,Rebuild,Failed}

// Connects to the database and makes sure it holds the schema of this
// version: a new file gets it; one of another version, or that is not a
// database, is to be built again.
@(private="file")
ai_index_connect :: proc(s:^Ai_Store) -> Ai_Index_State {
    path:=strings.clone_to_cstring(s.index_path,context.temp_allocator)
    if sqlite.open_v2(path,&s.index,sqlite.OPEN_READWRITE|sqlite.OPEN_CREATE|sqlite.OPEN_NOMUTEX,nil)!=sqlite.OK {return .Failed}
    sqlite.busy_timeout(s.index,AI_INDEX_BUSY_MS)
    version:=i64(-1)
    statement,ok:=ai_index_prepare(s,"PRAGMA user_version")
    if ok {
        if sqlite.step(statement)==sqlite.ROW {version=sqlite.column_int64(statement,0)}
        sqlite.finalize(statement)
    }
    switch {
    case version==AI_INDEX_VERSION && ai_index_exec(s,"PRAGMA journal_mode=WAL"): return .Ready
    case version==0 && ai_index_exec(s,AI_INDEX_SCHEMA):                           return .Ready
    case sqlite.errcode(s.index)&0xff==sqlite.BUSY:                                return .Failed
    }
    return .Rebuild
}

// Brings every chat of the store up to its log, and forgets the chats whose
// files are gone.
@(private="file")
ai_index_sync_all :: proc(s:^Ai_Store) -> bool {
    statement,ok:=ai_index_prepare(s,"SELECT id FROM chat")
    if !ok {return false}
    gone:=make([dynamic]i64,context.temp_allocator)
    for {
        code:=sqlite.step(statement)
        if code==sqlite.DONE {break}
        if code!=sqlite.ROW {sqlite.finalize(statement);return false}
        id:=sqlite.column_int64(statement,0)
        if ai_store_find(s,u64(id))==nil {append(&gone,id)}
    }
    sqlite.finalize(statement)
    for id in gone {
        if !ai_index_exec(s,"BEGIN IMMEDIATE") {return false}
        if !ai_index_forget(s,id) || !ai_index_run(s,"DELETE FROM chat WHERE id=?1",id) || !ai_index_exec(s,"COMMIT") {
            ai_index_exec(s,"ROLLBACK");return false
        }
    }
    for &conversation in s.conversations {
        if !ai_index_sync(s,conversation.id) {return false}
    }
    return true
}

@(private="file")
ai_index_forget :: proc(s:^Ai_Store,chat:i64) -> bool {
    return ai_index_run(s,"DELETE FROM line_text WHERE rowid IN (SELECT id FROM line WHERE chat=?1)",chat) &&
        ai_index_run(s,"DELETE FROM line WHERE chat=?1",chat)
}

// Indexes the lines of a chat's log after the bytes indexed before; a log
// shorter than those was written again, and is indexed whole. A line cut at
// the end waits for the save that ends it.
@(private="file")
ai_index_sync :: proc(s:^Ai_Store,id:u64) -> bool {
    chat:=i64(id)
    indexed:=i64(0)
    statement,ok:=ai_index_prepare(s,"SELECT log_bytes FROM chat WHERE id=?1",chat)
    if !ok {return false}
    code:=sqlite.step(statement)
    if code==sqlite.ROW {indexed=sqlite.column_int64(statement,0)}
    sqlite.finalize(statement)
    if code!=sqlite.ROW && code!=sqlite.DONE {return false}
    size:=i64(0)
    if info,error:=os.stat(ai_store_path(s,id,"log"),context.temp_allocator);error==nil {size=info.size}
    if size==indexed {return true}
    restart:=size<indexed
    if restart {indexed=0}
    scratch:vmem.Arena
    if vmem.arena_init_growing(&scratch)!=nil {return false}
    defer vmem.arena_destroy(&scratch)
    allocator:=vmem.arena_allocator(&scratch)
    // A log the store cannot read either stays out of the index, which the next sync tries again.
    data:[]u8
    if size>indexed {
        if size-indexed>AI_STORE_LOG_BYTES {return true}
        file,error:=os.open(ai_store_path(s,id,"log"),{.Read})
        if error!=nil {return true}
        defer os.close(file)
        data=make([]u8,int(size-indexed),allocator)
        if count,read_error:=os.read_at(file,data,indexed);read_error!=nil || count!=len(data) {return true}
    }
    end:=strings.last_index_byte(string(data),'\n')+1
    // The latest record of each sequence, as the store reads them.
    Line :: struct {sequence:u64,kind:Ai_Line_Kind,text:string}
    lines:=make([dynamic]Line,allocator)
    at:=make(map[u64]int,allocator=allocator)
    rest:=string(data[:end])
    for line in strings.split_lines_iterator(&rest) {
        record,valid:=ai_store_record_parse(line,allocator)
        if !valid || record.annotation {continue}
        if index,found:=at[record.sequence];found {lines[index].kind,lines[index].text=Ai_Line_Kind(record.kind),record.text;continue}
        at[record.sequence]=len(lines)
        append(&lines,Line{record.sequence,Ai_Line_Kind(record.kind),record.text})
    }
    if !ai_index_exec(s,"BEGIN IMMEDIATE") {return false}
    done:=!restart || ai_index_forget(s,chat)
    for line in lines {
        if !done {break}
        upsert,prepared:=ai_index_prepare(s,"INSERT INTO line(chat,sequence,kind) VALUES(?1,?2,?3) ON CONFLICT(chat,sequence) DO UPDATE SET kind=excluded.kind RETURNING id",chat,i64(line.sequence),i64(line.kind))
        if !prepared {done=false;break}
        row:=i64(0)
        if sqlite.step(upsert)==sqlite.ROW {row=sqlite.column_int64(upsert,0)} else {done=false}
        sqlite.finalize(upsert)
        done=done && ai_index_run(s,"DELETE FROM line_text WHERE rowid=?1",row)
        if done && line.text!="" {done=ai_index_run(s,"INSERT INTO line_text(rowid,text) VALUES(?1,?2)",row,line.text)}
    }
    done=done && ai_index_run(s,"INSERT INTO chat(id,log_bytes) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET log_bytes=excluded.log_bytes",chat,indexed+i64(end))
    if !done || !ai_index_exec(s,"COMMIT") {ai_index_exec(s,"ROLLBACK");return false}
    return true
}

// After a save of a chat: what its log gained. An index that fails is built
// again; the chats themselves are saved already.
@(private)
ai_index_update :: proc(s:^Ai_Store,id:u64) {
    if s.index==nil || ai_index_sync(s,id) {return}
    if ai_index_broken(s) {ai_index_rebuild(s);return}
    // What failed stays unindexed and the next save tries again from there.
    ai_index_fail(s,"The chat search index could not be updated")
}

@(private="file")
ai_index_rebuild :: proc(s:^Ai_Store) {
    ai_index_close(s)
    ai_index_remove(s)
    ai_index_open(s)
}

// The FTS5 query of what a person or an agent typed: each word is a phrase,
// quoted so that no character is syntax, and all of them must be there; OR
// between two words takes either. An asset path or a method is a phrase of
// its parts, in order. With prefix the last word also matches the start of
// a longer one, as a search box that is being typed in does.
ai_index_match :: proc(query:string,prefix:bool,allocator:=context.temp_allocator) -> string {
    b:=strings.builder_make(allocator)
    rest:=query
    words:=0
    pending_or:=false
    for word in strings.fields_iterator(&rest) {
        if word=="OR" {pending_or=words>0;continue}
        searchable:=false
        // What FTS5 keeps of a word are its letters and numbers.
        for r in word {if unicode.is_letter(r) || unicode.is_number(r) {searchable=true;break}}
        if !searchable {continue}
        if words>0 {strings.write_string(&b," OR " if pending_or else " ")}
        pending_or=false
        strings.write_byte(&b,'"')
        for r in word {
            if r=='"' {strings.write_byte(&b,'"')}
            strings.write_rune(&b,r)
        }
        strings.write_byte(&b,'"')
        words+=1
    }
    if words==0 {return ""}
    if prefix {strings.write_byte(&b,'*')}
    return strings.to_string(b)
}

// The lines of the chats that match a query, the best first, each with a
// snippet whose matches go between the marks. With a conversation, only its
// own. A database found corrupt is built again and the search runs once more.
ai_store_search :: proc(s:^Ai_Store,query:string,out:[]Ai_Search_Hit,conversation:u64=0,prefix:=false,marks:=[2]string{"",""},allocator:=context.temp_allocator) -> (count:int,message:string) {
    if s.folder=="" {return 0,"Chat history is not open"}
    match:=ai_index_match(query,prefix)
    if match=="" {return 0,AI_SEARCH_NO_WORDS}
    if len(out)==0 {return 0,""}
    if s.index==nil {ai_index_open(s)}
    for attempt in 0..<2 {
        if s.index==nil {break}
        statement,ok:=ai_index_prepare(s,`SELECT line.chat,line.sequence,line.kind,snippet(line_text,0,?2,?3,'…',?4),rank
FROM line_text JOIN line ON line.id=line_text.rowid
WHERE line_text MATCH ?1 AND (?5=0 OR line.chat=?5) ORDER BY rank LIMIT ?6`,
            match,marks[0],marks[1],i64(AI_SEARCH_SNIPPET_WORDS),i64(conversation),i64(len(out)))
        code:=c.int(sqlite.DONE)
        count=0
        if ok {
            for {
                code=sqlite.step(statement)
                if code!=sqlite.ROW {break}
                kind:=sqlite.column_int64(statement,2)
                if kind<0 || kind>i64(Ai_Line_Kind.Note) {continue}
                out[count]={conversation=u64(sqlite.column_int64(statement,0)),sequence=u64(sqlite.column_int64(statement,1)),kind=Ai_Line_Kind(kind),
                    snippet=strings.clone(ai_index_text(statement,3),allocator),score=sqlite.column_double(statement,4)}
                count+=1
            }
            sqlite.finalize(statement)
        }
        if ok && code==sqlite.DONE {return count,""}
        // A file that stopped being a database, or broke, is built again.
        if attempt==0 && ai_index_broken(s) {ai_index_rebuild(s);continue}
        return 0,fmt.tprintf("The chat search failed: %s",string(sqlite.errmsg(s.index)))
    }
    return 0,fmt.tprintf("Chat search is unavailable. %s",string(s.index_error[:s.index_error_len]))
}
