package asset

import "core:testing"
import "mirai:std/serial"

@(test)
mesh_morphs_roundtrip_sparse_named_targets_and_refuse_broken_ranges :: proc(t:^testing.T) {
    vertices:=[3]Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    indices:=[3]u32{0,1,2}
    targets:=[2]Morph_Target{{weight=.25,count=1},{weight=-.5,first=1,count=2}}
    text_set(targets[0].name[:],"Smile");text_set(targets[1].name[:],"Wide")
    deltas:=[3]Morph_Delta{{vertex=1,position={2,0,0},normal={0,.1,0},tangent={0,0,.2}},{vertex=0,position={0,3,0}},{vertex=2,tangent={1,0,0}}}
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document
    if !testing.expect_value(t,mesh_document(&doc,&types,{id={51,17},geometry=test_geometry(vertices[:],indices[:],morphs=targets[:],deltas=deltas[:])}),Error.None) {return}
    defer document_destroy(&doc)
    testing.expect_value(t,doc.kind_version,u16(MESH_VERSION))
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    testing.expect_value(t,document_write(&doc,&bytes),Error.None)
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    view,error:=mesh_view(&file,&types)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expect_value(t,view.morphs[1],targets[1])
    for delta,i in deltas {testing.expect_value(t,view.morph_deltas[i],delta)}
    testing.expect(t,mesh_check_indices(view))
    broken:=view;moved:=deltas;moved[0].vertex=3;broken.morph_deltas=moved[:];testing.expect(t,!mesh_check_indices(broken))
    moved=deltas;moved[2].vertex=0;broken.morph_deltas=moved[:];testing.expect(t,!mesh_check_indices(broken))
    moved=deltas;moved[1].tangent.y=transmute(f32)u32(0x7fc00000);broken.morph_deltas=moved[:];testing.expect(t,!mesh_check_indices(broken))
    invalid:=targets;invalid[1].name=invalid[0].name;broken=view;broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    invalid=targets;invalid[1].first=max(u32);broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    invalid=targets;invalid[1].count=1;broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    invalid=targets;invalid[0].weight=transmute(f32)u32(0x7fc00000);broken.morphs=invalid[:];testing.expect(t,!mesh_check(broken))
    for cut in 0..<bytes.count {
        truncated:Asset
        if asset_open(&truncated,serial.writer_bytes(&bytes)[:cut])==.None {
            if view,read:=mesh_view(&truncated,&types);read==.None {mesh_check_indices(view)}
            asset_close(&truncated)
        }
    }
}

@(test)
meshes_without_morphs_have_no_morph_tables :: proc(t:^testing.T) {
    vertices:=[3]Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document
    if !testing.expect_value(t,mesh_document(&doc,&types,{id={13,15},geometry=test_geometry(vertices[:],{0,1,2})}),Error.None) {return}
    defer document_destroy(&doc)
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    testing.expect_value(t,document_write(&doc,&bytes),Error.None)
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    view,error:=mesh_view(&file,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(view.morphs)==0 && len(view.morph_deltas)==0)
    _,has_morphs:=asset_table(&file,"morphs");_,has_deltas:=asset_table(&file,"morph_deltas")
    testing.expect(t,!has_morphs && !has_deltas)
}
