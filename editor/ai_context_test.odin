package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"

Ai_Context_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    time:core.Time,
}

Ai_Context_Test_Editor :: struct {api:Api}

@(private="file")
ai_context_test_world_init :: proc(w:^Ai_Context_Test_World) {
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id")
    core.table_init(&w.names,"Name")
    core.table_init(&w.transforms,"Transform")
    core.table_init(&w.parents,"Parent")
}

@(private="file")
ai_context_test_world_close :: proc(w:^Ai_Context_Test_World) {
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms);core.table_destroy(&w.parents)
    core.entities_destroy(&w.entities)
}

@(test)
ai_context_continues_project_chats_and_passes_instructions_skills_and_live_play :: proc(t:^testing.T) {
    root:=project.path_absolute(fmt.tprintf(".mirai/test-ai-context-%d",os.get_pid()),context.temp_allocator)
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    defer os.remove_all(root)
    engine:=project.path(root,"engine",allocator=context.temp_allocator)
    for skill in ([2]string{"mirai-gameplay","mirai-rendering"}) {
        folder:=project.path(engine,".agents/skills",skill,allocator=context.temp_allocator)
        os.make_directory_all(folder)
        testing.expect(t,os.write_entire_file(project.path(folder,"SKILL.md",allocator=context.temp_allocator),"# Skill\n")==nil)
    }
    tool:=project.tool_file(engine,context.temp_allocator)
    os.make_directory_all(project.path(engine,"bin",allocator=context.temp_allocator))
    testing.expect(t,os.write_entire_file(tool,"")==nil)
    world,live:Ai_Context_Test_World
    ai_context_test_world_init(&world);ai_context_test_world_init(&live)
    defer ai_context_test_world_close(&world);defer ai_context_test_world_close(&live)
    tables:=[4]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Ai_Context_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Ai_Context_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Ai_Context_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Ai_Context_Test_World,parents)},
    }
    storages:=[2]core.Storage_Info{
        {name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(Ai_Context_Test_Editor,api)},
        {name="Time",type=core.Time,info=type_info_of(core.Time),offset=offset_of(Ai_Context_Test_World,time)},
    }
    info:=core.World_Info{entities=offset_of(Ai_Context_Test_World,entities),tables=tables[:],storages=storages[:]}
    state:=Api_State{server={port=7940}}
    editor_world:=Ai_Context_Test_Editor{api={state=&state}}
    app:host.App
    viewport:=Viewport{size={800,600},window={800,600}}
    selection:Selection
    defer delete(selection.entities)
    edits:Edits
    document:Document
    document.path_length=copy(document.path[:],"scenes/main.scene")
    ai:=new(Ai);defer free(ai);ai_connections_reset(ai)
    ai.initialized=true
    for &worker in ai.workers {worker.task=-1}
    base.text_set(ai.connections[AI_CODEX].model[:],"gpt-6-luna")
    base.text_set(ai.connections[AI_CODEX].effort[:],"low")
    testing.expect_value(t,ai_store_open(&ai.store,root),"")
    defer ai_store_close(&ai.store)
    s:=Session{info=&info,edit_world=&world,editor_world=&editor_world,app=&app,viewport=&viewport,
        selection=&selection,edits=&edits,document=&document,ai=ai,project_root=root,engine_root=engine,has_project=true}
    testing.expect_value(t,ai_instructions_write(&s,"Explain the player's current state precisely."),"")
    selected_entity:=core.create(&world.entities)
    core.add(&world.ids,selected_entity,{value=33})
    core.add(&world.transforms,selected_entity,core.TRANSFORM_IDENTITY)
    core.table_settle(&world.ids,&world.entities);core.table_settle(&world.transforms,&world.entities)
    selection_set(&selection,{selected_entity})
    first,message:=ai_task_create(&s,ai,{0,0,800,600},"USER_REQUEST_SENT_SEPARATELY","codex")
    if !testing.expect(t,first!=nil && message=="") {return}
    testing.expect_value(t,first.id,1)
    testing.expect(t,first.context_count==1 && first.context_ids[0]==33,"sending freezes the selected authors for task outlines")
    message_file,message_error:=os.read_entire_file(ai_task_path(&s,first,AI_FILE_MESSAGE),context.temp_allocator)
    testing.expect(t,message_error==nil && string(message_file)=="USER_REQUEST_SENT_SEPARATELY","the message waits in the folder of the turn")
    testing.expect_value(t,string(first.conversation.document[:first.conversation.document_len]),"scenes/main.scene")
    testing.expect_value(t,string(first.conversation.model[:first.conversation.model_len]),"gpt-6-luna")
    prompt_file,read_error:=os.read_entire_file(ai_task_path(&s,first,AI_FILE_PROMPT),context.temp_allocator)
    testing.expect(t,read_error==nil)
    prompt:=string(prompt_file)
    testing.expect(t,!strings.contains(prompt,"USER_REQUEST_SENT_SEPARATELY"))
    testing.expect(t,strings.contains(prompt,"Explain the player's current state precisely."))
    // The agent works on the game: of the engine it gets the gameplay skill only, and it keeps the memory of the project.
    testing.expect(t,strings.contains(prompt,"mirai-gameplay/SKILL.md") && !strings.contains(prompt,"mirai-rendering") && !strings.contains(prompt,project.path(engine,"AGENTS.md",allocator=context.temp_allocator)))
    testing.expect(t,strings.contains(prompt,project.path(s.project_root,AI_PROJECT_MEMORY,allocator=context.temp_allocator)),"the agent keeps the AGENTS.md of the project")
    testing.expect(t,strings.contains(prompt,"`scene_batch`") && strings.contains(prompt,"`finish`"),"the tools are named as the agent calls them")
    testing.expect(t,strings.contains(prompt,"0000000000000021 |") && strings.contains(prompt,"(selected)"),"the entities in view are in the instructions")
    testing.expect(t,strings.contains(prompt,"MCP server `mirai`"))
    rpc:=strings.concatenate({"`",tool," rpc <method> '<json>'`"},context.temp_allocator)
    testing.expect(t,strings.contains(prompt,rpc) && strings.contains(prompt,"write and run a script") && !strings.contains(prompt,"only through"),"scripts call the API through the client")
    for hidden in ([?]string{"--task","--port","X-Mirai-Ai-Task",api.AI_TASK_VARIABLE,"/rpc","carry the turn"}) {
        testing.expectf(t,!strings.contains(prompt,hidden),"the agent is not told how its calls reach its turn: %s",hidden)
    }
    mcp_file,mcp_error:=os.read_entire_file(ai_task_path(&s,first,AI_FILE_MCP),context.temp_allocator)
    testing.expect(t,mcp_error==nil && !strings.contains(string(mcp_file),`X-Mirai-Plugins`),"a turn gets the core tools and call: a plugin it asks for through call")
    testing.expect(t,strings.contains(prompt,"Respond in English."))
    testing.expect(t,strings.contains(prompt,"MCP tool `finish` exactly once") && !strings.contains(prompt,"with `id`") && strings.contains(prompt,"omit `response`"))
    testing.expect(t,!strings.contains(prompt,"Image of the region:") && !strings.contains(prompt,"Image of the whole window:"))
    context_file,context_error:=os.read_entire_file(ai_task_path(&s,first,AI_FILE_CONTEXT),context.temp_allocator)
    testing.expect(t,context_error==nil && !strings.contains(string(context_file),"USER_REQUEST_SENT_SEPARATELY"))
    first.state=.Done
    first.finish_called=true
    selection_clear(&selection)
    ai_conversation_set_text(first.conversation.native_session[:],&first.conversation.native_session_len,"persisted-native-session")
    ai_transcript_add(&first.transcript,"The prior answer",.Output)
    ai_task_dirty(first);ai_task_persist(&s,first)
    previous_lines:=first.transcript.count
    continued,continue_error:=ai_task_create(&s,ai,{0,0,800,600},"Follow up","codex",first.id)
    if !testing.expect(t,continued==first && continue_error=="") {return}
    testing.expect_value(t,ai.task_count,1)
    testing.expect(t,!continued.finish_called,"continuing a conversation requires its own finish call")
    testing.expect(t,continued.context_count==0,"each turn replaces its sent selection")
    testing.expect_value(t,continued.transcript.count,previous_lines+1)
    testing.expect_value(t,string(continued.conversation.native_session[:continued.conversation.native_session_len]),"persisted-native-session")
    continued.state=.Done
    wrong_provider,provider_error:=ai_task_create(&s,ai,{0,0,800,600},"Follow up","claude",first.id)
    testing.expect(t,wrong_provider==nil && provider_error!="")
    document.path_length=copy(document.path[:],"scenes/other.scene")
    wrong_document,document_error:=ai_task_create(&s,ai,{0,0,800,600},"Follow up","codex",first.id)
    testing.expect(t,wrong_document==nil && document_error!="")
    document.path_length=copy(document.path[:],"scenes/main.scene")
    player:=core.create(&live.entities)
    core.add(&live.ids,player,{value=7});core.add(&live.names,player,core.name_make("Live player"))
    core.add(&live.transforms,player,{position={42,0,0},rotation=1,scale={1,1,1}})
    core.table_settle(&live.ids,&live.entities);core.table_settle(&live.names,&live.entities);core.table_settle(&live.transforms,&live.entities)
    selection_set(&selection,{player})
    s.mode=.Play;s.runs[0]={world=&live}
    playing,play_error:=ai_task_create(&s,ai,{0,0,800,600},"Where am I?","codex",first.id)
    if !testing.expect(t,playing!=nil && play_error=="") {return}
    testing.expect(t,playing.play)
    play_context,play_read_error:=os.read_entire_file(ai_task_path(&s,playing,AI_FILE_CONTEXT),context.temp_allocator)
    testing.expect(t,play_read_error==nil)
    value:Ai_Context
    testing.expect(t,json.unmarshal(play_context,&value,allocator=context.temp_allocator)==nil)
    testing.expect_value(t,value.mode,"play")
    testing.expect_value(t,len(value.entities),1)
    testing.expect_value(t,value.entities[0].name,"Live player")
    testing.expect_value(t,value.entities[0].position,[3]f32{42,0,0})
    play_prompt,_:=os.read_entire_file(ai_task_path(&s,playing,AI_FILE_PROMPT),context.temp_allocator)
    testing.expect(t,strings.contains(string(play_prompt),"play.player") && strings.contains(string(play_prompt),"include_runtime=true") && strings.contains(string(play_prompt),"read-only"))
    restored:Ai_Transcript
    testing.expect_value(t,ai_store_load(&ai.store,first.conversation.id,&restored),"")
    testing.expect_value(t,restored.count,playing.transcript.count)
    playing.state=.Done
    // Sent from the pause, the turn has the selected entities with their values at that tick;
    // the next turn without a selection in the pause does not keep them.
    api_schema_build(&s,&state)
    defer api_schema_free(&state)
    s.mode,live.time.tick=.Paused,120
    paused,paused_error:=ai_task_create(&s,ai,{0,0,800,600},"Why is it here?","codex",first.id)
    if !testing.expect(t,paused!=nil && paused_error=="") {return}
    snapshot,snapshot_error:=os.read_entire_file(ai_task_path(&s,paused,AI_FILE_STATE),context.temp_allocator)
    testing.expect(t,snapshot_error==nil && strings.contains(string(snapshot),`"tick":120`))
    testing.expect(t,strings.contains(string(snapshot),"Live player") && strings.contains(string(snapshot),`"position":[42,0,0]`))
    paused_prompt,_:=os.read_entire_file(ai_task_path(&s,paused,AI_FILE_PROMPT),context.temp_allocator)
    testing.expect(t,strings.contains(string(paused_prompt),"paused at tick 120") && strings.contains(string(paused_prompt),AI_FILE_STATE))
    paused.state=.Done
    selection_clear(&selection)
    unselected,unselected_error:=ai_task_create(&s,ai,{0,0,800,600},"And now?","codex",first.id)
    if !testing.expect(t,unselected!=nil && unselected_error=="") {return}
    testing.expect(t,!os.exists(ai_task_path(&s,unselected,AI_FILE_STATE)))
    unselected.state=.Done
    s.mode=.Edit;s.runs[0]={}
    selection_clear(&selection)
    ai.connections[AI_CLAUDE].configured=true
    base.text_set(ai.connections[AI_CLAUDE].model[:],"default")
    base.text_set(ai.connections[AI_CLAUDE].effort[:],"low")
    base.text_set(ai.agent[:],"claude")
    selected,selected_error:=ai_task_create(&s,ai,{0,0,800,600},"Use my selected agent","")
    if !testing.expect(t,selected!=nil && selected_error=="") {return}
    testing.expect_value(t,base.text_get(selected.agent[:]),"claude")
    testing.expect_value(t,string(selected.conversation.model[:selected.conversation.model_len]),"default")
    selected.state=.Done
    base.text_set(ai.agent[:],"codex")
    resumed,resumed_error:=ai_task_create(&s,ai,{0,0,800,600},"Continue without an explicit provider","",selected.id)
    if !testing.expect(t,resumed==selected && resumed_error=="") {return}
    testing.expect_value(t,base.text_get(resumed.agent[:]),"claude")
    resumed.state=.Done
    ai.agent={}
    configured,configured_error:=ai_task_create(&s,ai,{0,0,800,600},"Use the configured agent","")
    if !testing.expect(t,configured!=nil && configured_error=="") {return}
    testing.expect_value(t,base.text_get(configured.agent[:]),"claude")
}
