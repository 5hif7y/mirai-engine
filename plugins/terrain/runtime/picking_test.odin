package terrain

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"

@(test)
chunks_without_a_collider_keep_their_triangles_on_the_cpu_only_while_the_world_does_not_play :: proc(t:^testing.T) {
    root:=source_test_path("picking");os.make_directory_all(root);defer os.remove_all(root)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{65,1,65},1,16))
    source.revision=1
    id:=base.Asset_Id{93,1}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/ground.terrain",root),id,&types),asset.Error.None)
    for playing in ([]bool{true,false}) {
        assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
        app:=host.App{assets=&assets,allocator=context.allocator}
        w:Terrain_Test_World;terrain_test_world_init(&w);defer terrain_test_world_free(&w)
        // One slot for a heightfield: one chunk collides, the others do not.
        w.physics_settings=phys.Physics_Settings{bodies=8,shapes=8,contacts=8,joints=1,characters=1,hulls=1,meshes=1,heightfields=1}
        resident:Terrain_Resident;defer terrain_resident_free(&resident)
        owner:=core.create(&w.entities)
        core.add(&w.locals,owner,core.TRANSFORM_IDENTITY)
        core.add(&w.terrains,owner,Terrain{source=id,solid=true})
        terrain_test_world_settle(&w)
        for _ in 0..<3 {
            c:=terrain_test_tables(&w)
            terrain_update(c.commands,&w.terrains,c.chunks,c.locals,c.parents,c.ids,c.colliders,c.meshes,c.tints,c.overrides,&w.data,&resident,&w.requests,&w.digs,TERRAIN_TEST_SETTINGS,&app,{playing=playing},{phase=.Fixed},core.VIEW_DEFAULT,core.read(&w.poses),core.ref(&w.sources),{},w.physics_settings,{},nil,&w.problems,{})
            terrain_test_world_settle(&w)
            if work_busy(&w.data,nil) {work_wait(&w.data,nil)}
        }
        held,bare:=0,0
        for row in 0..<core.count(&w.chunks) {
            e:=core.entity_at(&w.chunks,row)
            renderer,shown:=core.get(core.read(&w.statics),e)
            if !shown || core.has(core.read(&w.colliders),e) {continue}
            geometry:geom.Mesh_Buffer
            geom.mesh_buffer_init(&geometry,context.temp_allocator)
            host.assets_geometry(&assets,renderer.mesh,.None,&geometry)
            if len(geometry.indices)>0 {held+=1} else {bare+=1}
        }
        testing.expectf(t,held+bare>0,"playing %v: chunks without a collider show",playing)
        if playing {testing.expect_value(t,held,0)} else {testing.expect_value(t,bare,0)}
    }
}
