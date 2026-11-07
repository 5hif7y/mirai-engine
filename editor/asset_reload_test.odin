package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") RELOAD_TEST_PREFAB :: base.Asset_Id{0x510ad101,0x1}
@(private="file") RELOAD_TEST_OTHER :: base.Asset_Id{0x510ad102,0x2}
@(private="file") RELOAD_TEST_THIRD :: base.Asset_Id{0x510ad103,0x3}

// A prefab whose entities have names, saved where a tool would write it.
@(private="file")
reload_test_prefab :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,names:..string) {
    sc:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&sc,types,asset.KIND_PREFAB,id),asset.Error.None) {return}
    defer asset.scene_destroy(&sc)
    for name,i in names {asset.scene_entity_add(&sc,base.Entity_Id(i+1),0,name)}
    sc.info.root=1
    testing.expect_value(t,asset.scene_save(&sc,path),asset.Error.None)
}

// A prefab replaced on disk under an open editor stays as it was read (what
// Play spawns from) until asset.reload reads it again; one with unsaved
// changes keeps them, and a file that is gone is said to be.
@(test)
asset_reload_reads_again_what_changed_on_disk_and_keeps_unsaved_changes :: proc(t:^testing.T) {
    f:=new(Files_Test,context.temp_allocator)
    files_test_open(f,"mirai-asset-reload")
    defer files_test_close(f)
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=project.path(f.root,"assets",allocator=context.temp_allocator),capacity=16})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    f.s.app=&app
    s:=&f.s
    blade:=project.path(f.root,"assets","blade.prefab",allocator=context.temp_allocator)
    other:=project.path(f.root,"assets","other.prefab",allocator=context.temp_allocator)
    reload_test_prefab(t,&assets.types,blade,RELOAD_TEST_PREFAB,"Blade")
    reload_test_prefab(t,&assets.types,other,RELOAD_TEST_OTHER,"Other")
    host.assets_scan(&assets)
    loaded:=host.assets_scene(&assets,RELOAD_TEST_PREFAB)
    if !testing.expect(t,loaded!=nil) {return}
    first:=loaded.blob.header.content_hash

    // Nothing changed: nothing is read again.
    report,refusal:=assets_reload_disk(s,nil)
    testing.expect_value(t,refusal,"")
    testing.expect_value(t,len(report.reloaded),0)

    reload_test_prefab(t,&assets.types,blade,RELOAD_TEST_PREFAB,"Blade","Hand_Attach")
    testing.expect_value(t,host.assets_scene(&assets,RELOAD_TEST_PREFAB).blob.header.content_hash,first)
    report,refusal=assets_reload_disk(s,nil)
    testing.expect_value(t,refusal,"")
    testing.expect(t,len(report.reloaded)==1 && report.reloaded[0].path=="blade.prefab" && report.reloaded[0].id==RELOAD_TEST_PREFAB,fmt.tprint(report.reloaded))
    now:=host.assets_scene(&assets,RELOAD_TEST_PREFAB)
    testing.expect(t,now!=nil && now.blob.header.content_hash!=first,"the editor holds what the file holds now")

    // Named, a file is read again even when the registry already saw it change.
    report,refusal=assets_reload_disk(s,{"blade.prefab"})
    testing.expect(t,refusal=="" && len(report.reloaded)==1,refusal)

    // Unsaved changes stay; the file that is gone is said to be.
    held,_:=os.read_entire_file(blade,context.temp_allocator)
    testing.expect_value(t,asset.registry_memory_set(&assets.registry,"blade.prefab",held),asset.Error.None)
    reload_test_prefab(t,&assets.types,blade,RELOAD_TEST_PREFAB,"Blade","Hand_Attach","Sheath")
    testing.expect(t,os.remove(other)==nil)
    report,refusal=assets_reload_disk(s,nil)
    testing.expect_value(t,refusal,"")
    testing.expect(t,slice.contains(report.unsaved[:],"blade.prefab"),fmt.tprint(report.unsaved))
    testing.expect(t,slice.contains(report.removed[:],"other.prefab"),fmt.tprint(report.removed))
    if memory,found:=asset.registry_memory_find(&assets.registry,"blade.prefab");testing.expect(t,found) {
        testing.expect(t,slice.equal(memory.data,held),"the unsaved bytes stay")
    }

    // The method takes paths, also of a file that is new, and answers in the shape it declares.
    reload_test_prefab(t,&assets.types,project.path(f.root,"assets","third.prefab",allocator=context.temp_allocator),RELOAD_TEST_THIRD,"Third")
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    call:=api.Call{raw=`{"assets":["third.prefab","blade.prefab"]}`,out=&out,allocator=context.temp_allocator}
    api_asset_reload(s,&call)
    text:=string(serial.writer_bytes(&out))
    testing.expect(t,!call.failed && strings.contains(text,`"path":"third.prefab"`) && strings.contains(text,`"unsaved":["blade.prefab"]`),text)
    api_result_shape_expect(t,text,Api_Reload_Result)
    wrong:=api.Call{raw=`{"paths":["third.prefab"]}`,out=&out,allocator=context.temp_allocator}
    api_asset_reload(s,&wrong)
    testing.expect(t,wrong.failed && strings.contains(wrong.error.message,"assets"),wrong.error.message)

    s.mode=.Play
    _,refusal=assets_reload_disk(s,nil)
    testing.expect(t,refusal!="","not while a game plays")
}
