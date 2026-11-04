package host

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

// A reload of a file that changed into one that does not open keeps what
// loaded before and says why, once however often it is tried; once the file
// is whole again the reload takes it and the error goes.
@(test)
a_reload_of_a_damaged_file_keeps_what_loaded_and_says_why_until_it_is_whole :: proc(t:^testing.T) {
    directory,_:=os.temp_directory(context.temp_allocator)
    root:=fmt.tprintf("%s/mirai-host-%d-reload",directory,os.get_pid())
    os.remove_all(root)
    defer os.remove_all(root)
    os.make_directory_all(root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    stone:=base.Asset_Id{1,1}
    info:=asset.MATERIAL_DEFAULTS
    testing.expect_value(t,asset.material_save(fmt.tprintf("%s/stone.mat",root),&types,{id=stone,info=info}),asset.Error.None)
    a:Assets
    if !testing.expect(t,assets_init(&a,{root=root,capacity=8})) {return}
    defer assets_destroy(&a)
    row:=assets_material_row(&a,stone)
    assets_commit(&a)
    testing.expect(t,row!=0 && len(a.errors)==0)

    bytes_of :: proc(t:^testing.T,types:^asset.Types,id:base.Asset_Id,info:asset.Material_Info) -> []u8 {
        doc:asset.Document
        testing.expect_value(t,asset.material_document(&doc,types,{id=id,info=info}),asset.Error.None)
        defer asset.document_destroy(&doc)
        data,_:=asset.document_bytes(&doc,context.temp_allocator)
        return data
    }
    changed:=info
    changed.roughness=0.25
    damaged:=bytes_of(t,&types,stone,changed)
    damaged[len(damaged)-1]~=0xff
    testing.expect_value(t,asset.registry_memory_set(&a.registry,"stone.mat",damaged),asset.Error.None)
    reloads:=a.stats.reloads
    for _ in 0..<2 {
        testing.expect(t,!assets_reload(&a,stone))
        testing.expect_value(t,assets_material_values(&a,row).roughness,info.roughness)
    }
    testing.expect_value(t,a.stats.reloads,reloads)
    if testing.expect_value(t,len(a.errors),1) {
        testing.expect(t,a.errors[0].id==stone && a.errors[0].kind==.Material && a.errors[0].problem==.Corrupt,"the file contradicts its hash")
    }

    testing.expect_value(t,asset.registry_memory_set(&a.registry,"stone.mat",bytes_of(t,&types,stone,changed)),asset.Error.None)
    testing.expect(t,assets_reload(&a,stone))
    testing.expect_value(t,assets_material_values(&a,row).roughness,f32(0.25))
    testing.expect_value(t,len(a.errors),0)
}
