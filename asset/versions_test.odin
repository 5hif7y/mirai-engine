package asset

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The kind_version of a file, changed in place: the header is outside its content hash.
@(private="file")
version_set :: proc(path:string,version:u16) -> bool {
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil || len(data)<HEADER_SIZE {return false}
    data[10],data[11]=u8(version),u8(version>>8)
    return os.write_entire_file(path,data)==nil
}

// root/assets/models/box.obj/Box.mesh, of the version before this build's,
// imported from root/source/models/box.obj.
@(private="file")
stale_mesh :: proc(t:^testing.T,types:^Types,root:string) -> (path:string,ok:bool) {
    os.make_directory_all(fmt.tprintf("%s/source/models",root))
    os.make_directory_all(fmt.tprintf("%s/assets/models/box.obj",root))
    _=os.write_entire_file(fmt.tprintf("%s/source/models/box.obj",root),"v 0 0 0\n")
    vertices,indices:=test_grid(1);defer delete(vertices);defer delete(indices)
    source:Import_Info
    text_set(source.source[:],"source/models/box.obj")
    text_set(source.name[:],"Box")
    text_set(source.importer[:],"mirai-import")
    path=fmt.tprintf("%s/assets/models/box.obj/Box.mesh",root)
    if !testing.expect_value(t,mesh_save(path,types,{id={1,2},geometry=test_geometry(vertices,indices),source=&source}),Error.None) {return}
    return path,testing.expect(t,version_set(path,MESH_VERSION-1))
}

@(test)
an_asset_of_another_version_says_which_it_is_and_how_to_import_it_again :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root,_:=strings.replace_all(test_path("versions"),"\\","/",context.temp_allocator)
    defer os.remove_all(root)
    path,ok:=stale_mesh(t,&types,root)
    if !ok {return}

    a:Asset
    if !testing.expect_value(t,asset_load(&a,path),Error.None) {return}
    defer asset_close(&a)
    _,view_error:=mesh_view(&a,&types)
    testing.expect_value(t,view_error,Error.Version)
    message:=version_message(&a,&types,path,allocator=context.temp_allocator)
    wanted:=fmt.tprintf("mirai import %s/source/models/box.obj --out %s/assets/models/box.obj --root %s",root,root,root)
    testing.expect(t,strings.has_prefix(message,path) && strings.contains(message,fmt.tprintf("a mesh of version %d",MESH_VERSION-1)) && strings.contains(message,wanted),message)

    // An asset nobody imported is named, with nothing to import; one older than the oldest
    // version its kind reads says to make it again, and one newer, to open it with a newer engine.
    material:=fmt.tprintf("%s/assets/Paint.mat",root)
    if !testing.expect_value(t,material_save(material,&types,{id={3,4},info=MATERIAL_DEFAULTS}),Error.None) {return}
    if !testing.expect(t,version_set(material,MATERIAL_VERSION+1)) {return}
    b:Asset
    if !testing.expect_value(t,asset_load(&b,material),Error.None) {return}
    defer asset_close(&b)
    _,material_error:=material_view(&b,&types)
    testing.expect_value(t,material_error,Error.Version)
    told:=version_message(&b,&types,material,allocator=context.temp_allocator)
    testing.expect(t,strings.contains(told,"a material of version") && strings.contains(told,"newer engine") && !strings.contains(told,"mirai import"),told)
    b.blob.header.kind_version=0
    told=version_message(&b,&types,material,MATERIAL_OLDEST,MATERIAL_VERSION,context.temp_allocator)
    testing.expect(t,strings.contains(told,"a material of version 0, older than") && strings.contains(told,"it was not imported: make it again"),told)

    // Every kind the engine defines reads from its oldest version to its current one.
    testing.expect_value(t,kind_check(&a,KIND_MESH,MESH_VERSION-1,MESH_VERSION),Error.None)
    testing.expect_value(t,kind_check(&a,KIND_MESH,MESH_VERSION,MESH_VERSION),Error.Version)
    testing.expect_value(t,kind_check(&a,KIND_MESH,MESH_VERSION-2,MESH_VERSION-2),Error.Version)
    testing.expect_value(t,kind_check(&a,KIND_MATERIAL,MESH_VERSION-1,MESH_VERSION-1),Error.Invalid)
    for info in KINDS {
        testing.expectf(t,info.version>0 && info.oldest>0 && info.oldest<=info.version || info.kind==KIND_PHYSICS_CACHE,"%s has the versions it reads",info.name)
    }
}

// A kind of version 2 whose rows gained a field and that gained a table, both since version 1:
// what a plugin kind is to the engine.
@(private="file") KIND_GROWN :: Fourcc(u32('G')|u32('R')<<8|u32('W')<<16|u32('N')<<24)

@(test)
an_asset_of_a_version_its_kind_migrates_reads_with_its_rows_migrated :: proc(t:^testing.T) {
    Row_1 :: struct {speed:f32,blend:[2]u32}
    Row_2 :: struct {speed:f32,blend:[4]u32,rate:f32}
    Added :: struct {weight:f32}
    types:Types;types_init(&types);defer types_destroy(&types)
    written:=[2]Row_1{{1,{5,6}},{2,{7,8}}}
    for version in ([4]u16{1,2,0,3}) {
        doc:Document;document_init(&doc,KIND_GROWN,{5,6});defer document_destroy(&doc)
        doc.kind_version=version
        if _,error:=document_put(&doc,&types,"rows",written[:]);!testing.expect_value(t,error,Error.None) {continue}
        bytes,error:=document_bytes(&doc,context.temp_allocator)
        if !testing.expect_value(t,error,Error.None) {continue}
        a:Asset
        if !testing.expect_value(t,asset_open(&a,bytes,context.temp_allocator),Error.None) {continue}
        defer asset_close(&a)
        checked:=kind_check(&a,KIND_GROWN,1,2)
        switch version {
        case 1:
            if !testing.expect_value(t,checked,Error.None) {continue}
            testing.expect_value(t,kind_age(version,1,2),Kind_Age.Old)
            rows,read:=asset_rows(&a,&types,"rows","",Row_2)
            testing.expect(t,read==.None && len(rows)==2 && rows[1]==Row_2{2,{7,8,0,0},0},"the rows of version 1 migrate")
            added,since:=asset_rows_since(&a,&types,2,"added","",Added)
            testing.expect(t,since==.None && len(added)==0,"a table of version 2 reads empty from a file of version 1")
            // mirai asset verify passes it and tells how to write the current version.
            notice:=version_notice(version,{kind=KIND_GROWN,name="grown",version=2,oldest=1},context.temp_allocator)
            testing.expect(t,strings.contains(notice,"a grown of version 1") && strings.contains(notice,"writes as version 2"),notice)
            testing.expect_value(t,version_notice(2,{kind=KIND_GROWN,name="grown",version=2,oldest=1},context.temp_allocator),"")
        case 2:
            testing.expect_value(t,checked,Error.None)
            _,since:=asset_rows_since(&a,&types,2,"added","",Added)
            testing.expect_value(t,since,Error.Not_Found)
        case 0:
            testing.expect_value(t,checked,Error.Version)
            told:=version_message(&a,&types,"grown.grw",1,2,context.temp_allocator)
            testing.expect(t,strings.contains(told,"of version 0, older than this build reads (versions 1 to 2)") && strings.contains(told,"make it again"),told)
        case 3:
            testing.expect_value(t,checked,Error.Version)
            told:=version_message(&a,&types,"grown.grw",1,2,context.temp_allocator)
            testing.expect(t,strings.contains(told,"newer than this build") && strings.contains(told,"newer engine"),told)
        }
    }
}

@(test)
an_asset_of_another_version_named_by_a_relative_path_says_how_to_import_it_again :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    root,_:=strings.replace_all(test_path("versions_relative"),"\\","/",context.temp_allocator)
    defer os.remove_all(root)
    path,ok:=stale_mesh(t,&types,root)
    if !ok {return}
    a:Asset
    if !testing.expect_value(t,asset_load(&a,path),Error.None) {return}
    defer asset_close(&a)

    // The folders above a relative path are the ones of its own, then "." once.
    working,_:=os.get_working_directory(context.temp_allocator)
    if relative,error:=filepath.rel(working,root,context.temp_allocator);error==.None {
        relative,_=strings.replace_all(relative,"\\","/",context.temp_allocator)
        named:=fmt.tprintf("%s/assets/models/box.obj/Box.mesh",relative)
        found:=version_message(&a,&types,named,allocator=context.temp_allocator)
        wanted:=fmt.tprintf("mirai import %s/source/models/box.obj --out %s/assets/models/box.obj --root %s",relative,relative,relative)
        testing.expect(t,strings.contains(found,wanted),found)
        os.remove(fmt.tprintf("%s/source/models/box.obj",root))
        lost:=version_message(&a,&types,named,allocator=context.temp_allocator)
        testing.expect(t,strings.has_suffix(lost,fmt.tprintf("import its source source/models/box.obj again with mirai import into %s/assets/models/box.obj",relative)),lost)
    }
    bare:=version_message(&a,&types,"Box.mesh",allocator=context.temp_allocator)
    testing.expect(t,strings.has_suffix(bare,"again with mirai import into ."),bare)
}
