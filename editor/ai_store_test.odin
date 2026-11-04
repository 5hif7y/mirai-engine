package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:project"

@(private="file")
ai_store_test_root :: proc(name:string) -> string {
    return project.path_absolute(fmt.tprintf(".mirai/test-ai-store-%s-%d",name,os.get_pid()),context.temp_allocator)
}

@(private="file")
ai_store_test_conversation :: proc(id:u64,document:string) -> Ai_Conversation {
    c:=Ai_Conversation{id=id,created_at=100,updated_at=200}
    ai_conversation_set_text(c.title[:],&c.title_len,"Player questions")
    ai_conversation_set_text(c.document[:],&c.document_len,document)
    ai_conversation_set_text(c.provider[:],&c.provider_len,"codex")
    ai_conversation_set_text(c.model[:],&c.model_len,"gpt-6-luna")
    ai_conversation_set_text(c.effort[:],&c.effort_len,"low")
    ai_conversation_set_text(c.native_session[:],&c.native_session_len,"native-session-1")
    return c
}

@(test)
ai_store_reopens_chats_with_metadata_and_changed_stream_text :: proc(t:^testing.T) {
    root:=ai_store_test_root("roundtrip")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    id,message:=ai_store_next_id(&store)
    testing.expect_value(t,message,"")
    testing.expect_value(t,id,u64(1))
    c:=ai_store_test_conversation(id,"scene/main.scene")
    // What the agent spent comes back with the chat.
    c.seconds,c.usage=12.5,{input=1200,output=340,cache_read=9000,total=10540,context_used=48000,context_size=200000,cost=0.25}
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"What's the player's health? '; DROP TABLE conversations; --",.Prompt)
    ai_transcript_add(&transcript,"The player",.Output)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    testing.expect_value(t,ai_store_annotate(&store,id,0,"user","context","",`{"player":4}`),"")
    transcript={}
    ai_transcript_add(&transcript,"What's the player's health? '; DROP TABLE conversations; --",.Prompt)
    ai_transcript_add(&transcript,"The player's health is 100.",.Output)
    c.updated_at=300
    testing.expect_value(t,ai_store_save(&store,&c,&transcript,1),"")
    ai_store_close(&store)
    testing.expect(t,os.is_file(project.path(root,".mirai/ai/chats/1.json",allocator=context.temp_allocator)))
    testing.expect_value(t,ai_store_open(&store,root),"")
    conversations:[8]Ai_Conversation
    count,list_message:=ai_store_list(&store,conversations[:])
    testing.expect_value(t,list_message,"")
    testing.expect_value(t,count,1)
    testing.expect_value(t,conversations[0],c)
    testing.expect_value(t,string(conversations[0].last[:conversations[0].last_len]),"The player's health is 100.")
    restored:Ai_Transcript
    testing.expect_value(t,ai_store_load(&store,id,&restored),"")
    testing.expect_value(t,restored.count,2)
    testing.expect_value(t,restored.dropped,0)
    text,kind:=ai_transcript_line(&restored,1)
    testing.expect_value(t,text,"The player's health is 100.")
    testing.expect_value(t,kind,Ai_Line_Kind.Output)
    lines:[4]Ai_Stored_Line
    line_count,page_message:=ai_store_page(&store,id,-1,lines[:])
    testing.expect_value(t,page_message,"")
    testing.expect_value(t,line_count,2)
    testing.expect_value(t,lines[0].role,"user")
    testing.expect_value(t,lines[0].event_type,"context")
    testing.expect_value(t,lines[0].context_json,`{"player":4}`)
    next_id,next_message:=ai_store_next_id(&store)
    testing.expect_value(t,next_message,"")
    testing.expect_value(t,next_id,u64(2))
}

@(test)
ai_store_filters_documents_and_keeps_projects_isolated :: proc(t:^testing.T) {
    root:=ai_store_test_root("isolation")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    first,second:Ai_Store
    defer ai_store_close(&first)
    defer ai_store_close(&second)
    testing.expect_value(t,ai_store_open(&first,project.path(root,"one",allocator=context.temp_allocator)),"")
    testing.expect_value(t,ai_store_open(&second,project.path(root,"two",allocator=context.temp_allocator)),"")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Hello",.Prompt)
    a:=ai_store_test_conversation(1,"scene/one.scene")
    b:=ai_store_test_conversation(2,"scene/two.scene")
    testing.expect_value(t,ai_store_save(&first,&a,&transcript),"")
    testing.expect_value(t,ai_store_save(&first,&b,&transcript),"")
    conversations:[8]Ai_Conversation
    count,message:=ai_store_list(&first,conversations[:],"scene/two.scene")
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,1)
    testing.expect_value(t,conversations[0].id,u64(2))
    count,message=ai_store_list(&second,conversations[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,0)
    next_id,next_message:=ai_store_next_id(&first)
    testing.expect_value(t,next_message,"")
    testing.expect_value(t,next_id,u64(3))
    other_id,other_message:=ai_store_next_id(&second)
    testing.expect_value(t,other_message,"")
    testing.expect_value(t,other_id,u64(1))
}

@(test)
ai_store_preserves_messages_beyond_the_transcript_cache :: proc(t:^testing.T) {
    root:=ai_store_test_root("retention")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    c:=ai_store_test_conversation(1,"scene/main.scene")
    transcript:Ai_Transcript
    for index in 0..<900 {
        text:=fmt.tprintf("Line %04d: a long streamed transcript keeps its complete earlier history in the project database.",index)
        ai_transcript_add(&transcript,text)
        if (index+1)%40==0 {testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")}
    }
    testing.expect(t,transcript.dropped>0)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    testing.expect_value(t,ai_store_annotate(&store,1,895,"assistant","tool_call","mirai.scene.inspect",`{"selection":[1]}`),"")
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    restored:Ai_Transcript
    testing.expect_value(t,ai_store_load(&store,1,&restored),"")
    testing.expect(t,restored.dropped>0)
    testing.expect_value(t,restored.count+restored.dropped,900)
    last,_:=ai_transcript_line(&restored,restored.count-1)
    testing.expect(t,strings.has_prefix(last,"Line 0899:"))
    old:[16]Ai_Stored_Line
    count,message:=ai_store_page(&store,1,10,old[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,10)
    testing.expect_value(t,old[0].sequence,u64(0))
    testing.expect(t,strings.has_prefix(old[0].text,"Line 0000:"))
    testing.expect_value(t,old[9].sequence,u64(9))
    latest:[16]Ai_Stored_Line
    count,message=ai_store_page(&store,1,-1,latest[:])
    testing.expect_value(t,message,"")
    testing.expect_value(t,count,16)
    testing.expect_value(t,latest[11].sequence,u64(895))
    testing.expect_value(t,latest[11].tool,"mirai.scene.inspect")
    testing.expect_value(t,latest[11].context_json,`{"selection":[1]}`)
}

@(private="file")
ai_store_test_hits :: proc(t:^testing.T,store:^Ai_Store,query:string,conversation:u64=0) -> []Ai_Search_Hit {
    hits:=make([]Ai_Search_Hit,8,context.temp_allocator)
    count,message:=ai_store_search(store,query,hits,conversation,marks={"[","]"})
    testing.expectf(t,message=="","search %q: %s",query,message)
    return hits[:count]
}

@(test)
ai_store_search_finds_words_ids_and_paths_ranked :: proc(t:^testing.T) {
    root:=ai_store_test_root("search")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    a:=ai_store_test_conversation(1,"scene/main.scene")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Hang a lantern over the door",.Prompt)
    ai_transcript_add(&transcript,"The player",.Output)
    ai_transcript_add(&transcript,"Tool: scene.set Crate · ref 0x000000010000002a materials/floor.mat · +0.4 s · 2.0 ms",.Note)
    testing.expect_value(t,ai_store_save(&store,&a,&transcript),"")
    // The stream grows a line already saved: its later record replaces it.
    transcript={}
    ai_transcript_add(&transcript,"Hang a lantern over the door",.Prompt)
    ai_transcript_add(&transcript,"The player's lantern, the lantern of the quest, hangs at the door.",.Output)
    testing.expect_value(t,ai_store_save(&store,&a,&transcript,1),"")
    b:=ai_store_test_conversation(2,"scene/main.scene")
    transcript={}
    ai_transcript_add(&transcript,"Is there a lantern among the many props that the cellar of the old house keeps for later?",.Prompt)
    testing.expect_value(t,ai_store_save(&store,&b,&transcript),"")

    hits:=ai_store_test_hits(t,&store,"lantern")
    testing.expect_value(t,len(hits),3)
    if len(hits)==3 {
        testing.expect(t,hits[0].conversation==1 && hits[0].sequence==1 && hits[0].kind==.Output,"the line that says it most, and short, ranks first")
        testing.expect(t,hits[0].score<=hits[1].score && hits[1].score<=hits[2].score)
        testing.expect(t,hits[2].conversation==2,"a long line that says it once ranks last")
        testing.expectf(t,strings.contains(hits[0].snippet,"[lantern]"),"the snippet marks what matched, got %q",hits[0].snippet)
    }
    hits=ai_store_test_hits(t,&store,"player")
    testing.expect(t,len(hits)==1 && strings.contains(hits[0].snippet,"quest"),"a replaced line is indexed once, with its latest text")
    hits=ai_store_test_hits(t,&store,"0x000000010000002a")
    testing.expect(t,len(hits)==1 && hits[0].kind==.Note && hits[0].sequence==2,"a tool note is found by the id of its entity")
    hits=ai_store_test_hits(t,&store,"materials/floor.mat")
    testing.expect(t,len(hits)==1 && hits[0].sequence==2,"and by the path of its asset")
    hits=ai_store_test_hits(t,&store,"scene.set")
    testing.expect(t,len(hits)==1,"and by its method")
    hits=ai_store_test_hits(t,&store,"lantern",2)
    testing.expect(t,len(hits)==1 && hits[0].conversation==2,"a conversation narrows the search to its own lines")
    hits=ai_store_test_hits(t,&store,"door cellar")
    testing.expect_value(t,len(hits),0)
    hits=ai_store_test_hits(t,&store,"door OR cellar")
    testing.expect_value(t,len(hits),3)
    hits=ai_store_test_hits(t,&store,"dragon")
    testing.expect_value(t,len(hits),0)
    prefixed:[4]Ai_Search_Hit
    count,message:=ai_store_search(&store,"lant",prefixed[:],prefix=true)
    testing.expect(t,message=="" && count==3,"a prefix matches the start of a word")
    for query in ([]string{"",`"; DROP TABLE line; --`,"  · - "}) {
        count,message=ai_store_search(&store,query,prefixed[:])
        if query==`"; DROP TABLE line; --` {
            testing.expect(t,message=="" && count==0,"quotes and SQL in a query are words")
        } else {
            testing.expect_value(t,message,AI_SEARCH_NO_WORDS)
        }
    }
}

@(test)
ai_store_search_follows_saves_and_rebuilds_from_the_logs :: proc(t:^testing.T) {
    root:=ai_store_test_root("search-rebuild")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    store:Ai_Store
    defer ai_store_close(&store)
    testing.expect_value(t,ai_store_open(&store,root),"")
    c:=ai_store_test_conversation(1,"scene/main.scene")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Paint the barn red",.Prompt)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),1)
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"windmill")),0)
    ai_transcript_add(&transcript,"The windmill turns by the barn now.",.Output)
    testing.expect_value(t,ai_store_save(&store,&c,&transcript,1),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"windmill")),1)
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),2)
    index_path:=project.path(root,".mirai/ai/search.db",allocator=context.temp_allocator)
    testing.expect(t,os.is_file(index_path))

    // Deleted: built again from the logs when the project opens.
    ai_store_close(&store)
    testing.expect(t,os.remove(index_path)==nil)
    testing.expect_value(t,ai_store_open(&store,root),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),2)

    // Lines another editor appended while this one was closed come in on open.
    ai_store_close(&store)
    other:Ai_Store
    testing.expect_value(t,ai_store_open(&other,root),"")
    ai_transcript_add(&transcript,"A scarecrow guards the field.",.Output)
    ai_index_close(&other)
    testing.expect_value(t,ai_store_save(&other,&c,&transcript,2),"")
    ai_store_close(&other)
    testing.expect_value(t,ai_store_open(&store,root),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"scarecrow")),1)

    // Corrupt: no database any more, it is built again.
    ai_store_close(&store)
    for suffix in ([]string{"-wal","-shm"}) {os.remove(fmt.tprintf("%s%s",index_path,suffix))}
    garbage:=strings.repeat("not a database ",512,context.temp_allocator)
    testing.expect(t,os.write_entire_file(index_path,garbage)==nil)
    testing.expect_value(t,ai_store_open(&store,root),"")
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"barn")),2)
    testing.expect_value(t,len(ai_store_test_hits(t,&store,"scarecrow")),1)
}

@(test)
ai_store_search_feeds_history_by_title_or_by_what_chats_said :: proc(t:^testing.T) {
    root:=ai_store_test_root("history-search")
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    m:=new(Ai);defer free(m)
    document:=new(Document);defer free(document)
    document.path_length=copy(document.path[:],"scene/main.scene")
    s:=Session{ai=m,document=document}
    defer ai_store_close(&m.store)
    testing.expect_value(t,ai_store_open(&m.store,root),"")
    titled:=ai_store_test_conversation(1,"scene/main.scene")
    ai_conversation_set_text(titled.title[:],&titled.title_len,"Lanterns of the harbor")
    said:=ai_store_test_conversation(2,"scene/main.scene")
    transcript:Ai_Transcript
    ai_transcript_add(&transcript,"Light the pier",.Prompt)
    ai_transcript_add(&transcript,"Hung a [lantern](entity:0x2a) on the pier.",.Output)
    testing.expect_value(t,ai_store_save(&m.store,&said,&transcript),"")
    transcript={}
    ai_transcript_add(&transcript,"Name the boats",.Prompt)
    testing.expect_value(t,ai_store_save(&m.store,&titled,&transcript),"")
    ai_history_refresh(&s,0,"lant")
    testing.expect_value(t,m.history_count,2)
    for &c in m.history[:m.history_count] {
        last:=string(c.last[:c.last_len])
        if c.id==2 {testing.expectf(t,strings.contains(last,"Hung a lantern on the pier"),"a chat found by its lines shows what matched, got %q",last)}
    }
    ai_history_refresh(&s,0,"boats")
    testing.expect(t,m.history_count==1 && m.history[0].id==1)
    ai_history_refresh(&s,0,"·")
    testing.expect_value(t,m.history_count,0)
}
