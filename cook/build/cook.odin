package build

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The assets a game ships: of the assets folder of a project, the ones the
// game can reach, as the runtime loads them fastest.
//
// What is reached starts at the roots: every scene and every table of game
// data (.records, which the code reads by the type of its rows) of the
// project and what cook.mirai names, the assets only code refers to. From them, everything an
// asset depends on, and so on. The rest stays behind and is listed in the
// report. A texture that stores RGBA8 is written in the blocks of its use,
// unless only interfaces show it, and the blocks are kept in the texture
// cache for the next cook; a scene or prefab with a stale prefab
// instance is written with its instances brought up to date, so a shipped
// game loads them as they are; every other file is copied byte for byte.
// The folder gets a packed index, so the game does not look at its files to
// know what they are, and everything written is read back and checked.

COOK_FILE :: "cook.mirai"

Cook_Textures :: enum u8 {
    Blocks, // a texture that stores RGBA8 is compressed by its use
    Keep,   // textures are copied as they are
}

Cook_Desc :: struct {
    assets:string,   // the assets folder of the project
    output:string,   // the assets folder of the shipped game: it ends up holding what was cooked and nothing else
    manifest:string, // the cook.mirai of the project. "", or a file that does not exist: the scenes are the only roots
    plugins:[]project.Asset_Folder, // the assets of active plugins: every file a root, cooked under its prefix
    texture_cache:string, // folder of compressed textures kept by content (textures.cache_read); "": none
    server:bool, // for a dedicated server: what is only shown or heard (asset.Kind_Info.presentation) stays behind, and is not missing
    allocator:runtime.Allocator, // of the report. Unset: context.allocator
}

Cook_Error :: enum u8 {
    None,
    Assets_Missing,   // the assets folder cannot be read
    Manifest_Invalid, // detail: what is wrong with cook.mirai
    Root_Missing,     // detail: the root that names no file of the assets
    Read_Failed,      // detail: the file
    Write_Failed,     // detail: the file
    Verify_Failed,    // detail: the file that does not read back as what was written
    Resolve_Failed,   // detail: the scene or prefab whose prefab instances could not be brought up to date
}

Cook_File :: struct {
    path:string, // from the assets folder
    id:base.Asset_Id, // zero for a file that is not an asset
    kind:asset.Fourcc,
    source_bytes,bytes:i64,
    compressed:bool,  // a texture that was RGBA8 and is blocks now
    resolved:bool,    // a scene or prefab whose stale prefab instances follow their prefabs now
}

Cook_Dropped :: struct {
    path:string,
    bytes:i64,
    asset:bool, // false: a file of the folder that is not an asset
    shown:bool, // only shown or heard: a dedicated server leaves it behind, reached or not
}

Cook_Missing :: struct {
    path:string,      // the asset that names it
    id:base.Asset_Id, // a dependency no file of the assets is
}

// Everything it points to is in the allocator of the description.
Cook_Report :: struct {
    error:Cook_Error,
    detail:string,
    roots:int,                // files the cook started from
    files:[]Cook_File,        // what the output holds, by path
    dropped:[]Cook_Dropped,   // what stayed behind, by path
    missing:[]Cook_Missing,
    removed:int,              // files of an earlier cook that the output no longer has
    textures_compressed:int,
    scenes_resolved:int,      // scenes and prefabs written with their prefab instances up to date
    source_bytes:i64,         // of the whole assets folder
    output_bytes:i64,         // of what was written, with the index
    seconds:f64,
}

@(private="file")
Cook_Manifest :: struct {
    roots:[]string,
    textures:Cook_Textures,
}

@(private="file")
manifest_read :: proc(path:string,allocator:runtime.Allocator) -> (manifest:Cook_Manifest,problem:string) {
    if path=="" || !os.exists(path) {return}
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return {},"it cannot be read"}
    value,parse_error:=json.parse(data,parse_integers=true,allocator=context.temp_allocator)
    object,is_object:=value.(json.Object)
    if parse_error!=.None || !is_object {return {},"it is not a JSON object"}
    roots:=make([dynamic]string,allocator)
    for key,member in object {
        switch key {
        case "roots":
            list,is_list:=member.(json.Array)
            if !is_list {return {},"roots is a list of paths and ids"}
            for entry in list {
                text,is_text:=entry.(json.String)
                if !is_text || text=="" {return {},"roots is a list of paths and ids"}
                append(&roots,strings.clone(text,allocator))
            }
        case "textures":
            switch member.(json.String) or_else "" {
            case "blocks": manifest.textures=.Blocks
            case "keep":   manifest.textures=.Keep
            case: return {},"textures is \"blocks\" or \"keep\""
            }
        case:
            return {},fmt.aprintf("%s is not a setting of a cook",key,allocator=allocator)
        }
    }
    manifest.roots=roots[:]
    return
}

@(private="file")
cook_fail :: proc(report:^Cook_Report,error:Cook_Error,detail:string,allocator:runtime.Allocator) {
    report.error,report.detail=error,strings.clone(detail,allocator)
}

// Cooks the assets of a project into the folder a game ships them in. On an
// error the output may hold part of the cook, without an index.
cook_assets :: proc(desc:Cook_Desc) -> (report:Cook_Report) {
    // Set after the cook: a defer does not reach the result it returns.
    start:=time.tick_now()
    report=cook_run(desc)
    report.seconds=time.duration_seconds(time.tick_since(start))
    return
}

@(private="file")
cook_run :: proc(desc:Cook_Desc) -> (report:Cook_Report) {
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    temp:=context.temp_allocator
    manifest,problem:=manifest_read(desc.manifest,temp)
    if problem!="" {cook_fail(&report,.Manifest_Invalid,problem,allocator);return}

    registry:asset.Registry
    asset.registry_init(&registry,desc.assets,"",temp)
    for folder in desc.plugins {asset.registry_mount(&registry,folder.path,folder.prefix)}
    defer asset.registry_destroy(&registry)
    if asset.registry_scan(&registry)!=.None {cook_fail(&report,.Assets_Missing,desc.assets,allocator);return}
    files:=registry.files[:]
    reached:=make([]bool,len(files),temp)
    // What a dedicated server leaves behind counts as reached, and is not written.
    left:=make([]bool,len(files),temp)
    if desc.server {
        for file,at in files {
            if info,known:=asset.kind_info(file.kind);file.state==.Asset && known && info.presentation {reached[at],left[at]=true,true}
        }
    }
    pending:=make([dynamic]u32,temp)
    root_add :: proc(reached:[]bool,pending:^[dynamic]u32,report:^Cook_Report,at:u32) {
        if reached[at] {return}
        reached[at]=true
        report.roots+=1
        append(pending,at)
    }
    for file,at in files {
        if file.state==.Asset && (file.kind==asset.KIND_SCENE || file.kind==asset.KIND_RECORDS) {root_add(reached,&pending,&report,u32(at))}
        // What a plugin brings is for its code, which no scene names.
        for folder in desc.plugins {
            if strings.has_prefix(file.path,folder.prefix) && len(file.path)>len(folder.prefix) && file.path[len(folder.prefix)]=='/' {root_add(reached,&pending,&report,u32(at))}
        }
    }
    for root in manifest.roots {
        named:=false
        if id,is_id:=serial.text_parse_asset_id(root);is_id {
            if at,found:=registry.by_id[id];found {
                root_add(reached,&pending,&report,at)
                named=true
            }
        } else if strings.has_suffix(root,"/") {
            for file,at in files {
                if strings.has_prefix(file.path,root) {
                    root_add(reached,&pending,&report,u32(at))
                    named=true
                }
            }
        } else if at,found:=registry.by_path[root];found {
            root_add(reached,&pending,&report,at)
            named=true
        }
        if !named {cook_fail(&report,.Root_Missing,root,allocator);return}
    }
    missing:=make([dynamic]Cook_Missing,allocator)
    // Whether something that is cooked depends on a file: an interface, or anything else.
    shown:=make([]bool,len(files),temp)
    drawn:=make([]bool,len(files),temp)
    for len(pending)>0 {
        at:=pop(&pending)
        file:=&files[at]
        if file.state!=.Asset {continue}
        for id in asset.registry_dependencies(&registry,file) {
            needed,found:=registry.by_id[id]
            if !found {
                append(&missing,Cook_Missing{strings.clone(file.path,allocator),id})
                continue
            }
            if file.kind==asset.KIND_UI {shown[needed]=true} else {drawn[needed]=true}
            if !reached[needed] {
                reached[needed]=true
                append(&pending,needed)
            }
        }
    }
    report.missing=missing[:]

    if os.make_directory_all(desc.output)!=nil && !os.is_dir(desc.output) {cook_fail(&report,.Write_Failed,desc.output,allocator);return}
    // The index of an earlier cook goes first: one that fails leaves none over half of its files.
    index:=fmt.tprintf("%s/%s",desc.output,asset.REGISTRY_INDEX)
    if os.exists(index) && os.remove(index)!=nil {cook_fail(&report,.Write_Failed,asset.REGISTRY_INDEX,allocator);return}
    types:asset.Types
    asset.types_init(&types,temp)
    defer asset.types_destroy(&types)
    prefabs:asset.Registry_Prefabs
    asset.registry_prefabs_init(&prefabs,&registry,temp)
    defer asset.registry_prefabs_destroy(&prefabs)
    resolver:asset.Prefab_Resolver
    asset.resolver_init(&resolver,&types,asset.registry_prefab_files(&prefabs),temp)
    defer asset.resolver_destroy(&resolver)
    written:=make([dynamic]Cook_File,allocator)
    dropped:=make([dynamic]Cook_Dropped,allocator)
    for &file,at in files {
        report.source_bytes+=file.size
        if !reached[at] || left[at] {
            append(&dropped,Cook_Dropped{strings.clone(file.path,allocator),file.size,file.state==.Asset,left[at]})
            continue
        }
        source:=asset.registry_file_path(&registry,file.path,temp)
        target:=fmt.tprintf("%s/%s",desc.output,file.path)
        if slash:=strings.last_index_byte(target,'/');slash>=0 {
            if os.make_directory_all(target[:slash])!=nil && !os.is_dir(target[:slash]) {cook_fail(&report,.Write_Failed,file.path,allocator);return}
        }
        entry:=Cook_File{path=strings.clone(file.path,allocator),source_bytes=file.size}
        if file.state==.Asset {entry.id,entry.kind=file.id,file.kind}
        // A texture only interfaces show stays as it is: they draw it texel for texel.
        if file.state==.Asset && file.kind==asset.KIND_TEXTURE && manifest.textures==.Blocks && (drawn[at] || !shown[at]) {
            compressed,cooked:=texture_cook(source,target,&types,desc.texture_cache)
            if !cooked {cook_fail(&report,.Write_Failed,file.path,allocator);return}
            entry.compressed=compressed
            if compressed {report.textures_compressed+=1}
        }
        if !entry.compressed {
            data,read_error:=os.read_entire_file(source,temp)
            if read_error!=nil {cook_fail(&report,.Read_Failed,file.path,allocator);return}
            if file.state==.Asset && (file.kind==asset.KIND_SCENE || file.kind==asset.KIND_PREFAB) {
                resolved,resolve_ok:=scene_cook(&resolver,&types,data)
                if !resolve_ok {cook_fail(&report,.Resolve_Failed,file.path,allocator);return}
                if resolved!=nil {
                    data,entry.resolved=resolved,true
                    report.scenes_resolved+=1
                }
            }
            if os.write_entire_file(target,data)!=nil {cook_fail(&report,.Write_Failed,file.path,allocator);return}
            delete(data,temp)
        }
        // What was written reads back whole, as the asset it was.
        if file.state==.Asset {
            check:asset.Asset
            if asset.asset_load(&check,target,temp)!=.None {cook_fail(&report,.Verify_Failed,file.path,allocator);return}
            valid:=asset.blob_verify_hash(&check.blob) && check.blob.header.id==file.id && check.blob.header.kind==file.kind
            asset.asset_close(&check)
            if !valid {cook_fail(&report,.Verify_Failed,file.path,allocator);return}
        }
        if info,stat_error:=os.stat(target,temp);stat_error==nil {entry.bytes=info.size}
        report.output_bytes+=entry.bytes
        append(&written,entry)
    }
    report.files,report.dropped=written[:],dropped[:]

    // The output is what was cooked: what an earlier cook left and this one did not write goes.
    cooked:asset.Registry
    asset.registry_init(&cooked,desc.output,"",temp)
    defer asset.registry_destroy(&cooked)
    if asset.registry_scan(&cooked)!=.None {cook_fail(&report,.Write_Failed,desc.output,allocator);return}
    stale:=false
    for file in cooked.files {
        if _,kept:=slice.binary_search_by(report.files,file.path,proc(entry:Cook_File,path:string) -> slice.Ordering {return entry.path<path?.Less:entry.path>path?.Greater:.Equal});kept {continue}
        if os.remove(fmt.tprintf("%s/%s",desc.output,file.path))!=nil {cook_fail(&report,.Write_Failed,file.path,allocator);return}
        report.removed+=1
        stale=true
    }
    if stale && asset.registry_scan(&cooked)!=.None {cook_fail(&report,.Write_Failed,desc.output,allocator);return}
    if !asset.registry_save(&cooked,index) {cook_fail(&report,.Write_Failed,asset.REGISTRY_INDEX,allocator);return}
    if info,stat_error:=os.stat(index,temp);stat_error==nil {report.output_bytes+=info.size}
    return
}

// Writes a texture that stores RGBA8 as blocks, the ones the cache keeps for
// its content or new ones; compressed is false, with nothing written, for one
// that is blocks already. ok is false when it cannot be read or written.
@(private="file")
texture_cook :: proc(source,target:string,types:^asset.Types,cache:string) -> (compressed,ok:bool) {
    file:asset.Asset
    if asset.asset_load(&file,source,context.temp_allocator)!=.None {return}
    defer asset.asset_close(&file)
    view,error:=asset.texture_view(&file,types)
    if error!=.None {return}
    if view.info.format!=.RGBA8 {return false,true}
    key:=textures.cache_key_blocks(file.blob.header.content_hash)
    built,cached:=textures.cache_read(cache,key,types,context.temp_allocator)
    if !cached {
        built_ok:bool
        if built,built_ok=textures.blocks_of(view,context.temp_allocator);!built_ok {return}
        textures.cache_write(cache,key,types,&built)
    }
    defer textures.built_destroy(&built)
    return true,asset.texture_save(target,types,textures.built_desc(&built,file.blob.header.id,view.source))==.None
}

// A scene or prefab with its stale prefab instances brought up to date with
// their prefabs, as the bytes of the file; nil when none is stale. ok is
// false when it cannot be read or resolved.
@(private="file")
scene_cook :: proc(resolver:^asset.Prefab_Resolver,types:^asset.Types,data:[]u8) -> (resolved:[]u8,ok:bool) {
    file:asset.Asset
    if asset.asset_open(&file,data,context.temp_allocator)!=.None {return nil,false}
    defer asset.asset_close(&file)
    if !asset.resolver_stale(resolver,&file) {return nil,true}
    scene:asset.Scene
    if asset.scene_from_asset(&scene,types,&file,context.temp_allocator)!=.None {return nil,false}
    defer asset.scene_destroy(&scene)
    if _,error:=asset.scene_resolve(resolver,&scene);error!=.None {return nil,false}
    bytes,error:=asset.scene_bytes(&scene,context.temp_allocator)
    return bytes,error==.None
}

// "kept 61 of 83 files, 5.1 of 7.1 MB": the lines a build prints of a cook.
cook_summary :: proc(report:^Cook_Report,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    megabytes :: proc(bytes:i64) -> f64 {return f64(bytes)/(1<<20)}
    fmt.sbprintf(&b,"assets: %d of %d files from %d roots, %.2f MB (the folder has %.2f MB)",len(report.files),len(report.files)+len(report.dropped),report.roots,megabytes(report.output_bytes),megabytes(report.source_bytes))
    if report.textures_compressed>0 {fmt.sbprintf(&b,", %d textures compressed",report.textures_compressed)}
    if report.scenes_resolved>0 {fmt.sbprintf(&b,", %d scenes and prefabs with their prefab instances brought up to date",report.scenes_resolved)}
    if report.removed>0 {fmt.sbprintf(&b,", %d files of an earlier cook removed",report.removed)}
    strings.write_byte(&b,'\n')
    for shown in ([2]bool{false,true}) {
        bytes,count:=i64(0),0
        for file in report.dropped {
            if file.shown!=shown {continue}
            bytes+=file.bytes
            count+=1
        }
        if count==0 {continue}
        fmt.sbprintf(&b,shown?"left out, %.2f MB only shown or heard, which a dedicated server does not ship:\n":"left out, %.2f MB that nothing reaches:\n",megabytes(bytes))
        for file in report.dropped {
            if file.shown==shown {fmt.sbprintf(&b,"  %s (%d bytes%s)\n",file.path,file.bytes,file.asset?"":", not an asset")}
        }
    }
    buffer:[32]u8
    for lost in report.missing {fmt.sbprintf(&b,"missing: %s depends on %s, which no file is\n",lost.path,base.asset_id_format(lost.id,buffer[:]))}
    return strings.to_string(b)
}
