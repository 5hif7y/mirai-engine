package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

@(private="file") WOOD_COLOR :: base.Asset_Id{1,1}
@(private="file") WOOD_NORMAL :: base.Asset_Id{1,2}
@(private="file") ICON :: base.Asset_Id{1,3}
@(private="file") UNUSED_TEXTURE :: base.Asset_Id{1,4}
@(private="file") BLOCKS :: base.Asset_Id{1,5}
@(private="file") WOOD :: base.Asset_Id{2,1}
@(private="file") SPARE :: base.Asset_Id{2,2}
@(private="file") LONELY :: base.Asset_Id{2,3}
@(private="file") LOST :: base.Asset_Id{2,4}
@(private="file") CRATE :: base.Asset_Id{3,1}
@(private="file") MAIN :: base.Asset_Id{4,1}
@(private="file") HUD :: base.Asset_Id{5,1}
@(private="file") PROP :: base.Asset_Id{6,1}
@(private="file") ABSENT :: base.Asset_Id{9,9}

@(private="file")
Shown :: struct {mesh:base.Asset_Id}
@(private="file")
Picture :: struct {image:base.Asset_Id}

@(private="file")
cook_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path,_:=strings.replace_all(fmt.tprintf("%s/mirai-cook-%d-%s",directory,os.get_pid(),name),"\\","/",context.temp_allocator)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

// 8x8 with two levels; opaque unless `alpha`.
@(private="file")
texture_write :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,flags:asset.Texture_Flags,alpha:=false,format:=asset.Texture_Format.RGBA8) {
    levels:[2][256]u8
    for &level in levels {
        for &value,at in level {value=at%4==3?(alpha?u8(at):255):u8(at*3)}
    }
    mips:[][]u8={levels[0][:],levels[1][:64]}
    if format==.BC1 {mips={levels[0][:32],levels[1][:8]}}
    testing.expect_value(t,asset.texture_save(path,types,{id=id,width=8,height=8,format=format,flags=flags,mips=mips}),asset.Error.None)
}

@(private="file")
material_write :: proc(t:^testing.T,types:^asset.Types,path:string,id:base.Asset_Id,color,normal:base.Asset_Id) {
    info:=asset.MATERIAL_DEFAULTS
    info.maps.base_color.texture,info.maps.normal.texture=color,normal
    testing.expect_value(t,asset.material_save(path,types,{id=id,info=info}),asset.Error.None)
}

// A scene (or a prefab, or an interface) whose one entity names an asset.
@(private="file")
scene_write :: proc(t:^testing.T,types:^asset.Types,path:string,kind:asset.Fourcc,id,named:base.Asset_Id) {
    if kind==asset.KIND_UI {
        doc:asset.Document
        asset.document_init(&doc,kind,id)
        defer asset.document_destroy(&doc)
        pictures:=[1]Picture{{named}}
        _,put:=asset.document_put(&doc,types,"pictures",pictures[:])
        testing.expect_value(t,put,asset.Error.None)
        testing.expect_value(t,asset.document_save(&doc,path),asset.Error.None)
        return
    }
    scene:asset.Scene
    asset.scene_init(&scene,types,kind,id)
    defer asset.scene_destroy(&scene)
    asset.scene_entity_add(&scene,1,0,"thing")
    shown:=Shown{named}
    asset.scene_set(&scene,1,"Shown",&shown)
    testing.expect_value(t,asset.scene_save(&scene,path),asset.Error.None)
}

// main.scene -> crate.mesh -> wood.mat -> wood_color.tex, wood_normal.tex.
// hud.ui -> icon.tex. prop.prefab -> crate.mesh. spare.mat -> blocks.tex,
// lonely.mat -> unused.tex and lost.mat -> a texture that is no file: nothing
// names them. notes.txt is no asset.
@(private="file")
project_write :: proc(t:^testing.T,types:^asset.Types,assets:string) {
    for folder in ([]string{"textures","materials","models","scenes","ui","prefabs"}) {os.make_directory_all(fmt.tprintf("%s/%s",assets,folder))}
    texture_write(t,types,fmt.tprintf("%s/textures/wood_color.tex",assets),WOOD_COLOR,{.Srgb})
    texture_write(t,types,fmt.tprintf("%s/textures/wood_normal.tex",assets),WOOD_NORMAL,{.Normal_Map})
    texture_write(t,types,fmt.tprintf("%s/textures/icon.tex",assets),ICON,{.Srgb},true)
    texture_write(t,types,fmt.tprintf("%s/textures/unused.tex",assets),UNUSED_TEXTURE,{.Srgb},true)
    texture_write(t,types,fmt.tprintf("%s/textures/blocks.tex",assets),BLOCKS,{.Srgb},false,.BC1)
    material_write(t,types,fmt.tprintf("%s/materials/wood.mat",assets),WOOD,WOOD_COLOR,WOOD_NORMAL)
    material_write(t,types,fmt.tprintf("%s/materials/spare.mat",assets),SPARE,BLOCKS,{})
    material_write(t,types,fmt.tprintf("%s/materials/lonely.mat",assets),LONELY,UNUSED_TEXTURE,{})
    material_write(t,types,fmt.tprintf("%s/materials/lost.mat",assets),LOST,ABSENT,{})
    corners:=[3]asset.Vertex{{position={0,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,0,1},color=0xffffffff}}
    slots:=[1]asset.Material_Slot{{id=1,material=WOOD}}
    geometry:asset.Mesh_Geometry
    testing.expect(t,asset.mesh_build({vertices=corners[:]},{0,2,1},nil,&geometry,context.temp_allocator))
    testing.expect_value(t,asset.mesh_save(fmt.tprintf("%s/models/crate.mesh",assets),types,{id=CRATE,geometry=geometry,slots=slots[:]}),asset.Error.None)
    scene_write(t,types,fmt.tprintf("%s/scenes/main.scene",assets),asset.KIND_SCENE,MAIN,CRATE)
    scene_write(t,types,fmt.tprintf("%s/prefabs/prop.prefab",assets),asset.KIND_PREFAB,PROP,CRATE)
    scene_write(t,types,fmt.tprintf("%s/ui/hud.ui",assets),asset.KIND_UI,HUD,ICON)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/notes.txt",assets),"not an asset")==nil)
}

@(private="file")
cooked_format :: proc(t:^testing.T,types:^asset.Types,path:string) -> (format:asset.Texture_Format,mips:int) {
    a:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,error:=asset.texture_view(&a,types)
    testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,asset.blob_verify_hash(&a.blob))
    return view.info.format,len(view.mips)
}

@(private="file")
names :: proc(report:^Cook_Report) -> (kept,dropped:string) {
    b:=strings.builder_make(context.temp_allocator)
    for file in report.files {fmt.sbprintf(&b,"%s ",file.path)}
    kept=strings.clone(strings.to_string(b),context.temp_allocator)
    strings.builder_reset(&b)
    for file in report.dropped {fmt.sbprintf(&b,"%s ",file.path)}
    return kept,strings.to_string(b)
}

@(test)
a_cook_ships_what_the_scenes_and_the_roots_reach_as_the_runtime_loads_it :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=cook_folder("reach")
    defer os.remove_all(folder)
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    project_write(t,&types,assets)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)

    // Without cook.mirai the scenes are the roots.
    report:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,dropped:=names(&report)
    testing.expect_value(t,kept,"materials/wood.mat models/crate.mesh scenes/main.scene textures/wood_color.tex textures/wood_normal.tex ")
    testing.expect_value(t,dropped,"materials/lonely.mat materials/lost.mat materials/spare.mat notes.txt prefabs/prop.prefab textures/blocks.tex textures/icon.tex textures/unused.tex ui/hud.ui ")
    testing.expect(t,report.roots==1 && len(report.missing)==0 && report.removed==0)
    for file in report.dropped {testing.expect(t,file.asset==(file.path!="notes.txt") && file.bytes>0)}
    testing.expect_value(t,report.textures_compressed,2)
    color,color_mips:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_color.tex",output))
    normal,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_normal.tex",output))
    testing.expect(t,color==.BC7 && normal==.BC5 && color_mips==2,"a texture is compressed by its use, level by level")
    total:i64
    for file in report.files {
        testing.expect(t,file.bytes>0 && file.source_bytes>0 && (file.compressed==(file.kind==asset.KIND_TEXTURE)))
        if file.compressed {testing.expect(t,file.bytes<file.source_bytes)}
        total+=file.bytes
    }
    testing.expect(t,report.output_bytes>total && report.source_bytes>report.output_bytes,"the size is that of the files and the index")
    testing.expect(t,!os.exists(fmt.tprintf("%s/notes.txt",output)) && !os.exists(fmt.tprintf("%s/ui",output)))
    // What is copied is the same bytes.
    source,_:=os.read_entire_file(fmt.tprintf("%s/models/crate.mesh",assets),context.temp_allocator)
    shipped,_:=os.read_entire_file(fmt.tprintf("%s/models/crate.mesh",output),context.temp_allocator)
    testing.expect(t,len(source)>0 && string(source)==string(shipped))

    // The index is what a scan of the output finds.
    indexed,scanned:asset.Registry
    asset.registry_init(&indexed,output);defer asset.registry_destroy(&indexed)
    asset.registry_init(&scanned,output);defer asset.registry_destroy(&scanned)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    testing.expect_value(t,asset.registry_scan(&scanned),asset.Error.None)
    testing.expect_value(t,len(indexed.files),5)
    testing.expect_value(t,len(scanned.files),5)
    for file,at in indexed.files {testing.expect(t,file.path==scanned.files[at].path && file.id==scanned.files[at].id && file.size==scanned.files[at].size && file.time==scanned.files[at].time)}
    crate,found:=asset.registry_find(&indexed,CRATE)
    testing.expect(t,found && len(asset.registry_dependencies(&indexed,crate))==1)

    // Roots by path, by folder and by id; a texture only an interface shows stays as it is.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/spare.mat","ui/","00000000000000020000000000000004","notes.txt"]}`)==nil)
    report=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,dropped=names(&report)
    testing.expect_value(t,kept,"materials/lost.mat materials/spare.mat materials/wood.mat models/crate.mesh notes.txt scenes/main.scene textures/blocks.tex textures/icon.tex textures/wood_color.tex textures/wood_normal.tex ui/hud.ui ")
    testing.expect_value(t,dropped,"materials/lonely.mat prefabs/prop.prefab textures/unused.tex ")
    testing.expect_value(t,report.roots,5)
    testing.expect(t,len(report.missing)==1 && report.missing[0].path=="materials/lost.mat" && report.missing[0].id==ABSENT,"a dependency that is no file is reported")
    icon,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/icon.tex",output))
    blocks,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/blocks.tex",output))
    testing.expect(t,icon==.RGBA8 && blocks==.BC1 && report.textures_compressed==2)
    summary:=cook_summary(&report,context.temp_allocator)
    testing.expect(t,strings.contains(summary,"assets: 11 of 14 files from 5 roots") && strings.contains(summary,"2 textures compressed") && strings.contains(summary,"  prefabs/prop.prefab (") && strings.contains(summary,"missing: materials/lost.mat depends on 00000000000000090000000000000009"),summary)

    // A root that is no longer one: its files leave the output.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["ui/hud.ui"],"textures":"keep"}`)==nil)
    report=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    testing.expect_value(t,report.removed,4)
    testing.expect(t,!os.exists(fmt.tprintf("%s/materials/spare.mat",output)) && !os.exists(fmt.tprintf("%s/notes.txt",output)) && os.is_file(fmt.tprintf("%s/ui/hud.ui",output)))
    testing.expect_value(t,report.textures_compressed,0)
    kept_color,_:=cooked_format(t,&types,fmt.tprintf("%s/textures/wood_color.tex",output))
    testing.expect_value(t,kept_color,asset.Texture_Format.RGBA8)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    testing.expect_value(t,len(indexed.files),7)

    // A dedicated server leaves behind what is only shown or heard, without missing it.
    testing.expect(t,os.write_entire_file(manifest,`{"roots":["materials/spare.mat","ui/","00000000000000020000000000000004","notes.txt"]}`)==nil)
    server:=fmt.tprintf("%s/server/assets",folder)
    report=cook_assets({assets=assets,output=server,manifest=manifest,server=true,allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,_=names(&report)
    testing.expect_value(t,kept,"materials/lost.mat materials/spare.mat materials/wood.mat models/crate.mesh notes.txt scenes/main.scene ")
    testing.expect(t,len(report.missing)==1 && report.missing[0].id==ABSENT,"a texture a material names is not missing on a server")
    testing.expect(t,!os.exists(fmt.tprintf("%s/textures",server)) && !os.exists(fmt.tprintf("%s/ui",server)))
    summary=cook_summary(&report,context.temp_allocator)
    testing.expect(t,strings.contains(summary,"only shown or heard, which a dedicated server does not ship:\n  textures/blocks.tex") && strings.contains(summary,"that nothing reaches:\n  materials/lonely.mat"),summary)
}

@(test)
a_cook_that_cannot_be_what_was_asked_says_why :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=cook_folder("errors")
    defer os.remove_all(folder)
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    manifest:=fmt.tprintf("%s/project/%s",folder,COOK_FILE)
    missing:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
    testing.expect(t,missing.error==.Assets_Missing && !os.exists(output))
    project_write(t,&types,assets)
    for text in ([]string{"{","[]",`{"roots":"ui/"}`,`{"roots":[1]}`,`{"roots":[""]}`,`{"textures":"small"}`,`{"quality":3}`}) {
        testing.expect(t,os.write_entire_file(manifest,text)==nil)
        report:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
        testing.expectf(t,report.error==.Manifest_Invalid && report.detail!="" && !os.exists(output),"%s: %v %s",text,report.error,report.detail)
    }
    for root in ([]string{"scenes/other.scene","nothing/","00000000000000090000000000000009","materials"}) {
        testing.expect(t,os.write_entire_file(manifest,strings.concatenate({`{"roots":["ui/hud.ui","`,root,`"]}`},context.temp_allocator))==nil)
        report:=cook_assets({assets=assets,output=output,manifest=manifest,allocator=context.temp_allocator})
        testing.expectf(t,report.error==.Root_Missing && report.detail==root && !os.exists(output),"%s: %v %s",root,report.error,report.detail)
    }
    // An output that cannot be a folder.
    testing.expect(t,os.remove(manifest)==nil && os.write_entire_file(fmt.tprintf("%s/blocked",folder),"a file")==nil)
    blocked:=cook_assets({assets=assets,output=fmt.tprintf("%s/blocked/assets",folder),allocator=context.temp_allocator})
    testing.expect_value(t,blocked.error,Cook_Error.Write_Failed)
    // A project without scenes or roots ships an empty folder with its index.
    empty:=fmt.tprintf("%s/empty/assets",folder)
    os.make_directory_all(empty)
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/readme.txt",empty),"nothing here")==nil)
    bare:=cook_assets({assets=empty,output=output,allocator=context.temp_allocator})
    testing.expect(t,bare.error==.None && len(bare.files)==0 && len(bare.dropped)==1 && os.is_file(fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)))
    // A cook that fails halfway leaves no index, not the one before over the files it rewrote.
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/scenes/main.scene",output))==nil)
    halfway:=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expect(t,halfway.error==.Write_Failed && !os.exists(fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)))
}

@(test)
a_cook_ships_every_asset_of_an_active_plugin_under_its_prefix :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=cook_folder("plugins")
    defer os.remove_all(folder)
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    project_write(t,&types,assets)
    plugin:=fmt.tprintf("%s/project/plugins/probe/assets",folder)
    testing.expect(t,os.make_directory_all(fmt.tprintf("%s/brushes",plugin))==nil)
    BRUSH :: base.Asset_Id{7,1}
    material_write(t,&types,fmt.tprintf("%s/brushes/soft.mat",plugin),BRUSH,WOOD_COLOR,{})
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/readme.txt",plugin),"for the code of the plugin")==nil)

    report:=cook_assets({assets=assets,output=output,plugins={{plugin,"plugins/probe"}},allocator=context.temp_allocator})
    testing.expect_value(t,report.error,Cook_Error.None)
    kept,_:=names(&report)
    testing.expect_value(t,kept,"materials/wood.mat models/crate.mesh plugins/probe/brushes/soft.mat plugins/probe/readme.txt scenes/main.scene textures/wood_color.tex textures/wood_normal.tex ")
    testing.expect(t,os.is_file(fmt.tprintf("%s/plugins/probe/brushes/soft.mat",output)) && os.is_file(fmt.tprintf("%s/plugins/probe/readme.txt",output)))
    indexed:asset.Registry
    asset.registry_init(&indexed,output);defer asset.registry_destroy(&indexed)
    testing.expect_value(t,asset.registry_load(&indexed,fmt.tprintf("%s/%s",output,asset.REGISTRY_INDEX)),asset.Error.None)
    brush,found:=asset.registry_find(&indexed,BRUSH)
    testing.expect(t,found && brush.path=="plugins/probe/brushes/soft.mat")

    // In a project, the registry sees the folder of the plugin under the same path.
    mounted:asset.Registry
    asset.registry_init(&mounted,assets);defer asset.registry_destroy(&mounted)
    asset.registry_mount(&mounted,plugin,"plugins/probe")
    testing.expect_value(t,asset.registry_scan(&mounted),asset.Error.None)
    seen,in_project:=asset.registry_find(&mounted,BRUSH)
    testing.expect(t,in_project && seen.path=="plugins/probe/brushes/soft.mat")
    testing.expect_value(t,asset.registry_file_path(&mounted,seen.path,context.temp_allocator),fmt.tprintf("%s/brushes/soft.mat",plugin))
    testing.expect_value(t,asset.registry_file_path(&mounted,"scenes/main.scene",context.temp_allocator),fmt.tprintf("%s/scenes/main.scene",assets))
}

@(private="file")
Glow :: struct {range:f32}

@(private="file")
glow_prefab_write :: proc(t:^testing.T,types:^asset.Types,path:string,range:f32) -> (lamp:asset.Scene) {
    asset.scene_init(&lamp,types,asset.KIND_PREFAB,PROP)
    asset.scene_entity_add(&lamp,1,0,"Lamp")
    asset.scene_entity_add(&lamp,2,1,"Bulb")
    lamp.info.root=1
    glow:=Glow{range}
    asset.scene_set(&lamp,2,"Glow",&glow)
    testing.expect_value(t,asset.scene_save(&lamp,path),asset.Error.None)
    return
}

@(private="file")
glow_range :: proc(t:^testing.T,types:^asset.Types,path:string) -> f32 {
    level:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&level,types,path),asset.Error.None) {return -1}
    defer asset.scene_destroy(&level)
    for member in level.members {
        if member.source!=2 {continue}
        glow,_:=asset.scene_get(&level,member.entity,"Glow",Glow)
        return glow.range
    }
    return -1
}

@(test)
a_cook_brings_the_prefab_instances_of_what_it_ships_up_to_date :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    folder:=cook_folder("resolve")
    defer os.remove_all(folder)
    assets,output:=fmt.tprintf("%s/project/assets",folder),fmt.tprintf("%s/ship/assets",folder)
    for inside in ([]string{"prefabs","scenes"}) {os.make_directory_all(fmt.tprintf("%s/%s",assets,inside))}
    lamp_path,level_path:=fmt.tprintf("%s/prefabs/lamp.prefab",assets),fmt.tprintf("%s/scenes/level.scene",assets)
    lamp:=glow_prefab_write(t,&types,lamp_path,1)
    level:asset.Scene;asset.scene_init(&level,&types,asset.KIND_SCENE,MAIN);defer asset.scene_destroy(&level)
    _,_,placed:=asset.scene_instantiate(&level,&lamp,PROP,0)
    testing.expect_value(t,placed,asset.Error.None)
    testing.expect_value(t,asset.scene_save(&level,level_path),asset.Error.None)
    asset.scene_destroy(&lamp)
    report:=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.scenes_resolved==0)

    // The prefab changes after the scene was saved: the shipped scene follows it, the one of the project stays.
    lamp=glow_prefab_write(t,&types,lamp_path,4)
    asset.scene_destroy(&lamp)
    report=cook_assets({assets=assets,output=output,allocator=context.temp_allocator})
    testing.expect(t,report.error==.None && report.scenes_resolved==1)
    for file in report.files {testing.expect_value(t,file.resolved,file.path=="scenes/level.scene")}
    testing.expect_value(t,glow_range(t,&types,fmt.tprintf("%s/scenes/level.scene",output)),f32(4))
    testing.expect_value(t,glow_range(t,&types,level_path),f32(1))
}
