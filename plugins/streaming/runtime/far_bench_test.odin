package streaming

@(require) import "base:runtime"
@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:math/linalg"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import "mirai:asset"
@(require) import "mirai:core"
@(require) import render "mirai:engine/render"
@(require) import scene "mirai:engine/scene"
@(require) import "mirai:host"
@(require) import "mirai:std/base"
@(require) import "mirai:std/jobs"

// ./mirai test plugins/streaming/runtime measure_the_far_form_of_a_world_of_sections -define:MIRAI_FAR_WORLD=<project>/assets/synthetic/alien_world.scene
FAR_WORLD :: #config(MIRAI_FAR_WORLD,"")

when FAR_WORLD!="" {

// The far mesh of each scene a world references, from the assets of its
// project, and what the rays and the memory hold with the default
// streaming seen from a few places: the sections near load and turn on,
// with their meshes as they are; each one past them is one proxy.
@(test)
measure_the_far_form_of_a_world_of_sections :: proc(t:^testing.T) {
    testing.set_fail_timeout(t,600*time.Second)
    root:=FAR_WORLD
    for i:=len(root)-1;i>=0;i-=1 {
        if i+len("/assets/")<=len(root) && root[i:][:len("/assets/")]=="/assets/" {root=root[:i+len("/assets")];break}
    }
    registry:asset.Registry
    asset.registry_init(&registry,root)
    defer asset.registry_destroy(&registry)
    if !testing.expect_value(t,asset.registry_scan(&registry),asset.Error.None) {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    world:asset.Scene
    if !testing.expect_value(t,asset.scene_load(&world,&types,FAR_WORLD),asset.Error.None) {return}
    defer asset.scene_destroy(&world)

    Section :: struct {scene:base.Asset_Id,position:[3]f32,extents:[3]f32}
    sections:=make([dynamic]Section,context.temp_allocator)
    ids:=asset.scene_ids(&world)
    for row in 0..<asset.scene_entity_count(&world) {
        reference,has:=asset.scene_get(&world,ids[row],"Scene_Reference",scene.Scene_Reference)
        if !has || reference.scene=={} {continue}
        pose,_:=asset.scene_get(&world,ids[row],"Transform",core.Transform)
        append(&sections,Section{reference.scene,pose.position,reference.extents})
    }
    log.infof("%d sections",len(sections))
    settings:=STREAMING_SETTINGS_DEFAULT
    heap:=runtime.heap_allocator()

    Of_Scene :: struct {id:base.Asset_Id,instances,triangles:int,meshes:map[base.Asset_Id]Mesh_Bytes,far:Mesh_Bytes}
    scenes:=make([dynamic]Of_Scene,context.temp_allocator)
    for s in sections {
        known:=false
        for o in scenes {known||=o.id==s.scene}
        if known {continue}
        of:=Of_Scene{id=s.scene,meshes=make(map[base.Asset_Id]Mesh_Bytes,context.temp_allocator)}
        // Made as the jobs make it, the main thread finding each asset in the registry.
        started:=time.tick_now()
        b:=far_build_new(s.scene,far_error(settings),{})
        rounds:=0
        for !b.done && rounds<16 {
            for id in b.wanted {
                file,found:=asset.registry_find(&registry,id)
                if !found {continue}
                append(&b.sources,host.Assets_Source{id=id,kind=file.kind,hash=file.content_hash,path=asset.registry_file_path(&registry,file.path,heap),allocator=heap})
            }
            clear(&b.wanted)
            far_round(b,jobs.OWNER)
            rounds+=1
        }
        took:=time.duration_milliseconds(time.tick_since(started))
        // What a loaded section of it holds: its static instances and their meshes.
        parts:=make([dynamic]Far_Gathered,context.temp_allocator)
        far_expand(b,s.scene,linalg.MATRIX4F32_IDENTITY,0,&parts)
        for part in parts {
            m,read:=b.meshes[part.mesh]
            if !read || .Skinned in m.view.info.flags {continue}
            of.instances+=1
            of.triangles+=int(m.view.levels[0].triangle_count)
            of.meshes[part.mesh]=mesh_bytes(m.view.geometry)
        }
        if b.built {of.far=mesh_bytes(b.made.geometry)}
        for id,m in b.meshes {
            g:=m.view.geometry
            uses:=0
            for part in parts {if part.mesh==id {uses+=1}}
            last:=g.levels[len(g.levels)-1]
            log.infof("  mesh %v: %d uses, %d triangles at level 0, %d levels, the last %d triangles at %.3f m, flags %v",id,uses,g.levels[0].triangle_count,len(g.levels),last.triangle_count,last.error,g.flags)
        }
        log.infof("scene %v: %d static instances, %d triangles at level 0, %d meshes; far mesh in %.0f ms (%d rounds, %d assets read)",s.scene,of.instances,of.triangles,len(of.meshes),took,rounds,len(b.read))
        if b.built {
            g:=b.made.geometry
            cuts:[asset.MESH_RAY_LEVELS-1]int
            for e,k in g.ray_errors {
                if e==0 {continue}
                for c in g.clusters {if c.error<=e && c.parent_error>e {cuts[k]+=int(asset.cluster_triangle_count(c))}}
            }
            log.infof("  far mesh: error %.3f m, %d levels, %d triangles at level 0 (%d in all), %d clusters, %d vertices, %.2f MB with every page, %.2f MB of its root; rays far: %v triangles at %v m",
                b.error,len(g.levels),g.levels[0].triangle_count,of.far.triangles,len(g.clusters),len(g.vertices),f64(of.far.total)/(1<<20),f64(of.far.resident)/(1<<20),cuts,g.ray_errors)
        }
        // What coarser cuts of its parts would hold, for the same meshes.
        if b.built {
            far_parts:=make([dynamic]asset.Far_Part,context.temp_allocator)
            for part in parts {
                m,read:=b.meshes[part.mesh]
                if !read || .Skinned in m.view.info.flags {continue}
                append(&far_parts,asset.Far_Part{geometry=m.view.geometry,placement=part.placement})
            }
            for error in ([]f32{0.1,0.25,0.5,1}) {
                coarse:asset.Mesh_Geometry
                if !asset.mesh_build_far(far_parts[:],error,&coarse,context.temp_allocator) {continue}
                bytes:=mesh_bytes(coarse)
                log.infof("  cut at %.2f m: %d triangles at level 0 (%d in all), %.2f MB, %.2f MB of its root",error,coarse.levels[0].triangle_count,bytes.triangles,f64(bytes.total)/(1<<20),f64(bytes.resident)/(1<<20))
            }
        }
        far_build_free(nil,b)
        append(&scenes,of)
    }

    // Seen from a place: the sections near are loaded and on, as streaming
    // turns them, and the others are one proxy each.
    View :: struct {name:string,position:[3]f32}
    first:=sections[0].position
    views:=[]View{
        {"in the corner section, on the ground",first+{0,2,0}},
        {"250 m from the corner, 100 m up",first+{-250,100,0}},
        {"1 km from the corner, 300 m up",first+{-1000,300,0}},
        {"at the middle of the world, 50 m up",{0,50,0}},
    }
    for v in views {
        on,loaded,far:=0,0,0
        instances,bytes,resident:=0,0,0
        held:=make(map[base.Asset_Id]bool,context.temp_allocator)
        for s in sections {
            outside:=linalg.max(linalg.abs(v.position-s.position)-s.extents,[3]f32{})
            distance:=linalg.length(outside)
            of:Of_Scene
            for o in scenes {if o.id==s.scene {of=o}}
            switch {
            case distance<=settings.active: on+=1;instances+=of.instances
            case distance<=settings.load:   loaded+=1;instances+=1
            case:                           far+=1;instances+=1
            }
            if distance<=settings.load {for id,size in of.meshes {if !held[id] {held[id]=true;bytes+=size.total;resident+=size.resident}}}
            if distance>settings.active && !held[s.scene] {held[s.scene]=true;bytes+=of.far.total;resident+=of.far.resident}
        }
        all:=0
        for s in sections {for o in scenes {if o.id==s.scene {all+=o.instances}}}
        log.infof("%s: %d sections on, %d loaded and off, %d far; %d instances of static meshes in the TLAS (%d with all on), %.2f MB of their meshes with every page, %.2f MB of their roots",
            v.name,on,loaded,far,instances,all,f64(bytes)/(1<<20),f64(resident)/(1<<20))
    }
}

}

// The bytes of the geometry of a mesh in the pools of the renderer: with
// every page, and what stays there of one that streams (the blocks of its
// root; the others come into the slots of the pages).
Mesh_Bytes :: struct {triangles,total,resident:int}

mesh_bytes :: proc(g:asset.Mesh_Geometry) -> (b:Mesh_Bytes) {
    for c in g.clusters {b.triangles+=int(asset.cluster_triangle_count(c))}
    tables:=len(g.clusters)*size_of(asset.Cluster)+len(g.levels)*size_of(asset.Mesh_Level)+len(g.skin)*size_of(asset.Skin_Vertex)
    b.total,b.resident=tables,tables
    streams:=g.root_page>0 && len(g.page_data)>0
    for page,at in g.pages {
        b.total+=int(page.words)*4
        if !streams || u32(at)>=g.root_page {b.resident+=int(page.words)*4}
    }
    return
}
