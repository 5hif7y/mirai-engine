package terrain

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/jobs"

// The terrain of the synthetic world of alien-planet: its Landscape (2033 by
// 2033 samples every 0.165 m, chunks of 127 cells) shown by 64 terrains in a
// grid of 8 by 8 every 335.28 m around the origin, with the settings of that
// project. From each view, once settled: the pieces each depth shows and the
// triangles they hand the renderer, and the time a settled frame takes.
// Optional: -define:TERRAIN_BENCH=true, with the path of the Landscape in
// TERRAIN_LANDSCAPE.
TERRAIN_LANDSCAPE :: #config(TERRAIN_LANDSCAPE,"C:/Users/tzbk/CODIGOS/mirai-projects/alien-planet/assets/levels/AlienPlants_Vol2_Level/Landscape.terrain")

@(test)
bench_terrain_world_of_tiles :: proc(t:^testing.T) {
    when !TERRAIN_BENCH {return} else {
        root:=source_test_path("world-bench");os.make_directory_all(root);defer os.remove_all(root)
        bytes,read:=os.read_entire_file(TERRAIN_LANDSCAPE,context.allocator)
        if !testing.expect(t,read==nil,"the Landscape of alien-planet is not there") {return}
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/Landscape.terrain",root),bytes)==nil)
        delete(bytes)
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=65536}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        testing.expect(t,jobs.system_init(&app.jobs,{threads=8,allocator=runtime.heap_allocator()}))
        defer jobs.system_destroy(&app.jobs)
        probe:Source;defer source_destroy(&probe)
        id,loaded:=source_load(&probe,fmt.tprintf("%s/Landscape.terrain",root),&assets.types)
        if !testing.expect(t,loaded) {return}
        fmt.printfln("Landscape: %v samples, cell %v m, %d cells a chunk",probe.samples,probe.cell,probe.chunk_cells)
        w:Terrain_Test_World;terrain_test_world_init(&w);defer terrain_test_world_free(&w)
        core.table_init(&w.poses,"World_Transform")
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        SPACING :: f32(335.28)
        for k in 0..<64 {
            e:=core.create(&w.entities)
            place:=core.TRANSFORM_IDENTITY
            place.position={(f32(k%8)-3.5)*SPACING,0,(f32(k/8)-3.5)*SPACING}
            core.add(&w.locals,e,place)
            core.add(&w.poses,e,core.World_Transform{transform={position=place.position,rotation=place.rotation,scale=place.scale}})
            core.add(&w.terrains,e,Terrain{source=id,solid=true})
        }
        core.table_settle(&w.poses,&w.entities)
        terrain_test_world_settle(&w)
        w.physics_settings={} // the defaults of Physics_Settings
        settings:=Terrain_Settings{}
        tick :: proc(w:^Terrain_Test_World,resident:^Terrain_Resident,app:^host.App,settings:Terrain_Settings,view:core.View) {
            c:=terrain_test_tables(w)
            physics:=phys.Physics_Settings{}
            terrain_update(c.commands,&w.terrains,c.chunks,c.locals,c.parents,c.ids,c.colliders,c.meshes,c.tints,c.overrides,&w.data,resident,&w.requests,&w.digs,settings,app,{playing=true},{phase=.Fixed},view,core.read(&w.poses),core.ref(&w.sources),{},physics,{},nil,&w.problems,{})
            terrain_test_world_settle(w)
        }
        for position in ([3][3]f32{{0,250,-700},{0,900,-1800},{-900,40,-900}}) {
            view:=core.VIEW_DEFAULT
            view.position,view.size=position,{1440,900}
            w.sources.items[0]={position,position,0};w.sources.count=1;w.sources.revision+=1
            start:=time.tick_now()
            ticks:=0
            for ticks<400 {
                tick(&w,&resident,&app,settings,view)
                ticks+=1
                idle:=!work_busy(&w.data,nil)
                for &source in resident.sources {if len(source.pending)>0 {idle=false}}
                if idle {break}
            }
            settle:=time.duration_milliseconds(time.tick_since(start))
            frame:=time.tick_now()
            for _ in 0..<10 {tick(&w,&resident,&app,settings,view)}
            stable:=time.duration_milliseconds(time.tick_since(frame))/10
            pieces,triangles:[QUAD_DEPTH_MAX+1]int
            levels:[24]int
            colliders:=len(w.colliders.values)
            for &owner in resident.owners {
                source:=resident_source_find(&resident,owner.source,owner.entity)
                for node,i in owner.nodes {
                    if !node.visible {continue}
                    chunk:=&source.chunks[i]
                    if chunk.mesh=={} {continue}
                    depth:=quad_depth(&owner.quad,i)
                    ref:=assets.index[chunk.mesh]
                    count:=int(assets.meshes[ref.index].index_count)/3
                    pieces[depth]+=1;triangles[depth]+=count
                    levels[min(int(chunk.built.lod.level),len(levels)-1)]+=count
                }
            }
            // Each terrain covers its source once; its chunks, by why they are chunks.
            holes,overlaps,collide,plain,empty:=0,0,0,0,0
            for &owner in resident.owners {
                q:=&owner.quad
                count:=make([]int,q.first[1],context.temp_allocator)
                for node,i in owner.nodes {
                    if !node.visible {continue}
                    a,b:=quad_chunks(q,i)
                    for z in a.y..<b.y {for x in a.x..<b.x {count[x+q.counts[0].x*z]+=1}}
                    if i<q.first[1] {if node.collide {collide+=1} else {plain+=1}}
                    if source:=resident_source_find(&resident,owner.source,owner.entity);source!=nil && source.chunks[i].mesh=={} {empty+=1}
                }
                for n in count {if n==0 {holes+=1} else if n>1 {overlaps+=1}}
            }
            fmt.printfln("  coverage: %d chunks without a piece, %d with more, %d shown empty; chunks shown %d with a collider, %d without; %d problems",holes,overlaps,empty,collide,plain,w.problems.count)
            for &p in core.problems_list(&w.problems) {fmt.println("   ",core.problem_text(&p))}
            total:=0
            for n in triangles {total+=n}
            fmt.printfln("view %v: %d ticks to settle (%.0f ms), a settled tick %.3f ms, %d colliders, %d triangles",position,ticks,settle,stable,colliders,total)
            for d in 0..=QUAD_DEPTH_MAX {if pieces[d]>0 {fmt.printfln("  depth %d: %d pieces, %d triangles",d,pieces[d],triangles[d])}}
            for n,level in levels {if n>0 {fmt.printfln("  level %d: %d triangles",level,n)}}
        }
    }
}
