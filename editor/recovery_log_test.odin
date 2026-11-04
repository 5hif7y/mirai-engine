package editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/jobs"

@(test)
recovery_log_writes_each_step_over_the_saved_file_and_puts_them_back :: proc(t:^testing.T) {
    world:Prefab_Test_World
    prefab_test_init(&world,context.allocator)
    defer prefab_test_destroy(&world)
    tables:=[4]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Prefab_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Prefab_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Prefab_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Prefab_Test_World,parents)},
    }
    storages:=[2]core.Storage_Info{{type=Prefabs,place=.Editor},{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Prefab_Test_World,hierarchy)}}
    info:=core.World_Info{tables=tables[:],storages=storages[:],settle=prefab_test_settle,clear=prefab_test_clear,copy=prefab_test_copy,swap=prefab_test_swap,
        sizes={.World=size_of(Prefab_Test_World),.Shared=0,.Editor=0},aligns={.World=align_of(Prefab_Test_World),.Shared=1,.Editor=1},
        init={.World=prefab_test_init,.Shared=nil,.Editor=nil},destroy={.World=prefab_test_destroy,.Shared=nil,.Editor=nil}}
    root:=project.path_absolute(fmt.tprintf(".mirai/test-recovery-log-%d",os.get_pid()),context.temp_allocator)
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    os.make_directory_all(root)
    defer os.remove_all(root)
    assets:host.Assets
    asset.types_init(&assets.types)
    defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,root)
    defer asset.registry_destroy(&assets.registry)
    app:=host.App{assets=&assets,info=&info,allocator=context.allocator}
    defer delete(app.worlds)
    testing.expect(t,jobs.system_init(&app.jobs,{threads=1,allocator=context.allocator}))
    defer jobs.system_destroy(&app.jobs)
    selection:Selection
    edits:Edits
    document:Document
    prefabs:Prefabs
    s:=Session{info=&info,edit_world=&world,editor_world=&prefabs,assets_root=root,project_root=root,app=&app,selection=&selection,edits=&edits,document=&document}
    defer delete(selection.entities)
    defer edits_free(&edits)
    defer document_previous_free(&document)
    defer prefabs_free(&s)
    defer recovery_log_destroy(&s)
    w:=edited_world(&s)
    kept:=entity_create(&s,{name="Kept",transform={position={2,0,0},rotation=1,scale={1,1,1}}})
    core.world_settle(w)
    edits_reset(&edits,w)
    // A clean document with a file: the log follows that file.
    scene:=project.path(root,"kept.scene",allocator=context.temp_allocator)
    document_name(&document,"kept.scene",scene)
    document.saved=edits_scene_state(&edits)
    recovery_update(&s)
    testing.expect(t,s.recovery.log.following && s.recovery.log.base==.Source && edits.logging)
    testing.expect(t,os.is_file(recovery_log_path(&s,s.recovery.slot,1)))

    testing.expect(t,entity_rename(&s,kept,"Moved"))
    testing.expect(t,edits_commit(&edits,w,&selection))
    born:=entity_create(&s,{name="Born",transform={position={0,3,0},rotation=1,scale={1,1,1}}})
    testing.expect(t,edits_commit(&edits,w,&selection))
    testing.expect(t,born!=core.NONE)
    born_id:=api_entity_id(w,born)
    recovery_update(&s)
    testing.expect(t,s.recovery.log.records>0 && s.recovery.log.since!=0)
    testing.expect(t,len(edits.changes)==0,"what the log wrote leaves the journal")
    // Undoing in order is a step of the log too.
    testing.expect(t,undo(&edits,w,&selection))
    recovery_update(&s)
    testing.expect(t,!entity_alive(w,born))
    testing.expect(t,redo(&edits,w,&selection))
    recovery_update(&s)
    testing.expect(t,recovery_log_flush(&s,true))

    // A start after a crash: the chain over the saved file, every record whole.
    chain,records:=recovery_log_chain(&s,s.recovery.slot,0)
    testing.expect(t,len(chain)==1 && chain[0].base==.Source && chain[0].source==scene)
    testing.expect_value(t,records,s.recovery.log.records)
    // A record cut by a crash ends the chain there.
    file,_:=os.open(recovery_log_path(&s,s.recovery.slot,1),{.Write,.Append})
    os.write(file,[]u8{40,0,0,0,1,2,3})
    os.close(file)
    _,records_cut:=recovery_log_chain(&s,s.recovery.slot,0)
    testing.expect_value(t,records_cut,records)

    // Back to the saved state, the log puts the steps back by Id.
    recovery_log_end(&s,false)
    for undo(&edits,w,&selection) {}
    core.world_settle(w)
    testing.expect_value(t,entity_name(w,kept),"Kept")
    testing.expect(t,recovery_log_replay(&s,chain)==records)
    core.world_settle(w)
    testing.expect_value(t,entity_name(w,kept),"Moved")
    testing.expect_value(t,entity_name(w,api_entity(w,born_id)),"Born")

    // A copy names the generation after it; the ones before go once it is written.
    recovery_update(&s)
    document.unsaved=true
    s.recovery.deadline=platform.clock_ns()
    recovery_update(&s)
    testing.expect(t,recovery_wait(&s))
    generations:=recovery_log_generations(&s,s.recovery.slot)
    testing.expect(t,len(generations)==1 && generations[0]==s.recovery.log.generation,"the copy leaves only the generation that follows it")
}

// A tab at the back keeps the chain of its changes and writes nothing while
// it does not change; a start after a crash puts back every document that
// had changes, each in its tab.
@(test)
every_tab_with_changes_keeps_its_chain_and_a_start_recovers_them_all :: proc(t:^testing.T) {
    f:=new(Prefab_Fixture);defer free(f)
    if !testing.expect(t,prefab_fixture_init(f,"recovery-tabs")) {return}
    defer prefab_fixture_destroy(f)
    s:=&f.s
    s.project_root=f.root
    testing.expect(t,jobs.system_init(&f.app.jobs,{threads=1,allocator=context.allocator}))
    defer jobs.system_destroy(&f.app.jobs)
    defer recovery_log_destroy(s)
    w:=edited_world(s)
    root:=entity_create(s,{name="Root",named=true})
    plain:=entity_create(s,{name="Plain",named=true})
    core.world_settle(w)
    edits_reset(&f.edits,w)
    prefabs_follow(s,&f.prefabs)
    plain_id:=api_entity_id(w,plain)
    _,created:=prefab_create(s,root,"kept")
    if !testing.expect_value(t,created,Prefab_Error.None) {return}
    prefab_fixture_step(f)
    if !testing.expect_value(t,scene_save(s,"main.scene"),Document_Error.None) {return}
    recovery_update(s)
    scene_slot:=s.recovery.slot
    entity_rename(s,api_entity(w,plain_id),"Changed in the scene")
    prefab_fixture_step(f)
    recovery_update(s)

    if !testing.expect_value(t,document_open_tab(s,"kept.prefab"),Document_Error.None) {return}
    defer documents_free(s)
    recovery_update(s)
    prefab_slot:=s.recovery.slot
    testing.expect(t,prefab_slot!=0 && prefab_slot!=scene_slot)
    prefab_world:=edited_world(s)
    prefab_root:=document_root(s,prefab_world)
    root_id:=api_entity_id(prefab_world,prefab_root)
    entity_rename(s,prefab_root,"Changed in the prefab")
    prefab_fixture_step(f)
    recovery_update(s)

    // Back to the scene: the prefab keeps its chain and writes nothing more.
    testing.expect(t,document_activate(s,0))
    prefab_log:=recovery_log_path(s,prefab_slot,1)
    before,_:=os.stat(prefab_log,context.temp_allocator)
    entity_rename(s,api_entity(w,plain_id),"Changed again")
    prefab_fixture_step(f)
    recovery_update(s)
    after,_:=os.stat(prefab_log,context.temp_allocator)
    testing.expect(t,before.size>0 && after.size==before.size && after.modification_time==before.modification_time)

    // A crash: the chains stay; the next start finds a document in each.
    recovery_chains_close(s,false)
    documents_free(s)
    s.active_document=0
    s.recovery.chain={}
    scene_new(s)
    recovery_open(s)
    testing.expect(t,s.recovery.pending)
    if !testing.expect_value(t,len(s.recovery.found),2) {return}
    testing.expect(t,recovery_resolve(s,false))
    if !testing.expect_value(t,len(s.documents),2) {return}
    testing.expect(t,document_activate(s,0))
    testing.expect(t,document_dirty(s) && !document_is_prefab(s))
    testing.expect_value(t,entity_name(edited_world(s),api_entity(edited_world(s),plain_id)),"Changed again")
    testing.expect(t,document_activate(s,1))
    testing.expect(t,document_dirty(s) && document_is_prefab(s))
    testing.expect_value(t,entity_name(edited_world(s),api_entity(edited_world(s),root_id)),"Changed in the prefab")
    testing.expect(t,document_activate(s,0))
}
