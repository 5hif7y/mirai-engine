package editor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

@(test)
an_edit_of_another_end_makes_entities_that_its_other_rows_name_by_id :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    s:=&f.s
    st:=new(Collab_State);defer free(st)
    collab_tables_build(s,st)
    defer collab_tables_free(st)
    // The other end adds a parent and a child that names it.
    other:Play_Test_World
    if !testing.expect(t,play_test_init(&other,context.allocator)) {return}
    defer play_test_free(&other)
    edits:Edits;defer edits_free(&edits)
    selection:Selection;defer delete(selection.entities)
    end:=Session{info=s.info,edit_world=&other,edits=&edits,selection=&selection}
    edits_reset(&edits,core.world_ref(&other,s.info))
    sent:=new(Collab_State);defer free(sent)
    sent.role,sent.phase=.Guest,.Joined
    collab_tables_build(&end,sent)
    defer collab_tables_free(sent)
    collab_journal_reset(&end,sent)
    parent,child:=core.create(&other.entities),core.create(&other.entities)
    core.add(&other.ids,parent,core.Id{50});core.add(&other.ids,child,core.Id{51})
    core.add(&other.transforms,parent,core.Transform{{1,0,0},1,{1,1,1}})
    core.add(&other.transforms,child,core.Transform{{0,2,0},1,{1,1,1}})
    core.add(&other.parents,child,core.Parent{entity=parent})
    play_test_settle(&other,nil,nil)
    collab_edits_send(&end,sent)
    for message in sent.peers[0].out {
        collab_edit_apply(s,st,message)
        delete(message)
    }
    delete(sent.peers[0].out)

    world:=cast(^Play_Test_World)f.data
    made,named:=core.entity_of(&world.entities,50),core.entity_of(&world.entities,51)
    if !testing.expect(t,made!=core.NONE && named!=core.NONE && made!=f.original) {return}
    testing.expect_value(t,world.entities.alive,3)
    link,linked:=core.get(core.read(&world.parents),named)
    testing.expect(t,linked && link.entity==made)
    local,_:=core.get(core.read(&world.transforms),named)
    testing.expect_value(t,local.position,[3]f32{0,2,0})
    testing.expect_value(t,core.entity_of(&world.entities,base.Entity_Id(1)),f.original)
}

// The scene of the host replaces the World only when all of it got there: one
// that fails halfway, after its entities were made, leaves the World as it
// was, and one that loads replaces it.
@(test)
a_scene_of_the_host_that_fails_halfway_leaves_the_world_as_it_was :: proc(t:^testing.T) {
    f:=new(Play_Test);defer free(f)
    if !play_test_open(t,f) {return}
    defer play_test_close(f)
    directory,_:=os.temp_directory(context.temp_allocator)
    folder:=fmt.tprintf("%s/mirai-collab-snapshot-%d",directory,os.get_pid())
    os.remove_all(folder)
    if !testing.expect(t,os.make_directory_all(folder)==nil) {return}
    defer os.remove_all(folder)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=folder,capacity=8})) {return}
    defer host.assets_destroy(&assets)
    f.app.assets=&assets
    outliner:Outliner
    defer delete(outliner.expanded)
    f.s.outliner=&outliner
    st:=new(Collab_State);defer free(st)

    host_scene:asset.Scene
    asset.scene_init(&host_scene,&assets.types,asset.KIND_SCENE,{0x1c,1})
    defer asset.scene_destroy(&host_scene)
    placed:=core.Transform{{0,3,0},1,{1,1,1}}
    for i in 1..=64 {
        asset.scene_entity_add(&host_scene,base.Entity_Id(100+i),0,"Box")
        asset.scene_set(&host_scene,base.Entity_Id(100+i),"Transform",&placed)
    }
    good,error:=asset.scene_bytes(&host_scene,context.temp_allocator)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    // The transforms of the broken copy do not decompress.
    broken:=make([]u8,len(good),context.temp_allocator)
    copy(broken,good)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,broken),asset.Error.None) {return}
    view,_:=asset.scene_view(&file,&assets.types)
    entry:asset.Chunk_Entry
    for &component in view.components {
        if component.name=="Transform" {entry=asset.blob_chunk(&file.blob,component.table.columns[1].chunk)}
    }
    asset.asset_close(&file)
    if !testing.expect_value(t,entry.compression,asset.Compression.LZ4) {return}
    mem.set(&broken[entry.offset],0xff,int(entry.size))

    world:=cast(^Play_Test_World)f.data
    testing.expect(t,!collab_snapshot_load(&f.s,st,broken))
    testing.expect_value(t,world.entities.alive,1)
    testing.expect_value(t,core.entity_of(&world.entities,base.Entity_Id(1)),f.original)
    testing.expect_value(t,host.app_world_count(&f.app),1)

    testing.expect(t,collab_snapshot_load(&f.s,st,good))
    testing.expect_value(t,world.entities.alive,64)
    testing.expect(t,!core.alive(&world.entities,f.original))
    box:=core.entity_of(&world.entities,base.Entity_Id(101))
    local,found:=core.get(core.read(&world.transforms),box)
    testing.expect(t,found && local.position==[3]f32{0,3,0})
    document_previous_free(&f.document)
}
